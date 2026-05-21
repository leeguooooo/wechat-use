-- wechat-skill v1.12 orchestrate protocol — minimal D1 schema
-- Run: wrangler d1 migrations apply wechat-orchestrate-db [--local]

-- ─── Outbox ───────────────────────────────────────────────────────────────────
-- Stores messages your business code wants to send via the subscriber's Mac.
-- Mac polls GET /api/wechat-outbox/claim and drains this queue.
CREATE TABLE IF NOT EXISTS bot_outbox (
  id               TEXT    NOT NULL PRIMARY KEY,  -- "out_<20 hex chars>"
  tenant_id        TEXT    NOT NULL DEFAULT 'default',

  -- What to send
  to_recipient     TEXT    NOT NULL,   -- wxid / room_id@chatroom / display_name
  text             TEXT    NOT NULL,
  kind             TEXT    NOT NULL DEFAULT 'message',  -- business label (e.g. 'order_confirm')

  -- State machine: pending | claimed | done | failed
  status           TEXT    NOT NULL DEFAULT 'pending',

  -- Idempotency: SaaS writes a stable key; Mac passes it to wechat-skill /v1/send
  -- to prevent double-sends on retry.  Defaults to the row id if not supplied.
  idempotency_key  TEXT    NOT NULL,

  -- Lease (visibility timeout).  NULL while pending/done/failed.
  -- Rows with status='claimed' AND lease_until < now() are auto-reset to 'pending'
  -- by the scheduled cron handler.
  lease_until      TEXT,               -- ISO-8601 UTC

  -- Retry tracking
  attempt          INTEGER NOT NULL DEFAULT 0,
  next_attempt_at  TEXT,               -- ISO-8601 UTC; NULL = eligible immediately
  last_error_code  TEXT,
  last_error_msg   TEXT,

  -- Completion receipts (from POST /done)
  send_message_id      TEXT,           -- wechat-skill server_id (may be NULL for old clients)
  delivered_verified   INTEGER,        -- 1 = wechat-skill confirmed DB write
  completed_at         TEXT,           -- ISO-8601 UTC

  created_at       TEXT    NOT NULL,   -- ISO-8601 UTC
  updated_at       TEXT    NOT NULL    -- ISO-8601 UTC
);

-- Primary query pattern: claim N rows eligible for processing
CREATE INDEX IF NOT EXISTS idx_outbox_status_next_attempt
  ON bot_outbox (status, next_attempt_at, created_at);

-- Lease expiry scan (cron)
CREATE INDEX IF NOT EXISTS idx_outbox_claimed_lease
  ON bot_outbox (status, lease_until)
  WHERE status = 'claimed';

-- ─── Inbound events ───────────────────────────────────────────────────────────
-- Dedupe table for POST /api/wechat-inbound.
-- Mac pushes every SSE event here; event_id is the primary dedup key.
-- Your business logic runs AFTER the INSERT; see src/inbound.ts.
CREATE TABLE IF NOT EXISTS wechat_inbound_events (
  event_id         TEXT    NOT NULL PRIMARY KEY,  -- from event.event_id or X-Idempotency-Key
  tenant_id        TEXT    NOT NULL DEFAULT 'default',
  received_at      TEXT    NOT NULL,   -- ISO-8601 UTC (server arrival time)

  -- Normalized fields (spec §3.4 "normalized" object) — indexed for common queries
  conversation_id       TEXT,
  is_group              INTEGER,       -- 1 = group, 0 = DM
  sender_wxid           TEXT,
  sender_display_name   TEXT,
  message_kind          TEXT,          -- text | image | voice | video | file | url | quote | recall | system | mp
  text                  TEXT,
  is_mentioned          INTEGER,       -- 1 = bot was @-mentioned
  from_self             INTEGER,       -- 1 = sent by the subscriber themselves

  -- Full raw payload stored as JSON text for business logic that needs it
  raw_event        TEXT                -- JSON blob, wechat-skill SSE payload
);

-- Common query: all unhandled mentions in a group
CREATE INDEX IF NOT EXISTS idx_inbound_conversation_received
  ON wechat_inbound_events (conversation_id, received_at);

-- ─── API tokens ───────────────────────────────────────────────────────────────
-- Placeholder for per-tenant token management.
-- For a minimal single-tenant deployment, use the BOT_API_TOKEN env var
-- (see src/auth.ts) and leave this table empty.
--
-- For multi-tenant: insert one row per subscriber; set auth.ts to query here
-- instead of checking env BOT_API_TOKEN.
CREATE TABLE IF NOT EXISTS bot_api_tokens (
  id          TEXT    NOT NULL PRIMARY KEY,  -- "tok_<20 hex>"
  tenant_id   TEXT    NOT NULL,
  token_hash  TEXT    NOT NULL UNIQUE,   -- SHA-256 hex of the raw bearer token
  scopes      TEXT    NOT NULL DEFAULT '["outbox:claim","outbox:complete","inbound:write"]',
  created_at  TEXT    NOT NULL,
  expires_at  TEXT,                      -- NULL = no expiry (recommended; see spec §1)
  revoked_at  TEXT                       -- non-NULL = revoked
);

CREATE INDEX IF NOT EXISTS idx_tokens_hash ON bot_api_tokens (token_hash);
