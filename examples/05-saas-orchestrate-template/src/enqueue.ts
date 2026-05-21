/**
 * enqueueWechatOutbox — helper for business code to schedule a WeChat send.
 *
 * Usage from your own Worker route or scheduled handler:
 *
 *   import { enqueueWechatOutbox } from './enqueue.js';
 *
 *   // Send a message to a specific wxid:
 *   const { id } = await enqueueWechatOutbox(env, {
 *     to: 'wxid_abc123',
 *     text: '您好，您的订单 #1234 已确认，预计 3 天内送达。',
 *   });
 *
 *   // With idempotency key (prevents double-send on retry):
 *   await enqueueWechatOutbox(env, {
 *     to: 'group_room@chatroom',
 *     text: '今日早报 ...',
 *     idempotency_key: `daily-report-${today}`,
 *     kind: 'daily_report',
 *   });
 *
 * The Mac's `wechat orchestrate` process polls GET /api/wechat-outbox/claim
 * and drains rows from this table.
 */

import { type Env } from "./types.js";

export interface EnqueueParams {
  /** wxid / room_id@chatroom / display_name — wechat-skill resolves it */
  to: string;
  /** Message text */
  text: string;
  /**
   * Stable idempotency key.  wechat-skill passes this to /v1/send to prevent
   * duplicate sends on retry.  Auto-generated from row id if not supplied.
   */
  idempotency_key?: string;
  /**
   * Tenant scope.  Leave as 'default' for single-tenant deployments.
   * For multi-tenant: pass the tenant_id from your auth context.
   */
  tenant_id?: string;
  /**
   * Business-level label — useful for filtering / reporting.
   * Examples: 'order_confirm', 'daily_report', 'alert'
   */
  kind?: string;
}

export interface EnqueueResult {
  /** Row id — "out_<20 hex chars>" */
  id: string;
}

export async function enqueueWechatOutbox(
  env: Env,
  params: EnqueueParams
): Promise<EnqueueResult> {
  const id = `out_${crypto.randomUUID().replace(/-/g, "").slice(0, 20)}`;
  const idempotency_key = params.idempotency_key ?? id;
  const tenant_id = params.tenant_id ?? "default";
  const kind = params.kind ?? "message";
  const now = new Date().toISOString();

  await env.DB.prepare(
    `INSERT INTO bot_outbox
        (id, tenant_id, kind, to_recipient, text, status, idempotency_key, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, ?)`
  )
    .bind(id, tenant_id, kind, params.to, params.text, idempotency_key, now, now)
    .run();

  return { id };
}
