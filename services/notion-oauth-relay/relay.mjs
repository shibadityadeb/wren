// Wren's Notion OAuth relay. Run by Wren's maintainers; users never interact with it directly.
//
// Notion's token, refresh and revoke endpoints need the public integration's client secret,
// which must never ship inside the Wren app. This relay holds that secret and does exactly
// four things:
//   GET  /notion/callback  Notion redirects the browser here; the relay bounces it to Wren's
//                          loopback listener (http://127.0.0.1:<port>/notion/callback). The port
//                          comes from `state`, which Wren generates and checks.
//   POST /notion/token     {code}           -> Notion authorization_code exchange
//   POST /notion/refresh   {refresh_token}  -> Notion refresh_token grant
//   POST /notion/revoke    {token}          -> Notion token revocation
// It stores nothing, logs no request or response bodies, and sends no CORS headers.
//
// Configuration (secrets in the hosting platform, never in Git):
//   NOTION_CLIENT_ID, NOTION_CLIENT_SECRET, PUBLIC_URL (this relay's own https base URL)
//
// Deploy as a Cloudflare Worker (`export default { fetch }`) or any runtime with the
// standard fetch API. See docs/MAINTAINER_SETUP.md.

const NOTION = "https://api.notion.com/v1";
const NOTION_VERSION = "2026-03-11";
const MAX_BODY = 4096;
const STATE = /^(\d{4,5})\.([A-Za-z0-9_-]{20,128})$/;
const TOKENISH = /^[A-Za-z0-9._~-]{1,1024}$/;
const ERROR_CODE = /^[a-z_]{1,64}$/;

const SECURITY_HEADERS = {
  "cache-control": "no-store",
  "referrer-policy": "no-referrer",
  "x-content-type-options": "nosniff",
};

function json(status, body) {
  return new Response(JSON.stringify(body), { status, headers: { ...SECURITY_HEADERS, "content-type": "application/json" } });
}

function text(status, body) {
  return new Response(body, { status, headers: { ...SECURITY_HEADERS, "content-type": "text/plain; charset=utf-8" } });
}

function config(env) {
  const id = env.NOTION_CLIENT_ID, secret = env.NOTION_CLIENT_SECRET, base = env.PUBLIC_URL;
  if (!id || !secret || !base || !base.startsWith("https://")) return null;
  return { id, secret, redirectURI: base.replace(/\/+$/, "") + "/notion/callback" };
}

/** Browser redirect from Notion -> Wren's loopback listener. Only a well-formed state is honoured. */
export function callback(url) {
  const state = url.searchParams.get("state") ?? "";
  const m = STATE.exec(state);
  const port = m ? Number(m[1]) : 0;
  if (!m || port < 1024 || port > 65535 || url.searchParams.getAll("state").length !== 1) {
    return text(400, "This sign-in link is not valid. Return to Wren and try connecting again.");
  }
  const target = new URL(`http://127.0.0.1:${port}/notion/callback`);
  const code = url.searchParams.get("code");
  const error = url.searchParams.get("error");
  if (code && TOKENISH.test(code)) target.searchParams.set("code", code);
  else target.searchParams.set("error", error && ERROR_CODE.test(error) ? error : "access_denied");
  target.searchParams.set("state", state);
  return new Response(null, { status: 302, headers: { ...SECURITY_HEADERS, location: target.toString() } });
}

async function readJSON(request) {
  if (!(request.headers.get("content-type") ?? "").toLowerCase().startsWith("application/json")) return null;
  const raw = await request.text();
  if (raw.length > MAX_BODY) return null;
  try { const v = JSON.parse(raw); return v && typeof v === "object" && !Array.isArray(v) ? v : null; } catch { return null; }
}

async function notion(cfg, path, body, fetchImpl) {
  let response;
  try {
    response = await fetchImpl(`${NOTION}${path}`, {
      method: "POST",
      headers: {
        authorization: "Basic " + btoa(`${cfg.id}:${cfg.secret}`),
        "content-type": "application/json",
        "notion-version": NOTION_VERSION,
      },
      body: JSON.stringify(body),
    });
  } catch {
    return json(502, { error: "temporarily_unavailable", error_description: "Notion could not be reached." });
  }
  let data = {};
  try { data = await response.json(); } catch { data = {}; }
  if (!response.ok) {
    const code = typeof data.error === "string" && ERROR_CODE.test(data.error) ? data.error : (response.status >= 500 ? "temporarily_unavailable" : "invalid_request");
    const status = response.status >= 500 ? 502 : response.status;
    return json(status, { error: code, error_description: "Notion rejected the request." });
  }
  return { data };
}

/** Only the fields Wren uses are returned. */
export function tokenFields(d) {
  const out = {};
  for (const k of ["access_token", "refresh_token", "bot_id", "workspace_id", "workspace_name", "workspace_icon"]) {
    if (typeof d[k] === "string") out[k] = d[k];
  }
  if (typeof d.expires_in === "number") out.expires_in = d.expires_in;
  const name = d.owner?.user?.name;
  if (typeof name === "string") out.owner_name = name;
  return out;
}

export async function handle(request, env, fetchImpl = fetch) {
  const url = new URL(request.url);
  if (request.method === "GET" && url.pathname === "/notion/callback") return callback(url);
  if (request.method !== "POST" || !["/notion/token", "/notion/refresh", "/notion/revoke"].includes(url.pathname)) {
    return text(404, "Not found");
  }
  const cfg = config(env);
  if (!cfg) return json(503, { error: "temporarily_unavailable", error_description: "Relay not configured." });
  const body = await readJSON(request);
  if (!body) return json(400, { error: "invalid_request", error_description: "Expected a small JSON body." });

  if (url.pathname === "/notion/token") {
    if (typeof body.code !== "string" || !TOKENISH.test(body.code)) return json(400, { error: "invalid_request", error_description: "Missing code." });
    const r = await notion(cfg, "/oauth/token", { grant_type: "authorization_code", code: body.code, redirect_uri: cfg.redirectURI }, fetchImpl);
    return r instanceof Response ? r : json(200, tokenFields(r.data));
  }
  if (url.pathname === "/notion/refresh") {
    if (typeof body.refresh_token !== "string" || !TOKENISH.test(body.refresh_token)) return json(400, { error: "invalid_request", error_description: "Missing refresh_token." });
    const r = await notion(cfg, "/oauth/token", { grant_type: "refresh_token", refresh_token: body.refresh_token }, fetchImpl);
    return r instanceof Response ? r : json(200, tokenFields(r.data));
  }
  if (typeof body.token !== "string" || !TOKENISH.test(body.token)) return json(400, { error: "invalid_request", error_description: "Missing token." });
  const r = await notion(cfg, "/oauth/revoke", { token: body.token }, fetchImpl);
  return r instanceof Response ? r : json(200, { revoked: true });
}

export default { fetch: (request, env) => handle(request, env) };
