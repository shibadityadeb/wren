// Checks a built site (no dependencies): every internal link, anchor and asset resolves, nothing is
// loaded from another server, images have alt text, pages have the basics, no placeholders remain.
//   node tools/check.mjs dist
import { readFileSync, existsSync, statSync, readdirSync } from "node:fs";
import { join, dirname, extname } from "node:path";

const root = process.argv[2] || ".";
const problems = [];
const external = new Set();

function walk(dir) {
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    return statSync(p).isDirectory() ? walk(p) : [p];
  });
}
const files = walk(root);
const pages = files.filter((f) => f.endsWith(".html"));

function resolve(fromFile, url) {
  const clean = url.split("#")[0].split("?")[0];
  let p = clean.startsWith("/") ? join(root, clean) : join(dirname(fromFile), clean);
  if (clean === "" ) p = fromFile;
  else if (clean.endsWith("/")) p = join(p, "index.html");
  else if (existsSync(p) && statSync(p).isDirectory()) p = join(p, "index.html");
  return p;
}
const ids = (html) => new Set([...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]));
const cache = new Map();
const read = (f) => { if (!cache.has(f)) cache.set(f, readFileSync(f, "utf8")); return cache.get(f); };

for (const page of pages) {
  const html = read(page);
  const rel = page.slice(root.length + 1);
  if (/\{\{[A-Z_]+\}\}/.test(html)) problems.push(`${rel}: unreplaced placeholder`);
  if (!/<html lang="/.test(html)) problems.push(`${rel}: missing lang`);
  if (!/<title>[^<]+<\/title>/.test(html)) problems.push(`${rel}: missing title`);
  if (!/name="viewport"/.test(html)) problems.push(`${rel}: missing viewport`);
  if (!rel.startsWith("404") && !/name="description"/.test(html)) problems.push(`${rel}: missing description`);
  for (const m of html.matchAll(/<img\b[^>]*>/g)) if (!/\salt="/.test(m[0])) problems.push(`${rel}: <img> without alt: ${m[0].slice(0, 80)}`);
  // Resources the browser loads by itself must be local.
  for (const m of html.matchAll(/<(script|img|link|source|iframe)\b[^>]*\s(?:src|href)="([^"]+)"/g)) {
    const [, tag, url] = m;
    if (tag === "link" && /rel="canonical"/.test(m[0])) continue;
    if (/^(https?:)?\/\//.test(url)) problems.push(`${rel}: <${tag}> loads from another server: ${url}`);
  }
  for (const m of html.matchAll(/\s(?:href|src)="([^"]+)"/g)) {
    const url = m[1];
    if (/^mailto:/.test(url)) continue;
    if (/^https?:\/\//.test(url)) { external.add(url); continue; }
    const target = resolve(page, url);
    if (!existsSync(target)) { problems.push(`${rel}: broken link ${url}`); continue; }
    const hash = url.includes("#") ? url.split("#")[1] : "";
    if (hash && extname(target) === ".html" && !ids(read(target)).has(hash)) problems.push(`${rel}: missing anchor ${url}`);
  }
  // Every in-page id is unique.
  const all = [...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]);
  const dup = all.filter((v, i) => all.indexOf(v) !== i);
  if (dup.length) problems.push(`${rel}: duplicate ids ${[...new Set(dup)].join(", ")}`);
}
// CSS url() references.
for (const css of files.filter((f) => f.endsWith(".css"))) {
  for (const m of read(css).matchAll(/url\("?([^")]+)"?\)/g)) {
    if (/^data:/.test(m[1])) continue;
    if (/^https?:/.test(m[1])) problems.push(`${css}: loads from another server: ${m[1]}`);
    else if (!existsSync(join(dirname(css), m[1]))) problems.push(`${css}: missing ${m[1]}`);
  }
}

console.log(`checked ${pages.length} pages; external links: ${external.size}`);
for (const u of [...external].sort()) console.log("  ↗ " + u);
if (problems.length) {
  console.error(`\n${problems.length} problem(s):\n` + problems.map((p) => "  ✗ " + p).join("\n"));
  process.exit(1);
}
console.log("✓ no broken links, anchors or assets; nothing loaded from other servers");
