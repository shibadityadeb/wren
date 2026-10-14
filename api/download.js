// POST /api/download  { "access_token": "<Supabase access token from Google sign-in>" }
// Checks the sign-in with Supabase, records the download (one row per person and version), and only
// then returns the download link. The token is used for this request only and is never stored.
const { release, config, send } = require("./_lib.js");

module.exports = async (req, res) => {
  if (req.method !== "POST") return send(res, 405, { error: "Use POST." });
  const c = config();
  if (!c.ok) return send(res, 503, { error: "Downloads aren't set up yet. Please try again later." });

  let body = req.body;
  if (typeof body === "string") { try { body = JSON.parse(body); } catch { body = {}; } }
  const token = body && body.access_token;
  if (typeof token !== "string" || token.length < 20 || token.length > 8192) return send(res, 400, { error: "Sign in with Google first." });

  // Who is this? Supabase verifies the token it issued.
  let user;
  try {
    const r = await fetch(`${c.url}/auth/v1/user`, { headers: { apikey: c.key, Authorization: `Bearer ${token}` } });
    if (!r.ok) return send(res, 401, { error: "Your sign-in has expired. Sign in with Google again." });
    user = await r.json();
  } catch {
    return send(res, 502, { error: "Couldn't reach the sign-in service. Try again in a moment." });
  }
  const providers = (user && user.app_metadata && user.app_metadata.providers) || [];
  const viaGoogle = (user && user.app_metadata && user.app_metadata.provider === "google") || providers.includes("google");
  if (!user || !user.id || !user.email || !viaGoogle) return send(res, 403, { error: "Downloading needs a Google sign-in." });

  const rel = release();
  const meta = user.user_metadata || {};
  const row = {
    user_id: user.id,
    email: String(user.email).slice(0, 254),
    name: String(meta.full_name || meta.name || "").slice(0, 120) || null,
    version: rel.version,
  };
  try {
    // Inserted as the signed-in person (their token), so Row Level Security applies: they can add
    // their own row and nothing else. A repeat download of the same version is already recorded (409).
    const r = await fetch(`${c.url}/rest/v1/download_requests`, {
      method: "POST",
      headers: { apikey: c.key, Authorization: `Bearer ${token}`, "Content-Type": "application/json", Prefer: "return=minimal" },
      body: JSON.stringify(row),
    });
    if (!r.ok && r.status !== 409) return send(res, 502, { error: "Couldn't record your download. Try again in a moment." });
  } catch {
    return send(res, 502, { error: "Couldn't record your download. Try again in a moment." });
  }
  return send(res, 200, { email: row.email, version: rel.version, dmg: rel.dmg, sha256: rel.sha256, notes: rel.notes });
};
