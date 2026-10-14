// Shared by the download functions. Files starting with "_" aren't routes on Vercel.
//
// Configuration (Vercel › Project › Settings › Environment Variables; never in the repository):
//   SUPABASE_URL        https://<project-ref>.supabase.co
//   SUPABASE_ANON_KEY   the project's anon (public) key. Row Level Security limits it to adding a row
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

function config(env = process.env) {
  const url = (env.SUPABASE_URL || "").trim().replace(/\/+$/, "");
  const key = (env.SUPABASE_ANON_KEY || "").trim();
  const ok = /^https:\/\/[a-z0-9-]+\.supabase\.(co|in)$/.test(url) && key.length > 20;
  return { ok, url, key };
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
