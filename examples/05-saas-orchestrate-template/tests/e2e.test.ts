/**
 * E2E flow test — simulates the full Mac orchestrate client interaction.
 */

import { describe, it, expect, beforeEach } from "vitest";
import { Hono } from "hono";
import { bearerAuth } from "../src/auth.js";
import { outbox } from "../src/outbox.js";
import { inbound } from "../src/inbound.js";
import { enqueueWechatOutbox } from "../src/enqueue.js";
import type { Env } from "../src/types.js";
import {
  createTestDb,
  makeEnv,
  authHeader,
  buildSignature,
} from "./helpers.js";

type TestDb = ReturnType<typeof createTestDb>;

interface ClaimBody {
  rows: Array<{
    id: string;
    idempotency_key: string;
    to: string;
    text: string;
    claimed_at: string;
    lease_until: string;
    attempt: number;
  }>;
}
interface OkBody { ok: boolean }
interface FailBody { ok: boolean; next_attempt_at: string | null }

function buildApp() {
  const app = new Hono<{ Bindings: Env }>();
  app.use("/*", bearerAuth());
  app.route("/api/wechat-outbox", outbox);
  app.route("/api/wechat-inbound", inbound);
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

describe("Happy path: enqueue → claim → done", () => {
  let d1: TestDb;
  let env: Env;

  beforeEach(() => {
    d1 = createTestDb();
    env = makeEnv(d1);
  });

  it("full flow completes successfully", async () => {
    // Step 1: Business code enqueues a message
    const { id } = await enqueueWechatOutbox(env, {
      to: "wxid_customer42",
      text: "您好，您的订单已确认！",
      idempotency_key: "order-1234-msg-1",
      kind: "order_confirm",
    });
    expect(id).toMatch(/^out_/);

    // Step 2: Mac polls claim
    const claimRes = await req(env, "/api/wechat-outbox/claim?limit=5", {
      headers: authHeader(),
    });
    expect(claimRes.status).toBe(200);
    const claimed = await claimRes.json() as ClaimBody;
    expect(claimed.rows).toHaveLength(1);

    const row = claimed.rows[0];
    expect(row.id).toBe(id);
    expect(row.idempotency_key).toBe("order-1234-msg-1");
    expect(row.to).toBe("wxid_customer42");
    expect(row.text).toBe("您好，您的订单已确认！");
    expect(row.attempt).toBe(1);
    expect(row.lease_until).toBeTruthy();

    // Step 4: Mac reports done
    const doneRes = await req(env, `/api/wechat-outbox/${id}/done`, {
      method: "POST",
      headers: { ...authHeader(), "Content-Type": "application/json" },
      body: JSON.stringify({ send_message_id: "wechat-srv-id-999", delivered_verified: true }),
    });
    expect(doneRes.status).toBe(200);
    expect(await doneRes.json() as OkBody).toEqual({ ok: true });

    // Step 5: Second claim returns empty
    const claimRes2 = await req(env, "/api/wechat-outbox/claim?limit=5", {
      headers: authHeader(),
    });
    const claimed2 = await claimRes2.json() as ClaimBody;
    expect(claimed2.rows).toHaveLength(0);
  });

  it("done is idempotent — calling twice returns ok both times", async () => {
    const { id } = await enqueueWechatOutbox(env, { to: "wxid_user", text: "hello" });
    await req(env, "/api/wechat-outbox/claim?limit=1", { headers: authHeader() });

    for (let i = 0; i < 2; i++) {
      const res = await req(env, `/api/wechat-outbox/${id}/done`, {
        method: "POST",
        headers: { ...authHeader(), "Content-Type": "application/json" },
        body: JSON.stringify({ delivered_verified: true }),
      });
      expect(res.status).toBe(200);
      expect(await res.json() as OkBody).toMatchObject({ ok: true });
    }
  });
});

describe("Failure path: enqueue → claim → fail (retryable) → backoff", () => {
  let d1: TestDb;
  let env: Env;

  beforeEach(() => {
    d1 = createTestDb();
    env = makeEnv(d1);
  });

  it("retryable fail schedules next_attempt_at in future, claim returns empty", async () => {
    const { id } = await enqueueWechatOutbox(env, { to: "wxid_target", text: "retry test" });

    await req(env, "/api/wechat-outbox/claim?limit=1", { headers: authHeader() });

    const failRes = await req(env, `/api/wechat-outbox/${id}/fail`, {
      method: "POST",
      headers: { ...authHeader(), "Content-Type": "application/json" },
      body: JSON.stringify({
        error_code: "bridge_unavailable",
        error_message: "wechatd not running",
        retryable: true,
      }),
    });
    expect(failRes.status).toBe(200);
    const failBody = await failRes.json() as FailBody;
    expect(failBody.ok).toBe(true);
    expect(failBody.next_attempt_at).toBeTruthy();
    expect(new Date(failBody.next_attempt_at!).getTime()).toBeGreaterThan(Date.now());

    // Claim immediately — backoff not yet expired
    const claimRes = await req(env, "/api/wechat-outbox/claim?limit=5", { headers: authHeader() });
    const claimed = await claimRes.json() as ClaimBody;
    expect(claimed.rows).toHaveLength(0);
  });

  it("non-retryable fail sets row to failed, claim returns empty", async () => {
    const { id } = await enqueueWechatOutbox(env, { to: "wxid_nobody", text: "will fail hard" });
    await req(env, "/api/wechat-outbox/claim?limit=1", { headers: authHeader() });

    const failRes = await req(env, `/api/wechat-outbox/${id}/fail`, {
      method: "POST",
      headers: { ...authHeader(), "Content-Type": "application/json" },
      body: JSON.stringify({ error_code: "resolve_failed", retryable: false }),
    });

    expect(failRes.status).toBe(200);
    const failBody = await failRes.json() as FailBody;
    expect(failBody.next_attempt_at).toBeNull();

    const claimRes = await req(env, "/api/wechat-outbox/claim?limit=5", { headers: authHeader() });
    const claimed = await claimRes.json() as ClaimBody;
    expect(claimed.rows).toHaveLength(0);
  });
});

describe("Inbound → enqueue reply flow", () => {
  let d1: TestDb;
  let env: Env;

  beforeEach(() => {
    d1 = createTestDb();
    env = makeEnv(d1);
  });

  it("inbound event accepted and deduplicated, reply can be enqueued", async () => {
    const event = {
      event_id: "e2e-evt-001",
      ts: new Date().toISOString(),
      normalized: {
        conversation_id: "wxid_alice",
        is_group: false,
        sender_wxid: "wxid_alice",
        sender_display_name: "Alice",
        message_kind: "text",
        text: "hi bot",
        is_mentioned: false,
        mentioned_ids: [],
        from_self: false,
      },
      raw_event: {},
    };
    const bodyStr = JSON.stringify(event);
    const sig = await buildSignature("test-secret", bodyStr);

    const res = await req(env, "/api/wechat-inbound", {
      method: "POST",
      headers: {
        ...authHeader(),
        "Content-Type": "application/json",
        "X-Wechat-Signature": sig,
      },
      body: bodyStr,
    });
    expect(res.status).toBe(200);

    // Simulate business logic: enqueue a reply
    const { id } = await enqueueWechatOutbox(env, {
      to: "wxid_alice",
      text: "hello from bot!",
      idempotency_key: `reply-${event.event_id}`,
    });
    expect(id).toMatch(/^out_/);

    // Mac claims the reply
    const claimRes = await req(env, "/api/wechat-outbox/claim?limit=1", {
      headers: authHeader(),
    });
    const claimed = await claimRes.json() as ClaimBody;
    expect(claimed.rows).toHaveLength(1);
    expect(claimed.rows[0].to).toBe("wxid_alice");
    expect(claimed.rows[0].idempotency_key).toBe(`reply-${event.event_id}`);
  });
});
