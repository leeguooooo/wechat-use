/**
 * Outbox endpoints — implements spec §3.1 / §3.2 / §3.3
 *
 *   GET  /api/wechat-outbox/claim?limit=N  → atomic claim N pending rows
 *   POST /api/wechat-outbox/:id/done       → mark sent (idempotent)
 *   POST /api/wechat-outbox/:id/fail       → report failure + schedule retry
 */

import { Hono } from "hono";
import { z } from "zod";
import {
  backoffSeconds,
  type ClaimResponse,
  type ClaimResponseRow,
  type DoneBody,
  type Env,
  type FailBody,
  type FailResponse,
  type OutboxRow,
} from "./types.js";

const outbox = new Hono<{ Bindings: Env; Variables: { tenantId: string } }>();

// ─── helpers ──────────────────────────────────────────────────────────────────

function leaseUntilISO(env: Env): string {
  const secs = parseInt(env.LEASE_SECONDS ?? "60", 10);
  return new Date(Date.now() + secs * 1000).toISOString();
}

function maxAttempts(env: Env): number {
  return parseInt(env.MAX_ATTEMPTS ?? "5", 10);
}

// ─── GET /api/wechat-outbox/claim ────────────────────────────────────────────

outbox.get("/claim", async (c) => {
  const tenantId = c.get("tenantId");
  const limitStr = c.req.query("limit") ?? "10";
  const limit = Math.min(Math.max(parseInt(limitStr, 10) || 1, 1), 100);

  const now = new Date().toISOString();
  const leaseUntil = leaseUntilISO(c.env);
  const claimedAt = now;

  // Atomic claim:
  // - Pick rows that are 'pending' OR ('claimed' with expired lease)
  //   ordered by next_attempt_at (nulls first = immediately eligible) then created_at.
  // - D1 doesn't support UPDATE...WHERE id IN (SELECT...) RETURNING * in a single
  //   shot atomically within a transaction via the simple API, so we use a
  //   D1 batch to: SELECT candidate ids → UPDATE each → RETURNING the updated rows.
  //
  // NOTE: In a high-throughput multi-replica scenario you'd need a proper
  // SELECT FOR UPDATE / advisory lock.  D1 is single-writer by nature at the
  // regional level, so this two-step is safe for typical SaaS workloads.

  const candidateResult = await c.env.DB.prepare(
    `SELECT id FROM bot_outbox
      WHERE tenant_id = ?
        AND (
          status = 'pending'
          OR (status = 'claimed' AND lease_until < ?)
        )
        AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
      ORDER BY next_attempt_at ASC NULLS FIRST, created_at ASC
      LIMIT ?`
  )
    .bind(tenantId, now, now, limit)
    .all<{ id: string }>();

  const ids = (candidateResult.results ?? []).map((r) => r.id);

  if (ids.length === 0) {
    return c.json<ClaimResponse>({ rows: [] });
  }

  // Update each candidate atomically inside a D1 batch
  const stmts = ids.map((id) =>
    c.env.DB.prepare(
      `UPDATE bot_outbox
          SET status = 'claimed',
              lease_until = ?,
              attempt = attempt + 1,
              updated_at = ?
        WHERE id = ?
          AND (
            status = 'pending'
            OR (status = 'claimed' AND lease_until < ?)
          )
          AND (next_attempt_at IS NULL OR next_attempt_at <= ?)`
    ).bind(leaseUntil, claimedAt, id, now, now)
  );

  await c.env.DB.batch(stmts);

  // Fetch the updated rows to return
  const placeholders = ids.map(() => "?").join(",");
  const rows = await c.env.DB.prepare(
    `SELECT * FROM bot_outbox WHERE id IN (${placeholders}) AND status = 'claimed'`
  )
    .bind(...ids)
    .all<OutboxRow>();

  const responseRows: ClaimResponseRow[] = (rows.results ?? []).map((r) => ({
    id: r.id,
    idempotency_key: r.idempotency_key,
    to: r.to_recipient,
    text: r.text,
    claimed_at: claimedAt,
    lease_until: r.lease_until ?? leaseUntil,
    attempt: r.attempt,
  }));

  return c.json<ClaimResponse>({ rows: responseRows });
});

// ─── POST /api/wechat-outbox/:id/done ────────────────────────────────────────

const DoneBodySchema = z.object({
  send_message_id: z.string().optional().nullable(),
  delivered_verified: z.boolean().optional(),
  completed_at: z.string().optional(),
});

outbox.post("/:id/done", async (c) => {
  const id = c.req.param("id");
  const tenantId = c.get("tenantId");

  let body: DoneBody = {};
  try {
    const raw = await c.req.json();
    body = DoneBodySchema.parse(raw);
  } catch {
    return c.json({ error: "invalid_body" }, 400);
  }

  const now = new Date().toISOString();
  const completedAt = body.completed_at ?? now;

  // Idempotent: if already 'done', return ok without touching the row
  const existing = await c.env.DB.prepare(
    "SELECT status, send_message_id FROM bot_outbox WHERE id = ? AND tenant_id = ?"
  )
    .bind(id, tenantId)
    .first<{ status: string; send_message_id: string | null }>();

  if (!existing) {
    return c.json({ error: "not_found" }, 404);
  }

  if (existing.status === "done") {
    // Already completed — idempotent success
    return c.json({ ok: true });
  }

  await c.env.DB.prepare(
    `UPDATE bot_outbox
        SET status = 'done',
            send_message_id = COALESCE(send_message_id, ?),
            delivered_verified = ?,
            completed_at = ?,
            lease_until = NULL,
            updated_at = ?
      WHERE id = ? AND tenant_id = ?`
  )
    .bind(
      body.send_message_id ?? null,
      body.delivered_verified ? 1 : 0,
      completedAt,
      now,
      id,
      tenantId
    )
    .run();

  console.log(`[outbox] done id=${id} tenant=${tenantId}`);
  return c.json({ ok: true });
});

// ─── POST /api/wechat-outbox/:id/fail ────────────────────────────────────────

const FailBodySchema = z.object({
  error_code: z.enum([
    "send_failed",
    "resolve_failed",
    "bridge_unavailable",
    "wechat_blocked",
    "hard_invalid",
    "lease_expired",
  ]),
  error_message: z.string().optional(),
  retryable: z.boolean(),
  failed_at: z.string().optional(),
});

outbox.post("/:id/fail", async (c) => {
  const id = c.req.param("id");
  const tenantId = c.get("tenantId");

  let body: FailBody;
  try {
    const raw = await c.req.json();
    body = FailBodySchema.parse(raw);
  } catch {
    return c.json({ error: "invalid_body" }, 400);
  }

  const now = new Date().toISOString();

  const existing = await c.env.DB.prepare(
    "SELECT status, attempt FROM bot_outbox WHERE id = ? AND tenant_id = ?"
  )
    .bind(id, tenantId)
    .first<{ status: string; attempt: number }>();

  if (!existing) {
    return c.json({ error: "not_found" }, 404);
  }

  // Idempotent: already settled
  if (existing.status === "done" || existing.status === "failed") {
    return c.json<FailResponse>({ ok: true, next_attempt_at: null });
  }

  const maxAttempt = maxAttempts(c.env);
  const shouldRetry =
    body.retryable &&
    body.error_code !== "lease_expired" &&
    existing.attempt < maxAttempt;

  let nextAttemptAt: string | null = null;
  let newStatus: string;

  if (shouldRetry) {
    const delaySecs = backoffSeconds(existing.attempt);
    nextAttemptAt = new Date(Date.now() + delaySecs * 1000).toISOString();
    newStatus = "pending";
  } else {
    newStatus = "failed";
  }

  await c.env.DB.prepare(
    `UPDATE bot_outbox
        SET status = ?,
            next_attempt_at = ?,
            last_error_code = ?,
            last_error_msg = ?,
            lease_until = NULL,
            updated_at = ?
      WHERE id = ? AND tenant_id = ?`
  )
    .bind(
      newStatus,
      nextAttemptAt,
      body.error_code,
      body.error_message ?? null,
      now,
      id,
      tenantId
    )
    .run();

  console.log(
    `[outbox] fail id=${id} tenant=${tenantId} code=${body.error_code} ` +
      `status=${newStatus} next_attempt_at=${nextAttemptAt}`
  );

  return c.json<FailResponse>({ ok: true, next_attempt_at: nextAttemptAt });
});

export { outbox };
