/**
 * Test helpers — in-memory D1 stub + env factory.
 *
 * The stub intercepts known query patterns from outbox.ts and inbound.ts
 * and executes them against an in-memory Map store.  Unknown queries return
 * empty results (logged to console.warn for debugging).
 *
 * This approach trades completeness for correctness: tests run in plain vitest
 * (no wrangler pool, no native sqlite binary) and finish in < 2s.
 */

import type { Env } from "../src/types.js";

type Row = Record<string, unknown>;
type TableStore = Map<string, Row>;

// ─── In-memory store ──────────────────────────────────────────────────────────

class InMemoryD1 {
  readonly tables: Map<string, TableStore> = new Map();

  private getTable(name: string): TableStore {
    if (!this.tables.has(name)) this.tables.set(name, new Map());
    return this.tables.get(name)!;
  }

  allRows(table: string): Row[] {
    return Array.from(this.getTable(table).values());
  }

  seed(tableName: string, rows: Row[]): void {
    const t = this.getTable(tableName);
    for (const row of rows) {
      const pk = String(row["id"] ?? row["event_id"] ?? row["token_hash"]);
      t.set(pk, { ...row });
    }
  }

  readTable(tableName: string): Row[] {
    return Array.from(this.getTable(tableName).values());
  }

  upsert(table: string, row: Row, orIgnore = false): number {
    const t = this.getTable(table);
    const pk = String(row["id"] ?? row["event_id"] ?? row["token_hash"]);
    if (orIgnore && t.has(pk)) return 0;
    t.set(pk, { ...row });
    return 1;
  }

  updateById(table: string, id: string, updates: Row): number {
    const t = this.getTable(table);
    if (!t.has(id)) return 0;
    t.set(id, { ...t.get(id)!, ...updates });
    return 1;
  }

  findById(table: string, id: string): Row | null {
    return this.getTable(table).get(id) ?? null;
  }

  // D1Database interface stubs
  prepare(query: string): D1PreparedStatement {
    return new InMemoryStatement(query, [], this) as unknown as D1PreparedStatement;
  }

  async batch<T = Record<string, unknown>>(
    statements: D1PreparedStatement[]
  ): Promise<D1Result<T>[]> {
    const results: D1Result<T>[] = [];
    for (const stmt of statements) {
      // Statements are InMemoryStatement cast to D1PreparedStatement
      results.push(await (stmt as unknown as InMemoryStatement).run<T>());
    }
    return results;
  }

  async dump(): Promise<ArrayBuffer> { return new ArrayBuffer(0); }
  async exec(_q: string): Promise<D1ExecResult> { return { count: 0, duration: 0 }; }
  withSession(_?: unknown): unknown { return this; }
}

// ─── Statement ────────────────────────────────────────────────────────────────

class InMemoryStatement {
  constructor(
    public readonly sql: string,
    public readonly params: unknown[],
    private store: InMemoryD1
  ) {}

  bind(...values: unknown[]): InMemoryStatement {
    return new InMemoryStatement(this.sql, values, this.store);
  }

  // ─── Query router ──────────────────────────────────────────────────────────
  // Each method matches a canonical query pattern from the production code.

  private dispatch(): { rows: Row[]; changes: number } {
    const sql = this.sql.trim();
    const upper = sql.toUpperCase();

    // ── SELECT id FROM bot_outbox WHERE ... (candidate claim query)
    if (upper.includes("SELECT") && upper.includes("FROM BOT_OUTBOX") && upper.includes("LIMIT")) {
      return { rows: this.claimSelect(), changes: 0 };
    }

    // ── SELECT * FROM bot_outbox WHERE id IN (...)
    if (upper.includes("SELECT *") && upper.includes("FROM BOT_OUTBOX") && upper.includes("IN")) {
      return { rows: this.selectByIds(), changes: 0 };
    }

    // ── SELECT status,... FROM bot_outbox WHERE id = ? AND tenant_id = ?
    if (upper.includes("SELECT") && upper.includes("FROM BOT_OUTBOX") && upper.includes("WHERE") && !upper.includes("LIMIT") && !upper.includes("IN")) {
      return { rows: this.selectByIdAndTenant(), changes: 0 };
    }

    // ── UPDATE bot_outbox SET status='claimed' ... (lease claim update)
    if (upper.includes("UPDATE BOT_OUTBOX") && upper.includes("STATUS = 'CLAIMED'") && upper.includes("ATTEMPT = ATTEMPT + 1")) {
      return { rows: [], changes: this.updateClaimRow() };
    }

    // ── UPDATE bot_outbox SET status = 'done', send_message_id = COALESCE(...)
    if (upper.includes("UPDATE BOT_OUTBOX") && upper.includes("STATUS = 'DONE'") && upper.includes("COALESCE")) {
      return { rows: [], changes: this.updateDoneRow() };
    }

    // ── UPDATE bot_outbox SET status = ?, next_attempt_at = ? (fail update)
    if (upper.includes("UPDATE BOT_OUTBOX") && upper.includes("NEXT_ATTEMPT_AT = ?") && upper.includes("LAST_ERROR_CODE = ?")) {
      return { rows: [], changes: this.updateFailRow() };
    }

    // ── INSERT INTO bot_outbox
    if (upper.includes("INSERT") && upper.includes("INTO BOT_OUTBOX")) {
      return { rows: [], changes: this.insertOutbox() };
    }

    // ── INSERT OR IGNORE INTO wechat_inbound_events
    if (upper.includes("INSERT OR IGNORE") && upper.includes("WECHAT_INBOUND_EVENTS")) {
      return { rows: [], changes: this.insertInboundEvent() };
    }

    console.warn("[InMemoryD1] unhandled query:", this.sql.slice(0, 80));
    return { rows: [], changes: 0 };
  }

  // ── Claim candidate SELECT (picks pending OR expired-claimed rows)
  private claimSelect(): Row[] {
    const [tenantId, nowStr, nowStr2, limit] = this.params as [string, string, string, number];
    const now = nowStr;
    const rows = this.store.allRows("bot_outbox").filter((r) => {
      if (r.tenant_id !== tenantId) return false;
      if (r.next_attempt_at != null && String(r.next_attempt_at) > now) return false;
      if (r.status === "pending") return true;
      if (r.status === "claimed" && r.lease_until != null && String(r.lease_until) < now) return true;
      return false;
    });
    // Sort: next_attempt_at ASC NULLS FIRST, then created_at ASC
    rows.sort((a, b) => {
      const an = a.next_attempt_at;
      const bn = b.next_attempt_at;
      if (an == null && bn == null) return String(a.created_at) < String(b.created_at) ? -1 : 1;
      if (an == null) return -1;
      if (bn == null) return 1;
      return String(an) < String(bn) ? -1 : String(an) > String(bn) ? 1 : 0;
    });
    return rows.slice(0, Number(limit)).map((r) => ({ id: r.id }));
  }

  // ── SELECT * WHERE id IN (...)
  private selectByIds(): Row[] {
    const ids = this.params as string[];
    return ids
      .map((id) => this.store.findById("bot_outbox", String(id)))
      .filter((r): r is Row => r !== null);
  }

  // ── SELECT cols FROM bot_outbox WHERE id = ? AND tenant_id = ?
  private selectByIdAndTenant(): Row[] {
    const [id, tenantId] = this.params as [string, string];
    const row = this.store.findById("bot_outbox", String(id));
    if (!row || row.tenant_id !== tenantId) return [];
    return [row];
  }

  // ── UPDATE SET status='claimed', attempt+1 WHERE id=? AND (status='pending' OR expired)
  private updateClaimRow(): number {
    // params: leaseUntil, claimedAt, id, nowForLeaseCheck, nowForNextAttempt
    const [leaseUntil, claimedAt, id, now] = this.params as [string, string, string, string];
    const row = this.store.findById("bot_outbox", String(id));
    if (!row) return 0;
    const eligible =
      row.status === "pending" ||
      (row.status === "claimed" && row.lease_until != null && String(row.lease_until) < String(now));
    if (!eligible) return 0;
    const nextEligible = row.next_attempt_at == null || String(row.next_attempt_at) <= String(now);
    if (!nextEligible) return 0;
    this.store.updateById("bot_outbox", String(id), {
      status: "claimed",
      lease_until: leaseUntil,
      attempt: Number(row.attempt ?? 0) + 1,
      updated_at: claimedAt,
    });
    return 1;
  }

  // ── UPDATE SET status='done' (literal), send_message_id=COALESCE, delivered_verified, completed_at
  // SQL: SET status = 'done', send_message_id = COALESCE(send_message_id, ?), ...
  // Bind params: (send_message_id, delivered_verified, completed_at, now, id, tenant_id)
  private updateDoneRow(): number {
    const [sendMsgId, deliveredVerified, completedAt, now, id, tenantId] =
      this.params as [string | null, number, string, string, string, string];
    const row = this.store.findById("bot_outbox", String(id));
    if (!row || row.tenant_id !== tenantId) return 0;
    // COALESCE(send_message_id, ?) — keep existing if non-null
    const finalSendMsgId = (row.send_message_id != null) ? row.send_message_id : sendMsgId;
    this.store.updateById("bot_outbox", String(id), {
      status: "done",
      send_message_id: finalSendMsgId,
      delivered_verified: deliveredVerified,
      completed_at: completedAt,
      lease_until: null,
      updated_at: now,
    });
    return 1;
  }

  // ── UPDATE SET status=?, next_attempt_at=?, last_error_code=?, ...
  private updateFailRow(): number {
    // params: status, next_attempt_at, error_code, error_msg, now, id, tenant_id
    const [newStatus, nextAttemptAt, errorCode, errorMsg, now, id, tenantId] =
      this.params as [string, string | null, string, string | null, string, string, string];
    const row = this.store.findById("bot_outbox", String(id));
    if (!row || row.tenant_id !== tenantId) return 0;
    this.store.updateById("bot_outbox", String(id), {
      status: newStatus,
      next_attempt_at: nextAttemptAt,
      last_error_code: errorCode,
      last_error_msg: errorMsg,
      lease_until: null,
      updated_at: now,
    });
    return 1;
  }

  // ── INSERT INTO bot_outbox (..., status, ...) VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, ?)
  // Note: status is a SQL literal 'pending', not a bind param — only 8 params are bound.
  // Bind order: id, tenant_id, kind, to_recipient, text, idempotency_key, created_at, updated_at
  private insertOutbox(): number {
    const [id, tenant_id, kind, to_recipient, text, idempotency_key, created_at, updated_at] =
      this.params as string[];
    return this.store.upsert("bot_outbox", {
      id, tenant_id, kind, to_recipient, text,
      status: "pending",  // literal in SQL
      idempotency_key, created_at, updated_at,
      lease_until: null, attempt: 0, next_attempt_at: null,
      last_error_code: null, last_error_msg: null,
      send_message_id: null, delivered_verified: null, completed_at: null,
    });
  }

  // ── INSERT OR IGNORE INTO wechat_inbound_events
  private insertInboundEvent(): number {
    const [
      event_id, tenant_id, received_at,
      conversation_id, is_group, sender_wxid, sender_display_name,
      message_kind, text, is_mentioned, from_self, raw_event,
    ] = this.params as unknown[];
    return this.store.upsert(
      "wechat_inbound_events",
      {
        event_id, tenant_id, received_at,
        conversation_id, is_group, sender_wxid, sender_display_name,
        message_kind, text, is_mentioned, from_self, raw_event,
      },
      true // OR IGNORE
    );
  }

  // ─── D1PreparedStatement interface ─────────────────────────────────────────

  async run<T = Record<string, unknown>>(): Promise<D1Result<T>> {
    const { changes } = this.dispatch();
    return {
      results: [] as T[],
      success: true,
      meta: { changed_db: changes > 0, changes, duration: 0, last_row_id: 0, rows_read: 0, rows_written: changes, size_after: 0 },
    };
  }

  async all<T = Record<string, unknown>>(): Promise<D1Result<T>> {
    const { rows } = this.dispatch();
    return {
      results: rows as T[],
      success: true,
      meta: { changed_db: false, changes: 0, duration: 0, last_row_id: 0, rows_read: rows.length, rows_written: 0, size_after: 0 },
    };
  }

  async first<T = Record<string, unknown>>(_col?: string): Promise<T | null> {
    const { rows } = this.dispatch();
    return (rows[0] as T) ?? null;
  }

  async raw<T = unknown[]>(options?: { columnNames?: boolean }): Promise<T[] | [string[], ...T[]]> {
    const { rows } = this.dispatch();
    if (options?.columnNames) {
      const cols = rows.length > 0 ? Object.keys(rows[0]) : [];
      return [cols, ...rows.map((r) => Object.values(r))] as [string[], ...T[]];
    }
    return rows.map((r) => Object.values(r)) as T[];
  }
}

// ─── Public API ───────────────────────────────────────────────────────────────

export function createTestDb(): InMemoryD1 {
  return new InMemoryD1();
}

export function makeEnv(
  d1: InMemoryD1,
  overrides: Partial<{
    BOT_API_TOKEN: string;
    WEBHOOK_SECRET: string;
    LEASE_SECONDS: string;
    MAX_ATTEMPTS: string;
  }> = {}
): Env {
  return {
    DB: d1 as unknown as D1Database,
    BOT_API_TOKEN: overrides.BOT_API_TOKEN ?? "test-token",
    WEBHOOK_SECRET: overrides.WEBHOOK_SECRET ?? "test-secret",
    LEASE_SECONDS: overrides.LEASE_SECONDS ?? "60",
    MAX_ATTEMPTS: overrides.MAX_ATTEMPTS ?? "5",
  };
}

export function authHeader(token = "test-token"): Record<string, string> {
  return { Authorization: `Bearer ${token}` };
}

export async function buildSignature(
  secret: string,
  body: string,
  overrideT?: number
): Promise<string> {
  const t = overrideT ?? Math.floor(Date.now() / 1000);
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  );
  const sigBuffer = await crypto.subtle.sign("HMAC", key, enc.encode(`${t}.${body}`));
  const hex = Array.from(new Uint8Array(sigBuffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return `t=${t},v1=${hex}`;
}

export function readTable(d1: InMemoryD1, tableName: string): Row[] {
  return d1.readTable(tableName);
}

export function seedTable(d1: InMemoryD1, tableName: string, rows: Row[]): void {
  d1.seed(tableName, rows);
}
