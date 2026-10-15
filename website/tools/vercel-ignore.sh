#!/bin/sh
# Vercel "Ignored Build Step": exit 0 skips the build, exit 1 builds.
# Skips only a new commit that leaves the website, its functions and vercel.json unchanged. A redeploy
# of the same commit (needed after changing environment variables) always builds.
prev="$VERCEL_GIT_PREVIOUS_SHA"
[ -n "$prev" ] || exit 1
[ "$prev" != "$VERCEL_GIT_COMMIT_SHA" ] || exit 1
git cat-file -e "$prev^{commit}" 2>/dev/null || exit 1
git diff --quiet "$prev" HEAD -- ':(top)website' ':(top)api' ':(top)vercel.json' || exit 1
exit 0
