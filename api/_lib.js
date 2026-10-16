// Shared by the download functions. Files starting with "_" aren't routes on Vercel.
//
// Configuration (Vercel › Project › Settings › Environment Variables; never in the repository):
//   SUPABASE_URL        https://<project-ref>.supabase.co
//   SUPABASE_ANON_KEY   the project's anon (public) key, or its sb_publishable_… key. Row Level Security limits it to adding a row
//                       for the signed-in person; it can't read the download list.
//   WREN_RELEASE_TAG    optional: the GitHub release to hand out (default below).

// The release the download page hands out. Update when a new release is published, or set WREN_RELEASE_TAG.
const DEFAULT_TAG = "v0.12.1-preview.1";
const REPO = "https://github.com/shibadityadeb/wren";
const ASSET = "Wren-macOS-universal-unsigned.dmg";

function release(env = process.env) {
  const tag = /^v\d+\.\d+\.\d+(?:-[a-z]+\.\d+)?$/.test(env.WREN_RELEASE_TAG || "") ? env.WREN_RELEASE_TAG : DEFAULT_TAG;
  return {
    tag,
    version: tag.slice(1),
    dmg: `${REPO}/releases/download/${tag}/${ASSET}`,
    sha256: `${REPO}/releases/download/${tag}/${ASSET}.sha256`,
    notes: `${REPO}/releases/tag/${tag}`,
  };
}

// Reads and checks the Supabase settings. Harmless slips are forgiven (quotes, spaces, a trailing
// slash or API path such as /rest/v1); dangerous ones are refused with a reason the page can show:
// a database connection string (it holds the database password) or the service_role key (it
// bypasses Row Level Security). `problem` is a short code, never a value.
function config(env = process.env) {
  const clean = (v) => String(v || "").trim().replace(/^["']+|["']+$/g, "").trim();
  const rawUrl = clean(env.SUPABASE_URL), key = clean(env.SUPABASE_ANON_KEY);
  let url = "", problem = null;
  if (!rawUrl) problem = "url-missing";
  else if (/^postgres(ql)?:\/\//i.test(rawUrl)) problem = "url-database";
  else {
    try {
      const u = new URL(rawUrl);
      if (u.protocol === "https:" && /^[a-z0-9-]+\.supabase\.(co|in)$/i.test(u.hostname)) url = "https://" + u.hostname.toLowerCase();
      else problem = "url-invalid";
    } catch { problem = "url-invalid"; }
  }
  if (!problem) {
    if (!key) problem = "key-missing";
    else if (jwtRole(key) === "service_role" || /^sb_secret_/.test(key)) problem = "key-secret";
    else if (!(/^sb_publishable_[A-Za-z0-9_-]{10,}$/.test(key) || (jwtRole(key) === "anon"))) problem = "key-invalid";
  }
  return { ok: !problem, url: problem ? "" : url, key: problem ? "" : key, problem };
}

// The "role" claim of a Supabase legacy API key (a JWT), or null. Only the payload is read.
function jwtRole(k) {
  const parts = k.split(".");
  if (parts.length !== 3) return null;
  try { return JSON.parse(Buffer.from(parts[1].replace(/-/g, "+").replace(/_/g, "/"), "base64").toString("utf8")).role || null; }
  catch { return null; }
}

// The site's own address, from the request (production or a preview deployment). Supabase only
// redirects to addresses on its allow list, so a forged Host header can't send anyone elsewhere.
function siteOrigin(req) {
  const host = String(req.headers["x-forwarded-host"] || req.headers.host || "").split(",")[0].trim();
  return /^[a-z0-9.-]+(:\d+)?$/i.test(host) ? `https://${host}` : "";
}

function send(res, status, body) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.setHeader("Cache-Control", "no-store");
  res.end(JSON.stringify(body));
}

module.exports = { release, config, siteOrigin, send };
