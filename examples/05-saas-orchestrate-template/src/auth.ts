/**
 * Bearer token middleware — minimal single-token implementation.
 *
 * UPGRADE PATH TO MULTI-TENANT:
 *   1. Remove BOT_API_TOKEN from wrangler.toml [vars] / secrets.
 *   2. In the middleware below, replace the env check with:
 *
 *      const tokenHash = await sha256hex(raw);
 *      const row = await env.DB.prepare(
 *        `SELECT tenant_id, scopes, revoked_at, expires_at
 *           FROM bot_api_tokens WHERE token_hash = ?`
 *      ).bind(tokenHash).first<{ tenant_id: string; scopes: string; revoked_at: string|null; expires_at: string|null }>();
 *
 *      if (!row || row.revoked_at) return c.json({ error: 'invalid_token' }, 401);
 *      if (row.expires_at && new Date(row.expires_at) < new Date()) return c.json({ error: 'token_expired' }, 401);
 *      c.set('tenantId', row.tenant_id);
 *
 *   3. Issue tokens at signup time (see enqueue.ts for the INSERT helper pattern).
 */

import { type Context, type MiddlewareHandler } from "hono";
import { type Env } from "./types.js";

declare module "hono" {
  interface ContextVariableMap {
    tenantId: string;
  }
}

export function bearerAuth(): MiddlewareHandler<{ Bindings: Env }> {
  return async (c: Context<{ Bindings: Env }>, next) => {
    const authHeader = c.req.header("Authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      return c.json({ error: "missing_authorization" }, 401);
    }

    const raw = authHeader.slice("Bearer ".length).trim();
    const expected = c.env.BOT_API_TOKEN;

    if (!expected) {
      // Misconfiguration: secret not set
      console.error("[auth] BOT_API_TOKEN is not configured");
      return c.json({ error: "server_misconfigured" }, 500);
    }

    // Constant-time comparison to prevent timing attacks
    if (!(await timingSafeEqual(raw, expected))) {
      return c.json({ error: "invalid_token" }, 401);
    }

    // For single-tenant mode, tenantId is always 'default'.
    // Multi-tenant: set from D1 row (see upgrade path above).
    c.set("tenantId", "default");
    await next();
  };
}

/**
 * Constant-time string comparison using Web Crypto.
 * Encodes both strings as UTF-8 then runs HMAC so length-difference leaks
 * are avoided at the comparison level.
 */
async function timingSafeEqual(a: string, b: string): Promise<boolean> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode("wechat-skill-const-time"),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sigA = await crypto.subtle.sign("HMAC", key, enc.encode(a));
  const sigB = await crypto.subtle.sign("HMAC", key, enc.encode(b));
  // Compare the HMAC outputs — same input → same output in constant time
  const va = new Uint8Array(sigA);
  const vb = new Uint8Array(sigB);
  if (va.length !== vb.length) return false;
  let diff = 0;
  for (let i = 0; i < va.length; i++) {
    diff |= va[i] ^ vb[i];
  }
  return diff === 0;
}
