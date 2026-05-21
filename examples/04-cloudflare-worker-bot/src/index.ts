/**
 * wechat-skill Cloudflare Worker bot example (v1.11 remote gateway)
 *
 * Flow:
 *   1. POST /gateway-token  → profile-api → get 1h JWT + tunnel URL
 *   2. GET  /v1/sessions    → REST bridge (via CF Tunnel) → verify connectivity
 *   3. POST /v1/send        → REST bridge (via CF Tunnel) → deliver message
 *
 * Required secrets (wrangler secret put):
 *   WECHAT_USER_TOKEN   — from `wechat auth status`
 *   WECHAT_MACHINE_ID   — from `wechat auth status`
 *   TARGET_WXID         — recipient wxid (use "filehelper" for safe testing)
 *
 * Optional env var (set in wrangler.toml [vars]):
 *   PROFILE_API_URL     — defaults to https://wxp.leeguoo.com
 */

export interface Env {
  /** wechat-skill user token (wxp_tok_...) — set via `wrangler secret put` */
  WECHAT_USER_TOKEN: string;
  /** Machine ID reported by `wechat auth status` — set via `wrangler secret put` */
  WECHAT_MACHINE_ID: string;
  /** Recipient wxid for the demo message — set via `wrangler secret put` */
  TARGET_WXID: string;
  /** Profile API base URL. Defaults to https://wxp.leeguoo.com (set in wrangler.toml). */
  PROFILE_API_URL: string;
}

interface GatewayTokenResponse {
  jwt: string;
  exp: number;       // Unix timestamp (seconds) when the JWT expires
  tunnel_url: string; // e.g. "abc123.cfargotunnel.com" — no protocol prefix
}

/**
 * Exchange the user token + machine ID for a short-lived ES256 JWT.
 * The JWT is valid for 1 hour; tunnelUrl tells us which CF Tunnel to call.
 */
async function getGatewayToken(env: Env): Promise<{ jwt: string; tunnelUrl: string }> {
  const profileApi = env.PROFILE_API_URL ?? 'https://wxp.leeguoo.com';

  const resp = await fetch(`${profileApi}/gateway-token`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      user_token: env.WECHAT_USER_TOKEN,
      machine_id: env.WECHAT_MACHINE_ID,
    }),
  });

  if (!resp.ok) {
    const body = await resp.text();
    throw new Error(`gateway-token request failed (${resp.status}): ${body}`);
  }

  const data = (await resp.json()) as GatewayTokenResponse;
  return { jwt: data.jwt, tunnelUrl: data.tunnel_url };
}

/**
 * Call GET /v1/sessions on the REST bridge to confirm the tunnel is reachable.
 * Returns the raw JSON string for the response body (we pass it through).
 */
async function checkSessions(tunnelUrl: string, jwt: string): Promise<unknown> {
  const resp = await fetch(`https://${tunnelUrl}/v1/sessions?limit=5`, {
    headers: { authorization: `Bearer ${jwt}` },
  });
  if (!resp.ok) {
    throw new Error(`/v1/sessions failed (${resp.status}): ${await resp.text()}`);
  }
  return resp.json();
}

/**
 * Send a text message via the REST bridge.
 * POST /v1/send  body: { to: wxid, text: string }
 */
async function sendMessage(
  tunnelUrl: string,
  jwt: string,
  to: string,
  text: string,
): Promise<unknown> {
  const resp = await fetch(`https://${tunnelUrl}/v1/send`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${jwt}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify({ to, text }),
  });

  if (!resp.ok) {
    throw new Error(`/v1/send failed (${resp.status}): ${await resp.text()}`);
  }
  return resp.json();
}

// ---------------------------------------------------------------------------
// Worker entry point
// ---------------------------------------------------------------------------

export default {
  /**
   * Called on every incoming HTTP request.
   * In production you'd use a scheduled trigger (cron) or a webhook handler;
   * this example responds to any fetch so you can curl it to test.
   */
  async fetch(req: Request, env: Env): Promise<Response> {
    // Only GET and HEAD are expected; ignore favicons etc.
    if (req.method !== 'GET' && req.method !== 'POST') {
      return new Response('Method Not Allowed', { status: 405 });
    }

    try {
      // Step 1: get a short-lived JWT from the profile API
      const { jwt, tunnelUrl } = await getGatewayToken(env);

      // Step 2: verify the tunnel is reachable by listing recent sessions
      const sessions = await checkSessions(tunnelUrl, jwt);

      // Step 3: send a demo message to the configured target wxid
      const target = env.TARGET_WXID;
      const sendResult = await sendMessage(tunnelUrl, jwt, target, 'hello from worker');

      // Return a summary so the caller can see what happened
      return Response.json({
        ok: true,
        tunnelUrl,
        sessions,
        sendResult,
      });
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      return Response.json({ ok: false, error: message }, { status: 500 });
    }
  },
} satisfies ExportedHandler<Env>;
