/**
 * Inbound webhook endpoint — implements spec §3.4 + §4
 *
 *   POST /api/wechat-inbound
 *
 * Flow:
 *   1. Bearer auth (handled by middleware in index.ts)
 *   2. HMAC-SHA256 signature verification (X-Wechat-Signature: t=…,v1=…)
 *   3. 5-minute replay-window check
 *   4. Dedupe by event_id (INSERT OR IGNORE)
 *   5. INSERT normalised fields + raw_event JSON
 *   6. ← DISPATCH POINT: call your handlers here after the INSERT
 */

import { Hono } from "hono";
import { z } from "zod";
import { type Env, type InboundBody } from "./types.js";

const inbound = new Hono<{ Bindings: Env; Variables: { tenantId: string } }>();

// ─── Signature verification ────────────────────────────────────────────────────

/**
 * Verifies X-Wechat-Signature: t=<unix>,v1=<hex>
 *
 * Signature payload = "<t>.<raw_body>"
 * Algorithm = HMAC-SHA256(WEBHOOK_SECRET, signature_payload)
 * Replay window = 5 minutes
 */
async function verifySignature(
  secret: string,
  rawBody: string,
  header: string
): Promise<{ ok: boolean; reason?: string }> {
  // Parse header: t=1730000000,v1=<hex>
  const parts = Object.fromEntries(
    header.split(",").map((p) => {
      const eq = p.indexOf("=");
      return [p.slice(0, eq), p.slice(eq + 1)];
    })
  );

  const tStr = parts["t"];
  const v1 = parts["v1"];

  if (!tStr || !v1) {
    return { ok: false, reason: "malformed_signature_header" };
  }

  const t = parseInt(tStr, 10);
  if (isNaN(t)) {
    return { ok: false, reason: "invalid_timestamp" };
  }

  // 5-minute replay window
  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - t) > 300) {
    return { ok: false, reason: "timestamp_out_of_window" };
  }

  // Recompute HMAC
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sigPayload = `${t}.${rawBody}`;
  const sigBuffer = await crypto.subtle.sign("HMAC", key, enc.encode(sigPayload));
  const computed = Array.from(new Uint8Array(sigBuffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  // Constant-time compare
  if (computed.length !== v1.length) {
    return { ok: false, reason: "signature_mismatch" };
  }
  let diff = 0;
  for (let i = 0; i < computed.length; i++) {
    diff |= computed.charCodeAt(i) ^ v1.charCodeAt(i);
  }
  if (diff !== 0) {
    return { ok: false, reason: "signature_mismatch" };
  }

  return { ok: true };
}

// ─── Inbound schema ────────────────────────────────────────────────────────────

const NormalizedSchema = z.object({
  conversation_id: z.string(),
  is_group: z.boolean(),
  sender_wxid: z.string(),
  sender_display_name: z.string(),
  message_kind: z.enum([
    "text",
    "image",
    "voice",
    "video",
    "file",
    "url",
    "quote",
    "recall",
    "system",
    "mp",
  ]),
  text: z.string(),
  is_mentioned: z.boolean(),
  mentioned_ids: z.array(z.string()),
  from_self: z.boolean(),
});

const InboundBodySchema = z.object({
  event_id: z.string().min(1),
  ts: z.string(),
  normalized: NormalizedSchema,
  raw_event: z.record(z.unknown()),
});

// ─── POST /api/wechat-inbound ─────────────────────────────────────────────────

inbound.post("/", async (c) => {
  const tenantId = c.get("tenantId");

  // Read raw body for signature verification (must be done before .json())
  const rawBody = await c.req.text();

  // Signature verification
  const sigHeader = c.req.header("X-Wechat-Signature");
  if (!sigHeader) {
    return c.json({ error: "missing_signature", reason: "X-Wechat-Signature header required" }, 401);
  }

  const webhookSecret = c.env.WEBHOOK_SECRET;
  if (!webhookSecret) {
    console.error("[inbound] WEBHOOK_SECRET is not configured");
    return c.json({ error: "server_misconfigured" }, 500);
  }

  const sigResult = await verifySignature(webhookSecret, rawBody, sigHeader);
  if (!sigResult.ok) {
    console.warn(`[inbound] signature rejected reason=${sigResult.reason} tenant=${tenantId}`);
    return c.json({ error: "invalid_signature", reason: sigResult.reason }, 401);
  }

  // Parse body
  let body: InboundBody;
  try {
    const parsed = JSON.parse(rawBody);
    body = InboundBodySchema.parse(parsed);
  } catch {
    return c.json({ error: "invalid_body" }, 400);
  }

  const now = new Date().toISOString();
  const { normalized, raw_event, event_id, ts } = body;

  // Dedupe: INSERT OR IGNORE — if the row already exists, skip processing
  const result = await c.env.DB.prepare(
    `INSERT OR IGNORE INTO wechat_inbound_events (
        event_id, tenant_id, received_at,
        conversation_id, is_group, sender_wxid, sender_display_name,
        message_kind, text, is_mentioned, from_self,
        raw_event
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  )
    .bind(
      event_id,
      tenantId,
      now,
      normalized.conversation_id,
      normalized.is_group ? 1 : 0,
      normalized.sender_wxid,
      normalized.sender_display_name,
      normalized.message_kind,
      normalized.text,
      normalized.is_mentioned ? 1 : 0,
      normalized.from_self ? 1 : 0,
      JSON.stringify(raw_event)
    )
    .run();

  const isDuplicate = result.meta.changes === 0;

  if (isDuplicate) {
    console.log(`[inbound] duplicate event_id=${event_id} tenant=${tenantId}`);
    // Still return 200 — Mac treats 4xx as permanent reject, not 200 duplicate
    return c.json({ ok: true });
  }

  console.log(
    `[inbound] received event_id=${event_id} tenant=${tenantId} ` +
      `kind=${normalized.message_kind} group=${normalized.is_group} ` +
      `mentioned=${normalized.is_mentioned} ts=${ts}`
  );

  // ─────────────────────────────────────────────────────────────────────────────
  // DISPATCH POINT — add your business logic here.
  //
  // Examples:
  //
  //   if (normalized.is_mentioned && normalized.message_kind === 'text') {
  //     await handleMention(c.env, tenantId, body);
  //   }
  //
  //   if (!normalized.is_group && !normalized.from_self) {
  //     await handleDM(c.env, tenantId, body);
  //   }
  //
  // Use `enqueueWechatOutbox` (from ./enqueue.ts) to send reply messages.
  // ─────────────────────────────────────────────────────────────────────────────

  return c.json({ ok: true });
});

export { inbound };
