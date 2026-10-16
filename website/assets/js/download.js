// Download page: finishes the Google sign-in that Supabase sends back in the address (#access_token=…),
// removes it from the address bar at once, and asks this site's own /api/download for the link. The
// token goes only to this site, is used for that one request, and isn't stored in the browser.
(function () {
  "use strict";
  var box = document.getElementById("get");
  if (!box) return;
  function show(state) {
    box.querySelectorAll("[data-state]").forEach(function (el) { el.hidden = el.getAttribute("data-state") !== state; });
  }
  function fail(message) {
    document.getElementById("error").textContent = message;
    show("error");
  }
  var hash = new URLSearchParams(location.hash.replace(/^#/, ""));
  var query = new URLSearchParams(location.search);
  var token = hash.get("access_token");
  var problem = hash.get("error_description") || query.get("error_description");
  if (token || problem || query.get("setup")) history.replaceState(null, "", location.pathname);

  // Which setting is wrong (a code from /api/signin/, never a value), so the site owner can fix it.
  var why = {
    "url-missing": "SUPABASE_URL isn't set for this deployment.",
    "url-database": "SUPABASE_URL is a database connection string. Use the Project URL, https://<project-ref>.supabase.co, and change the database password if that string was shared.",
    "url-invalid": "SUPABASE_URL isn't a Supabase project URL (https://<project-ref>.supabase.co).",
    "key-missing": "SUPABASE_ANON_KEY isn't set for this deployment.",
    "key-secret": "SUPABASE_ANON_KEY holds a secret (service_role) key. Use the anon or publishable key, and rotate the secret one.",
    "key-invalid": "SUPABASE_ANON_KEY isn't a Supabase anon or publishable key.",
    "host": "This address couldn't be read from the request."
  }[query.get("why")];
  if (query.get("setup") === "missing") return fail("Downloads aren't set up on this site yet. Please check back soon." + (why ? " (Site setup: " + why + " Redeploy after changing it.)" : ""));
  if (problem) return fail("Google sign-in didn't finish: " + problem.replace(/\+/g, " ").slice(0, 160));
  if (!token) return show("start");

  show("checking");
  fetch("/api/download/", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ access_token: token }),
    cache: "no-store"
  }).then(function (r) {
    return r.json().catch(function () { return {}; }).then(function (b) { return { ok: r.ok, body: b }; });
  }).then(function (res) {
    var b = res.body || {};
    if (!res.ok || !b.dmg) return fail(b.error || "Couldn't get the download. Try again in a moment.");
    document.getElementById("who").textContent = b.email || "";
    document.getElementById("version").textContent = b.version || "";
    document.getElementById("dmg").href = b.dmg;
    document.getElementById("sha").href = b.sha256;
    document.getElementById("notes").href = b.notes;
    show("ready");
  }).catch(function () { fail("Couldn't reach the download service. Check your connection and try again."); });
})();
