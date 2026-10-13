#!/bin/zsh
# Builds the static site into website/dist, ready to upload to any static host.
#   SITE_URL=https://example.org website/build.sh
# SITE_URL (no trailing slash) fills in canonical links, Open Graph URLs, robots.txt and the sitemap.
# Without it the build still works, but those tags are removed instead of pointing at a made-up domain.
set -euo pipefail
cd "$(dirname "$0")"
OUT=dist
rm -rf "$OUT"; mkdir -p "$OUT"
cp -R index.html 404.html privacy assets robots.txt sitemap.xml "$OUT"/
LASTMOD=$(date -u +%Y-%m-%d)
SITE_URL="${SITE_URL:-}"
SITE_URL="${SITE_URL%/}"
for f in $OUT/index.html $OUT/privacy/index.html $OUT/robots.txt $OUT/sitemap.xml; do
  if [[ -n "$SITE_URL" ]]; then
    sed -i '' -e "s#{{SITE_URL}}#$SITE_URL#g" -e "s#{{LASTMOD}}#$LASTMOD#g" "$f"
  else
    # No domain yet: drop the lines that need an absolute URL.
    sed -i '' -e '/{{SITE_URL}}/d' "$f"
  fi
done
[[ -z "$SITE_URL" ]] && rm -f "$OUT/sitemap.xml"
# Not part of the published site.
find "$OUT" -name ".DS_Store" -delete
node tools/check.mjs "$OUT"
echo "✓ built website/$OUT ${SITE_URL:+for $SITE_URL}"
