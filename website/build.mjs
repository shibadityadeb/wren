// Builds the static site into website/dist and checks it. Plain Node, no dependencies, so it runs the
// same on a Mac, in CI and on Vercel.
//   node website/build.mjs                        (no domain: absolute-URL tags are left out)
//   SITE_URL=https://example.org node website/build.mjs
// On Vercel, SITE_URL defaults to the project's production address (VERCEL_PROJECT_PRODUCTION_URL,
// e.g. wren.vercel.app), and preview deployments are marked noindex.
import { cpSync, rmSync, mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, "dist");
const env = process.env;
let site = (env.SITE_URL || (env.VERCEL_PROJECT_PRODUCTION_URL ? `https://${env.VERCEL_PROJECT_PRODUCTION_URL}` : "")).replace(/\/+$/, "");
const preview = env.VERCEL_ENV === "preview";
const lastmod = new Date().toISOString().slice(0, 10);

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
for (const f of ["index.html", "404.html", "privacy", "assets", "robots.txt", "sitemap.xml"]) {
  cpSync(join(here, f), join(out, f), { recursive: true, filter: (p) => !p.endsWith(".DS_Store") });
}

for (const f of ["index.html", "privacy/index.html", "404.html", "robots.txt", "sitemap.xml"]) {
  const p = join(out, f);
  let s = readFileSync(p, "utf8");
  if (site) s = s.replaceAll("{{SITE_URL}}", site).replaceAll("{{LASTMOD}}", lastmod);
  else s = s.split("\n").filter((l) => !l.includes("{{SITE_URL}}")).join("\n");
  if (preview && f.endsWith(".html") && !s.includes('name="robots"')) {
    s = s.replace("<meta charset=\"utf-8\">", "<meta charset=\"utf-8\">\n  <meta name=\"robots\" content=\"noindex\">");
  }
  writeFileSync(p, s);
}
if (!site) rmSync(join(out, "sitemap.xml"), { force: true });

// The Content-Security-Policy in vercel.json allows exactly one inline script, by hash. Fail if it drifted.
const vercel = JSON.parse(readFileSync(join(here, "..", "vercel.json"), "utf8"));
const csp = vercel.headers.flatMap((h) => h.headers).find((h) => h.key === "Content-Security-Policy").value;
for (const page of ["index.html", "privacy/index.html"]) {
  const html = readFileSync(join(out, page), "utf8");
  for (const m of html.matchAll(/<script>([\s\S]*?)<\/script>/g)) {
    const hash = "'sha256-" + createHash("sha256").update(m[1]).digest("base64") + "'";
    if (!csp.includes(hash)) {
      console.error(`✗ ${page}: inline script isn't allowed by the CSP in vercel.json. Add ${hash} to script-src.`);
      process.exit(1);
    }
  }
}

execFileSync(process.execPath, [join(here, "tools", "check.mjs"), out], { stdio: "inherit" });
console.log(`✓ built website/dist${site ? ` for ${site}` : " (no SITE_URL: canonical and sitemap left out)"}${preview ? " · preview: noindex" : ""}`);
if (!existsSync(join(out, "404.html"))) process.exit(1);
