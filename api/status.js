// GET /api/status/: whether downloads are set up on this deployment, and if not, which setting is
// wrong (a short code, never a value). For checking a deployment without signing in.
const { release, config, send } = require("./_lib.js");

module.exports = (req, res) => {
  const c = config();
  send(res, 200, { downloads: c.ok ? "ready" : "not set up", problem: c.problem, release: release().tag });
};
