# wechat-skill v1.12 SaaS orchestrate template

A minimal **Cloudflare Workers + D1** SaaS that implements the
[v1.12 orchestrate protocol](../../docs/v1.12-orchestrate-protocol.md).
Fork this, fill in your business logic, deploy — and your subscribers'
Macs are connected.

```
Your business code
  └─ enqueueWechatOutbox(env, { to, text })    ← write send tasks into D1
        ↓
  D1 bot_outbox table (your CF Worker)
        ↑ poll (GET /api/wechat-outbox/claim)
Subscriber Mac (wechat orchestrate)
  └─ calls local wechat-skill REST → WeChat app on Mac
        ↓
  POST /api/wechat-outbox/:id/done|fail        ← Mac reports result
  POST /api/wechat-inbound                     ← Mac pushes inbound SSE events
        ↓
  Your handlers (src/inbound.ts dispatch point)
```

No public IP needed on the subscriber's Mac — it's 100% outbound HTTPS.

---

## What this template provides

- 4 v1.12 protocol endpoints (claim / done / fail / inbound)
- Atomic lease-claim via D1 batch — one SQL round-trip, no row locks needed
- Automatic lease reset (visibility timeout) via 1-minute cron trigger
- HMAC-SHA256 webhook signature + 5-minute replay-window check
- event_id deduplication via `INSERT OR IGNORE`
- `enqueueWechatOutbox()` helper — one call to schedule a WeChat send
- Per-tenant D1 schema (single-tenant default; multi-tenant upgrade path
  documented in `src/auth.ts`)
- TypeScript strict — 0 `any`, all spec shapes typed in `src/types.ts`
- Vitest unit + e2e test suite (no wrangler pool, runs in < 2s)

---

## Quick start

### Prerequisites

- [Cloudflare account](https://dash.cloudflare.com/sign-up) (free tier is enough)
- `wrangler` v3+: `npm install -g wrangler`
- Node.js 18+ and npm

### 5 steps

**1. Fork / clone and install**

```bash
cd examples/05-saas-orchestrate-template
npm install
```

**2. Create your D1 database**

```bash
wrangler d1 create wechat-orchestrate-db
```

Copy the `database_id` from the output.  Open `wrangler.toml` and replace
`REPLACE_WITH_YOUR_DATABASE_ID` with it:

```toml
[[d1_databases]]
binding = "DB"
database_name = "wechat-orchestrate-db"
database_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

**3. Apply migrations**

```bash
# Production D1:
wrangler d1 migrations apply wechat-orchestrate-db

# Local dev (creates a local SQLite copy):
wrangler d1 migrations apply wechat-orchestrate-db --local
```

**4. Set secrets**

```bash
# Bearer token — choose any random string, 32+ chars
wrangler secret put BOT_API_TOKEN

# HMAC webhook signing secret — generate with:  openssl rand -hex 32
wrangler secret put WEBHOOK_SECRET
```

**5. Deploy**

```bash
wrangler deploy
```

Your Worker is live at `https://wechat-skill-saas-orchestrate.<your-subdomain>.workers.dev`.

---

## Connect a subscriber Mac

On the subscriber's Mac (wechat-skill v1.12+):

```bash
wechat orchestrate setup \
  --outbox-url=https://wechat-skill-saas-orchestrate.<sub>.workers.dev \
  --webhook-url=https://wechat-skill-saas-orchestrate.<sub>.workers.dev/api/wechat-inbound \
  --bearer=<BOT_API_TOKEN value> \
  --webhook-secret=<WEBHOOK_SECRET value>
```

Then start the orchestrate loop:

```bash
wechat orchestrate start
```

The Mac will begin polling `GET /api/wechat-outbox/claim` every 1-5 seconds
and pushing inbound SSE events to `POST /api/wechat-inbound`.

---

## Local development

```bash
cp .dev.vars.example .dev.vars
# Edit .dev.vars with real values

wrangler dev --local
```

Run typecheck + tests:

```bash
npm run typecheck   # tsc --noEmit, 0 errors expected
npm test            # vitest run
```

---

## Endpoints

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/wechat-outbox/claim?limit=N` | Mac claims N pending send tasks |
| `POST` | `/api/wechat-outbox/:id/done` | Mac reports send success (idempotent) |
| `POST` | `/api/wechat-outbox/:id/fail` | Mac reports send failure + schedules retry |
| `POST` | `/api/wechat-inbound` | Mac pushes inbound WeChat message event |
| `GET` | `/health` | Health check (no auth required) |

All `/api/*` routes require `Authorization: Bearer <BOT_API_TOKEN>`.

---

## Sending a WeChat message from your business code

```typescript
import { enqueueWechatOutbox } from "./src/enqueue.js";

// In any Worker route / scheduled handler / Queue consumer:
export default {
  async fetch(req: Request, env: Env) {
    await enqueueWechatOutbox(env, {
      to: "wxid_customer123",          // wxid / room_id@chatroom / display_name
      text: "您的订单 #4567 已发货 ✓",
      idempotency_key: "order-4567-shipped-msg-1",  // prevents double-send on retry
      kind: "order_update",            // custom business label
    });
    return new Response("queued", { status: 202 });
  },
};
```

The Mac's orchestrate loop picks it up within its poll interval (1-5s) and
calls the local wechat-skill REST endpoint to actually send.

---

## Receiving inbound messages

Edit `src/inbound.ts` — find the **DISPATCH POINT** comment block and add your handlers:

```typescript
// After dedupe INSERT succeeds:
if (normalized.is_mentioned && normalized.message_kind === "text") {
  await handleMention(c.env, tenantId, body);
}

if (!normalized.is_group && !normalized.from_self) {
  await handleDM(c.env, tenantId, body);
}
```

`body.normalized` has the stable 8-field subset.  For media / quote / recall
details use `body.raw_event` (full wechat-skill SSE payload).

---

## Customizing for your business

### Add business fields to the schema

The schema in `migrations/0001_init.sql` is intentionally minimal.  Add your
own columns in a new migration file:

```bash
# Create migration:
wrangler d1 migrations create wechat-orchestrate-db add-order-id
# Then edit migrations/0002_add_order_id.sql
```

### Multi-tenant setup

The template ships with a single `BOT_API_TOKEN` env var (one Mac, one
subscriber).  To support multiple subscribers:

1. Read the upgrade path in `src/auth.ts` — it's a 15-line D1 query change.
2. Use the `bot_api_tokens` table (already in the schema) to store per-tenant
   token hashes.
3. Issue a unique `BOT_API_TOKEN` to each subscriber at onboarding time and
   INSERT into `bot_api_tokens`.

### Backoff / retry tuning

Edit `MAX_ATTEMPTS` in `wrangler.toml [vars]` (default 5).  The backoff
schedule (30s/2min/10min/30min) is in `src/types.ts → backoffSeconds()`.

---

## What this template does NOT include

- Per-tenant token system (uses single `BOT_API_TOKEN`; see `src/auth.ts`)
- Customer routing (group A → handler B)
- LLM tool-calling or AI reply generation
- Admin dashboard / monitoring UI
- Order-flow / magic-link integrations

These are business-specific.  The template gives you the protocol plumbing;
you add the domain logic.

---

## File reference

```
05-saas-orchestrate-template/
├── src/
│   ├── index.ts        # Hono app entry + cron lease-reset handler
│   ├── outbox.ts       # GET claim / POST done / POST fail endpoints
│   ├── inbound.ts      # POST /api/wechat-inbound + HMAC verification
│   ├── auth.ts         # Bearer token middleware + multi-tenant upgrade path
│   ├── enqueue.ts      # enqueueWechatOutbox() helper for business code
│   └── types.ts        # Protocol types + backoff schedule
├── migrations/
│   └── 0001_init.sql   # bot_outbox + wechat_inbound_events + bot_api_tokens
├── tests/
│   ├── helpers.ts      # In-memory D1 stub + env factory + sig builder
│   ├── outbox.test.ts  # State machine / idempotency / lease tests
│   ├── inbound.test.ts # HMAC / dedupe / error body tests
│   └── e2e.test.ts     # enqueue → claim → done full flow
├── wrangler.toml       # CF Worker config template
├── package.json
├── tsconfig.json
├── vitest.config.ts
└── .dev.vars.example
```

---

## Protocol reference

Full spec: [`docs/v1.12-orchestrate-protocol.md`](../../docs/v1.12-orchestrate-protocol.md)

Key invariants:
- Subscriber Mac is always outbound (NAT-friendly, no public IP needed)
- State lives in your D1, not on the Mac
- Lease expiry (60s) protects against Mac crashes without manual intervention
- `idempotency_key` prevents double-sends across retries
- `event_id` dedup prevents double-processing across network retries
