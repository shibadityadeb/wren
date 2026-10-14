// GET /api/signin/: sends the visitor to Google sign-in through Supabase Auth, then back to /download/.
// Nothing is stored by this step.
const { config, siteOrigin } = require("./_lib.js");

module.exports = (req, res) => {
  const c = config();
  const origin = siteOrigin(req);
  res.setHeader("Cache-Control", "no-store");
  if (!c.ok || !origin) {
    res.statusCode = 302;
    res.setHeader("Location", "/download/?setup=missing");
    return res.end();
  }
  const back = `${origin}/download/`;
  res.statusCode = 302;
  res.setHeader("Location", `${c.url}/auth/v1/authorize?provider=google&redirect_to=${encodeURIComponent(back)}`);
  res.end();
};
