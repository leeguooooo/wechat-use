/**
 * Outbox unit tests — state machine, idempotency, lease expiry
 */

import { describe, it, expect, beforeEach } from "vitest";
import { Hono } from "hono";
import { bearerAuth } from "../src/auth.js";
import { outbox } from "../src/outbox.js";
import type { Env } from "../src/types.js";
import {
  createTestDb,
  makeEnv,
  authHeader,
  seedTable,
  readTable,
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

// Build the app once — env is injected at fetch time via second argument
function buildApp() {
  const app = new Hono<{ Bindings: Env }>();
  app.use("/*", bearerAuth());
  app.route("/", outbox);
  return app;
}

const APP = buildApp();

/** Helper: call app.fetch with the test env injected */
async function req(
  env: Env,
  path: string,
  init: RequestInit = {}
): Promise<Response> {
  const url = `http://localhost${path}`;
  return APP.fetch(new Request(url, init), env);
}

function pendingRow(id: string, overrides: Record<string, unknown> = {}) {
  const now = new Date().toISOString();
  return {
    id,
    tenant_id: "default",
    to_recipient: `wxid_${id}`,
    text: `hello from ${id}`,
    kind: "message",
    status: "pending",
    idempotency_key: id,
    lease_until: null,
    attempt: 0,
    next_attempt_at: null,
    last_error_code: null,
    last_error_msg: null,
    send_message_id: null,
    delivered_verified: null,
    completed_at: null,
    created_at: now,
    updated_at: now,
    ...overrides,
  };
}

describe("GET /claim", () => {
  let d1: TestDb;
  let env: Env;

  beforeEach(() => {
    d1 = createTestDb();
    env = makeEnv(d1);
  });

  it("returns empty rows when no pending work", async () => {
    const res = await req(env, "/claim", { headers: authHeader() });
    expect(res.status).toBe(200);
    const body = await res.json() as ClaimBody;
    expect(body.rows).toEqual([]);
  });

  it("claims pending rows and returns them", async () => {
    seedTable(d1, "bot_outbox", [pendingRow("row1"), pendingRow("row2")]);
    const res = await req(env, "/claim?limit=10", { headers: authHeader() });
    expect(res.status).toBe(200);
    const body = await res.json() as ClaimBody;
    expect(body.rows).toHaveLength(2);
    expect(body.rows[0]).toMatchObject({
      id: expect.stringMatching(/^row/),
      idempotency_key: expect.any(String),
      to: expect.stringContaining("wxid_"),
      text: expect.any(String),
      claimed_at: expect.any(String),
      lease_until: expect.any(String),
      attempt: 1,
    });
  });

  it("respects limit parameter", async () => {
    seedTable(d1, "bot_outbox", [pendingRow("r1"), pendingRow("r2"), pendingRow("r3")]);
    const res = await req(env, "/claim?limit=2", { headers: authHeader() });
    const body = await res.json() as ClaimBody;
    expect(body.rows).toHaveLength(2);
  });

  it("does NOT claim rows with active lease", async () => {
    const future = new Date(Date.now() + 60_000).toISOString();
    seedTable(d1, "bot_outbox", [
      pendingRow("active", { status: "claimed", lease_until: future, attempt: 1 }),
    ]);
    const res = await req(env, "/claim?limit=10", { headers: authHeader() });
    const body = await res.json() as ClaimBody;
    expect(body.rows).toHaveLength(0);
  });

  it("re-claims rows with expired lease (visibility timeout)", async () => {
    const past = new Date(Date.now() - 1000).toISOString();
    seedTable(d1, "bot_outbox", [
      pendingRow("expired", { status: "claimed", lease_until: past, attempt: 1 }),
    ]);
    const res = await req(env, "/claim?limit=10", { headers: authHeader() });
    const body = await res.json() as ClaimBody;
    expect(body.rows).toHaveLength(1);
    expect(body.rows[0].id).toBe("expired");
    expect(body.rows[0].attempt).toBe(2);
  });

  it("does not claim rows with future next_attempt_at", async () => {
    const future = new Date(Date.now() + 60_000).toISOString();
    seedTable(d1, "bot_outbox", [
      pendingRow("backoff", { next_attempt_at: future }),
    ]);
    const res = await req(env, "/claim?limit=10", { headers: authHeader() });
    const body = await res.json() as ClaimBody;
    expect(body.rows).toHaveLength(0);
  });
});

describe("POST /:id/done", () => {
  let d1: TestDb;
  let env: Env;

  beforeEach(() => {
    d1 = createTestDb();
    env = makeEnv(d1);
  });

  it("marks a claimed row as done", async () => {
    const future = new Date(Date.now() + 60_000).toISOString();
    seedTable(d1, "bot_outbox", [
      pendingRow("r1", { status: "claimed", lease_until: future, attempt: 1 }),
    ]);
    const res = await req(env, "/r1/done", {
      method: "POST",
      headers: { ...authHeader(), "Content-Type": "application/json" },
      body: JSON.stringify({ delivered_verified: true }),
    });
    expect(res.status).toBe(200);
    expect(await res.json() as OkBody).toEqual({ ok: true });

    const rows = readTable(d1, "bot_outbox");
    expect(rows[0].status).toBe("done");
  });

  it("is idempotent — second done call returns ok", async () => {
    seedTable(d1, "bot_outbox", [pendingRow("r2", { status: "done" })]);
    const res = await req(env, "/r2/done", {
      method: "POST",
      headers: { ...authHeader(), "Content-Type": "application/json" },
      body: JSON.stringify({}),
    });
    expect(res.status).toBe(200);
    expect(await res.json() as OkBody).toEqual({ ok: true });
  });

  it("returns 404 for unknown id", async () => {
    const res = await req(env, "/nonexistent/done", {
      method: "POST",
      headers: { ...authHeader(), "Content-Type": "application/json" },
      body: JSON.stringify({}),
    });
    expect(res.status).toBe(404);
  });
});

describe("POST /:id/fail", () => {
  let d1: TestDb;
  let env: Env;

  beforeEach(() => {
    d1 = createTestDb();
    env = makeEnv(d1, { MAX_ATTEMPTS: "5" });
  });

  it("retryable=true resets to pending with next_attempt_at", async () => {
    const future = new Date(Date.now() + 60_000).toISOString();
    seedTable(d1, "bot_outbox", [
      pendingRow("r1", { status: "claimed", lease_until: future, attempt: 1 }),
    ]);

    const res = await req(env, "/r1/fail", {
      method: "POST",
      headers: { ...authHeader(), "Content-Type": "application/json" },
      body: JSON.stringify({ error_code: "send_failed", error_message: "InputView cold", retryable: true }),
    });

    expect(res.status).toBe(200);
    const body = await res.json() as FailBody;
    expect(body.ok).toBe(true);
    expect(body.next_attempt_at).toBeTruthy();

    const rows = readTable(d1, "bot_outbox");
    expect(rows[0].status).toBe("pending");
    expect(rows[0].last_error_code).toBe("send_failed");
  });

  it("retryable=false sets status=failed", async () => {
    const future = new Date(Date.now() + 60_000).toISOString();
    seedTable(d1, "bot_outbox", [
      pendingRow("r2", { status: "claimed", lease_until: future, attempt: 1 }),
    ]);

    const res = await req(env, "/r2/fail", {
      method: "POST",
      headers: { ...authHeader(), "Content-Type": "application/json" },
      body: JSON.stringify({ error_code: "resolve_failed", retryable: false }),
    });

    expect(res.status).toBe(200);
    const body = await res.json() as FailBody;
    expect(body.ok).toBe(true);
    expect(body.next_attempt_at).toBeNull();

    const rows = readTable(d1, "bot_outbox");
    expect(rows[0].status).toBe("failed");
  });

  it("attempt >= max sets status=failed even if retryable=true", async () => {
    const future = new Date(Date.now() + 60_000).toISOString();
    seedTable(d1, "bot_outbox", [
      pendingRow("r3", { status: "claimed", lease_until: future, attempt: 5 }),
    ]);

    await req(env, "/r3/fail", {
      method: "POST",
      headers: { ...authHeader(), "Content-Type": "application/json" },
      body: JSON.stringify({ error_code: "bridge_unavailable", retryable: true }),
    });

    const rows = readTable(d1, "bot_outbox");
    expect(rows[0].status).toBe("failed");
  });

  it("error_code=lease_expired always hard-fails", async () => {
    const future = new Date(Date.now() + 60_000).toISOString();
    seedTable(d1, "bot_outbox", [
      pendingRow("r4", { status: "claimed", lease_until: future, attempt: 1 }),
    ]);

    await req(env, "/r4/fail", {
      method: "POST",
      headers: { ...authHeader(), "Content-Type": "application/json" },
      body: JSON.stringify({ error_code: "lease_expired", retryable: true }),
    });

    const rows = readTable(d1, "bot_outbox");
    expect(rows[0].status).toBe("failed");
  });

  it("idempotent on already-done row", async () => {
    seedTable(d1, "bot_outbox", [pendingRow("r5", { status: "done" })]);

    const res = await req(env, "/r5/fail", {
      method: "POST",
      headers: { ...authHeader(), "Content-Type": "application/json" },
      body: JSON.stringify({ error_code: "send_failed", retryable: true }),
    });

    expect(res.status).toBe(200);
    expect((await res.json() as OkBody).ok).toBe(true);
    const rows = readTable(d1, "bot_outbox");
    expect(rows[0].status).toBe("done");
  });
});
