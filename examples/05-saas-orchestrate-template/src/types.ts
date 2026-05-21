/**
 * wechat-skill v1.12 orchestrate protocol — shared types
 *
 * Mirrors the shapes defined in docs/v1.12-orchestrate-protocol.md.
 * Do not import business logic from here; keep this file data-only.
 */

// ─── Env bindings ─────────────────────────────────────────────────────────────

export interface Env {
  DB: D1Database;

  /**
   * Single bearer token for minimal single-tenant deployments.
   *
   * For multi-tenant production:
   *   - Remove this var from wrangler.toml
   *   - Query the bot_api_tokens D1 table instead (see src/auth.ts)
   */
  BOT_API_TOKEN: string;

  /**
   * Shared secret for HMAC-SHA256 inbound webhook signature verification.
   * Generate: openssl rand -hex 32
   */
  WEBHOOK_SECRET: string;

  /** Lease duration in seconds (default "60") */
  LEASE_SECONDS?: string;

  /** Max retry attempts before hard-failing (default "5") */
  MAX_ATTEMPTS?: string;
}

// ─── Outbox row (as stored in D1) ─────────────────────────────────────────────

export type OutboxStatus = "pending" | "claimed" | "done" | "failed";

export interface OutboxRow {
  id: string;
  tenant_id: string;
  to_recipient: string;
  text: string;
  kind: string;
  status: OutboxStatus;
  idempotency_key: string;
  lease_until: string | null;
  attempt: number;
  next_attempt_at: string | null;
  last_error_code: string | null;
  last_error_msg: string | null;
  send_message_id: string | null;
  delivered_verified: number | null;
  completed_at: string | null;
  created_at: string;
  updated_at: string;
}

// ─── Outbox claim response (spec §3.1) ────────────────────────────────────────

export interface ClaimResponseRow {
  id: string;
  idempotency_key: string;
  to: string;       // maps to to_recipient
  text: string;
  claimed_at: string;
  lease_until: string;
  attempt: number;
}

export interface ClaimResponse {
  rows: ClaimResponseRow[];
}

// ─── Done request body (spec §3.2) ────────────────────────────────────────────

export interface DoneBody {
  send_message_id?: string | null;
  delivered_verified?: boolean;
  completed_at?: string;
}

// ─── Fail request body (spec §3.3) ────────────────────────────────────────────

export type ErrorCode =
  | "send_failed"
  | "resolve_failed"
  | "bridge_unavailable"
  | "wechat_blocked"
  | "hard_invalid"
  | "lease_expired";

export interface FailBody {
  error_code: ErrorCode;
  error_message?: string;
  retryable: boolean;
  failed_at?: string;
}

export interface FailResponse {
  ok: boolean;
  next_attempt_at: string | null;
}

// ─── Inbound event (spec §3.4) ────────────────────────────────────────────────

export type MessageKind =
  | "text"
  | "image"
  | "voice"
  | "video"
  | "file"
  | "url"
  | "quote"
  | "recall"
  | "system"
  | "mp";

export interface NormalizedEvent {
  conversation_id: string;
  is_group: boolean;
  sender_wxid: string;
  sender_display_name: string;
  message_kind: MessageKind;
  text: string;
  is_mentioned: boolean;
  mentioned_ids: string[];
  from_self: boolean;
}

export interface InboundBody {
  event_id: string;
  ts: string;
  normalized: NormalizedEvent;
  raw_event: Record<string, unknown>;
}

// ─── Backoff schedule (spec §2) ───────────────────────────────────────────────

/** Returns seconds to add for attempt N (1-indexed).  Sequence: 30/120/600/1800 */
export function backoffSeconds(attempt: number): number {
  const schedule = [30, 120, 600, 1800] as const;
  const idx = Math.min(attempt - 1, schedule.length - 1);
  return schedule[idx];
}
