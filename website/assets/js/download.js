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

  if (query.get("setup") === "missing") return fail("Downloads aren't set up on this site yet. Please check back soon.");
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
