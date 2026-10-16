#!/bin/sh
# Vercel "Ignored Build Step": exit 0 skips the build, exit 1 builds.
# Skips only a preview of a new commit that leaves the website, its functions and vercel.json unchanged. A redeploy
# of the same commit (needed after changing environment variables) always builds.
# Production always builds: it's the only way new environment variables (Supabase settings) take
# effect, and a production deployment from an app-only commit must not keep serving old settings.
[ "$VERCEL_ENV" = "production" ] && exit 1
prev="$VERCEL_GIT_PREVIOUS_SHA"
[ -n "$prev" ] || exit 1
[ "$prev" != "$VERCEL_GIT_COMMIT_SHA" ] || exit 1
git cat-file -e "$prev^{commit}" 2>/dev/null || exit 1
git diff --quiet "$prev" HEAD -- ':(top)website' ':(top)api' ':(top)vercel.json' || exit 1
exit 0
