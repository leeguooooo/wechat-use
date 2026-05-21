/**
 * wechat-skill v1.12 SaaS orchestrate template
 *
 * Entry point — mounts all 4 protocol endpoints + cron lease-reset handler.
 *
 * Endpoints:
 *   GET  /api/wechat-outbox/claim       → outbox.ts
 *   POST /api/wechat-outbox/:id/done    → outbox.ts
 *   POST /api/wechat-outbox/:id/fail    → outbox.ts
 *   POST /api/wechat-inbound            → inbound.ts
 */

import { Hono } from "hono";
import { bearerAuth } from "./auth.js";
import { outbox } from "./outbox.js";
import { inbound } from "./inbound.js";
import { type Env } from "./types.js";

const app = new Hono<{ Bindings: Env }>();

// ─── Auth middleware ───────────────────────────────────────────────────────────
// Applied to all /api/* routes before dispatching to sub-apps.
app.use("/api/*", bearerAuth());

// ─── Mount sub-apps ───────────────────────────────────────────────────────────
app.route("/api/wechat-outbox", outbox);
app.route("/api/wechat-inbound", inbound);

// ─── Health check (no auth) ────────────────────────────────────────────────────
app.get("/health", (c) => c.json({ ok: true, protocol: "v1.12" }));

// ─── Cron: reset expired leases ───────────────────────────────────────────────
// Runs every minute (see wrangler.toml [triggers]).
// Finds rows where status='claimed' AND lease_until < now, resets to 'pending'.
//
// Spec note (§5): "SaaS 端必做 — 周期性把 claimed AND lease_until < now 重置为 pending"
//
// This inline approach avoids burning Cron Trigger quota (5-limit on free plan).
// For high-volume deployments, move to a Durable Object alarm or Queue consumer.
async function resetExpiredLeases(db: D1Database): Promise<number> {
  const now = new Date().toISOString();
  const result = await db
    .prepare(
      `UPDATE bot_outbox
          SET status = 'pending',
              lease_until = NULL,
              updated_at = ?
        WHERE status = 'claimed'
          AND lease_until < ?`
    )
    .bind(now, now)
    .run();
  return result.meta.changes ?? 0;
}

export default {
  fetch: app.fetch,

  async scheduled(
    _event: ScheduledEvent,
    env: Env,
    _ctx: ExecutionContext
  ): Promise<void> {
    const reset = await resetExpiredLeases(env.DB);
    if (reset > 0) {
      console.log(`[cron] reset ${reset} expired leases → pending`);
    }
  },
};
