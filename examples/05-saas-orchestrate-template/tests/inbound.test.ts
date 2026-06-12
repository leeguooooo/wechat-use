/**
 * Inbound unit tests — HMAC signature, dedupe, error body
 */

import { describe, it, expect, beforeEach } from "vitest";
import { Hono } from "hono";
import { bearerAuth } from "../src/auth.js";
import { inbound } from "../src/inbound.js";
import type { Env } from "../src/types.js";
import {
  createTestDb,
  makeEnv,
  authHeader,
  buildSignature,
  readTable,
} from "./helpers.js";

type TestDb = ReturnType<typeof createTestDb>;

interface OkBody { ok: boolean }
interface ErrBody { error: string; reason?: string }

function buildApp() {
  const app = new Hono<{ Bindings: Env }>();
  app.use("/*", bearerAuth());
  app.route("/", inbound);
  return app;
}

const APP = buildApp();

async function req(
  env: Env,
  path: string,
  init: RequestInit = {}
): Promise<Response> {
  return APP.fetch(new Request(`http://localhost${path}`, init), env);
}

const validEvent = {
  event_id: "evt_001",
  ts: new Date().toISOString(),
  normalized: {
    conversation_id: "wxid_user123",
    is_group: false,
    sender_wxid: "wxid_user123",
    sender_display_name: "Alice",
    message_kind: "text",
    text: "Hello!",
    is_mentioned: false,
    mentioned_ids: [],
    from_self: false,
  },
  raw_event: { type: "text_msg", content: "Hello!" },
};

describe("POST /api/wechat-inbound", () => {
  let d1: TestDb;
  let env: Env;

  beforeEach(() => {
    d1 = createTestDb();
    env = makeEnv(d1);
  });

  async function postEvent(
    body: unknown,
    opts: { token?: string; secret?: string; overrideT?: number; skipSig?: boolean } = {}
  ) {
    const bodyStr = JSON.stringify(body);
    const headers: Record<string, string> = {
      ...authHeader(opts.token ?? "test-token"),
      "Content-Type": "application/json",
    };
    if (!opts.skipSig) {
      headers["X-Wechat-Signature"] = await buildSignature(
        opts.secret ?? "test-secret",
        bodyStr,
        opts.overrideT
      );
    }
    return req(env, "/", { method: "POST", headers, body: bodyStr });
  }

  it("accepts a valid signed event and stores it", async () => {
    const res = await postEvent(validEvent);
    expect(res.status).toBe(200);
    expect(await res.json() as OkBody).toEqual({ ok: true });

    const rows = readTable(d1, "wechat_inbound_events");
    expect(rows).toHaveLength(1);
    expect(rows[0].event_id).toBe("evt_001");
    expect(rows[0].sender_wxid).toBe("wxid_user123");
    expect(rows[0].message_kind).toBe("text");
  });

  it("deduplicates: second push of same event_id returns ok but not stored again", async () => {
    await postEvent(validEvent);
    const res2 = await postEvent(validEvent);
    expect(res2.status).toBe(200);
    expect(await res2.json() as OkBody).toEqual({ ok: true });

    const rows = readTable(d1, "wechat_inbound_events");
    expect(rows).toHaveLength(1);
  });

  it("rejects missing X-Wechat-Signature with 401", async () => {
    const res = await postEvent(validEvent, { skipSig: true });
    expect(res.status).toBe(401);
    const body = await res.json() as ErrBody;
    expect(body.error).toBe("missing_signature");
  });

  it("rejects wrong signature with 401 signature_mismatch", async () => {
    const res = await postEvent(validEvent, { secret: "wrong-secret" });
    expect(res.status).toBe(401);
    const body = await res.json() as ErrBody;
    expect(body.error).toBe("invalid_signature");
    expect(body.reason).toBe("signature_mismatch");
  });

  it("rejects replay attack (t > 5min ago) with 401 timestamp_out_of_window", async () => {
    const oldT = Math.floor(Date.now() / 1000) - 400;
    const res = await postEvent(validEvent, { overrideT: oldT });
    expect(res.status).toBe(401);
    const body = await res.json() as ErrBody;
    expect(body.reason).toBe("timestamp_out_of_window");
  });

  it("rejects invalid body with 400", async () => {
    const res = await postEvent({ garbage: true });
    expect(res.status).toBe(400);
  });

  it("rejects wrong bearer token with 401", async () => {
    const res = await postEvent(validEvent, { token: "wrong-token" });
    expect(res.status).toBe(401);
  });

  it("stores is_group and is_mentioned flags correctly", async () => {
    const groupEvent = {
      ...validEvent,
      event_id: "evt_group_001",
      normalized: {
        ...validEvent.normalized,
        conversation_id: "room_abc@chatroom",
        is_group: true,
        is_mentioned: true,
        mentioned_ids: ["my_bot_wxid"],
        text: "@bot help",
      },
    };
    await postEvent(groupEvent);
    const rows = readTable(d1, "wechat_inbound_events");
    const row = rows.find((r) => r.event_id === "evt_group_001");
    expect(row?.is_group).toBe(1);
    expect(row?.is_mentioned).toBe(1);
  });
});
