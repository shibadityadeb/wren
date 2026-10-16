// Tests the download functions in ../api with Supabase and the network faked (no dependencies).
//   node website/tools/check-api.mjs
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const api = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "api");
const signin = require(join(api, "signin.js"));
const download = require(join(api, "download.js"));
const { release } = require(join(api, "_lib.js"));
const failures = [];
const check = (ok, what) => { if (!ok) failures.push(what); };

function res() {
  const r = { statusCode: 200, headers: {}, body: "" };
  r.setHeader = (k, v) => { r.headers[k.toLowerCase()] = v; };
  r.end = (b = "") => { r.body = b; };
  r.json = () => JSON.parse(r.body || "{}");
  return r;
}
// Fake Supabase API keys shaped like the real ones (JWTs whose payload names the role).
const jwt = (role) => ["e30", Buffer.from(JSON.stringify({ iss: "supabase", ref: "abcdefgh", role })).toString("base64url"), "c2lnbmF0dXJl"].join(".");
const env = { SUPABASE_URL: "https://abcdefgh.supabase.co", SUPABASE_ANON_KEY: jwt("anon") };
// Sets environment variables for one test block (sync or async) and puts the old values back after it.
function restore(saved, e) { for (const k of Object.keys(e)) if (!(k in saved)) delete process.env[k]; Object.assign(process.env, saved); }
function withEnv(e, f) {
  const saved = { ...process.env };
  Object.assign(process.env, e);
  let out;
  try { out = f(); } catch (err) { restore(saved, e); throw err; }
  if (out && typeof out.then === "function") return out.finally(() => restore(saved, e));
  restore(saved, e);
  return out;
}

// Fake Supabase: /auth/v1/user answers for "good-token…", /rest/v1/download_requests records inserts.
let inserts = [], userStatus = 200, insertStatus = 201, provider = "google";
globalThis.fetch = async (url, opts = {}) => {
  const auth = (opts.headers || {}).Authorization || "";
  if (url.endsWith("/auth/v1/user")) {
    if (userStatus !== 200 || !auth.includes("good-token")) return new Response("{}", { status: 401 });
    return new Response(JSON.stringify({ id: "11111111-2222-3333-4444-555555555555", email: "ada@example.com",
      app_metadata: { provider, providers: [provider] }, user_metadata: { full_name: "Ada Lovelace" } }), { status: 200 });
  }
  if (url.endsWith("/rest/v1/download_requests")) { inserts.push({ auth, body: JSON.parse(opts.body) }); return new Response("", { status: insertStatus }); }
  return new Response("not faked", { status: 500 });
};

await withEnv(env, async () => {
  // Sign-in goes to Supabase's Google sign-in and back to /download/ on the same site.
  let r = res(); signin({ headers: { host: "wren-test.vercel.app" } }, r);
  check(r.statusCode === 302 && r.headers.location === "https://abcdefgh.supabase.co/auth/v1/authorize?provider=google&redirect_to=" + encodeURIComponent("https://wren-test.vercel.app/download/"), "signin redirects to Google via Supabase");
  // Only POST.
  r = res(); await download({ method: "GET", headers: {} }, r); check(r.statusCode === 405, "GET is refused");
  // No token, a bad token.
  r = res(); await download({ method: "POST", body: {} }, r); check(r.statusCode === 400 && inserts.length === 0, "no token: 400, nothing recorded");
  r = res(); await download({ method: "POST", body: { access_token: "bad-token-0123456789abcdef" } }, r); check(r.statusCode === 401 && inserts.length === 0, "rejected token: 401, nothing recorded");
  // A real Google sign-in: recorded as that person (their token), then the link.
  r = res(); await download({ method: "POST", body: JSON.stringify({ access_token: "good-token-0123456789abcdef" }) }, r);
  const b = r.json();
  check(r.statusCode === 200 && b.dmg === release().dmg && b.email === "ada@example.com", "signed in: link returned");
  check(inserts.length === 1 && inserts[0].auth === "Bearer good-token-0123456789abcdef" && inserts[0].body.user_id.startsWith("1111") && inserts[0].body.name === "Ada Lovelace" && inserts[0].body.version === release().version, "the download is recorded as the signed-in person");
  check(!r.body.includes("good-token"), "the token is never echoed back");
  // Already recorded (unique per person and version): still the link.
  insertStatus = 409; r = res(); await download({ method: "POST", body: { access_token: "good-token-0123456789abcdef" } }, r); check(r.statusCode === 200, "a repeat download still works");
  // Recording failed: no link (the gate holds).
  insertStatus = 500; r = res(); await download({ method: "POST", body: { access_token: "good-token-0123456789abcdef" } }, r); check(r.statusCode === 502 && !r.json().dmg, "recording failed: no link");
  insertStatus = 201;
  // Signed in some other way than Google: refused.
  provider = "email"; r = res(); await download({ method: "POST", body: { access_token: "good-token-0123456789abcdef" } }, r); check(r.statusCode === 403, "non-Google sign-in refused"); provider = "google";
});
// Not configured: the page says so; nothing is called.
await withEnv({ SUPABASE_URL: "", SUPABASE_ANON_KEY: "" }, async () => {
  let r = res(); signin({ headers: { host: "wren-test.vercel.app" } }, r); check(r.headers.location === "/download/?setup=missing&why=url-missing", "unconfigured sign-in explains itself");
  r = res(); await download({ method: "POST", body: { access_token: "good-token-0123456789abcdef" } }, r); check(r.statusCode === 503, "unconfigured download: 503");
});
// Slips in the settings: harmless ones are forgiven, dangerous ones refused with a reason.
const { config } = require(join(api, "_lib.js"));
const cfg = (url, key = jwt("anon")) => withEnv({ SUPABASE_URL: url, SUPABASE_ANON_KEY: key }, () => config());
for (const u of ['"https://abcdefgh.supabase.co"', " https://abcdefgh.supabase.co/ ", "https://abcdefgh.supabase.co/rest/v1", "https://ABCDEFGH.supabase.co/auth/v1/"]) {
  check(cfg(u).ok && cfg(u).url === "https://abcdefgh.supabase.co", `forgiven URL: ${u}`);
}
check(cfg("postgres://postgres:pw@db.abcdefgh.supabase.co:5432/postgres").problem === "url-database", "a database connection string is refused");
check(cfg("http://abcdefgh.supabase.co").problem === "url-invalid", "plain http is refused");
check(cfg("https://example.com").problem === "url-invalid", "another site is refused");
check(cfg("https://abcdefgh.supabase.co", "").problem === "key-missing", "a missing key is reported");
check(cfg("https://abcdefgh.supabase.co", jwt("service_role")).problem === "key-secret", "the service_role key is refused");
check(cfg("https://abcdefgh.supabase.co", "sb_secret_abcdefghijklmnop").problem === "key-secret", "a secret key is refused");
check(cfg("https://abcdefgh.supabase.co", "sb_publishable_abcdefghijklmnop").ok, "a publishable key is accepted");
check(cfg("https://abcdefgh.supabase.co", `'${jwt("anon")}'`).ok, "a quoted anon key is accepted");
check(cfg("https://abcdefgh.supabase.co", "not-a-key-but-long-enough-0123").problem === "key-invalid", "something else is reported");
await withEnv({ SUPABASE_URL: "postgres://x@db.abcdefgh.supabase.co/postgres", SUPABASE_ANON_KEY: jwt("anon") }, async () => {
  const r = res(); signin({ headers: { host: "wren-test.vercel.app" } }, r);
  check(r.headers.location === "/download/?setup=missing&why=url-database", "sign-in names the problem");
  check(!r.headers.location.includes("postgres"), "never a value");
});
const status = require(join(api, "status.js"));
withEnv({ SUPABASE_URL: "", SUPABASE_ANON_KEY: "" }, () => { const r = res(); status({}, r); check(r.json().downloads === "not set up" && r.json().problem === "url-missing", "status reports the problem"); });
withEnv(env, () => { const r = res(); status({}, r); check(r.json().downloads === "ready" && !r.body.includes("abcdefgh"), "status says ready and shows no values"); });
// Release override.
check(withEnv({ WREN_RELEASE_TAG: "v9.9.9-preview.2" }, () => release().dmg.endsWith("/v9.9.9-preview.2/Wren-macOS-universal-unsigned.dmg")), "release tag override");
check(withEnv({ WREN_RELEASE_TAG: "../../evil" }, () => release().tag === "v0.12.3-preview.1"), "a malformed tag is ignored");

if (failures.length) { console.error("✗ download functions:\n" + failures.map((f) => "  ✗ " + f).join("\n")); process.exit(1); }
console.log("✓ download functions: sign-in redirect, token checks, recorded before the link, setting slips, unconfigured and failure cases");
