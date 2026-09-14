#!/usr/bin/env bash
#
# check-upstream-drift.sh
#
# This fork's local `main` fell 359 commits behind codeberg.org/CupertinoHQ/cupertino's
# `main` for months before anyone noticed — the project had quietly migrated off
# github.com/mihaelamj/cupertino (account deleted) to Codeberg, and nothing here ever
# checked back in. This script is the check that would have caught it: compares local
# `main` against `upstream`'s `main` and `develop`, and reports the gap instead of
# staying silent about it.
#
# Usage: scripts/check-upstream-drift.sh [remote-name]
#   remote-name defaults to "upstream" (this repo's remote for
#   codeberg.org/CupertinoHQ/cupertino).
#
# Exit code: 0 if local main is fully caught up with upstream/main, 1 otherwise.
# Safe to run anytime — only fetches, never merges/rebases/pushes.

set -euo pipefail

REMOTE="${1:-upstream}"

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
    echo "❌ no remote named '$REMOTE' configured. Add it with:" >&2
    echo "   git remote add $REMOTE https://codeberg.org/CupertinoHQ/cupertino.git" >&2
    exit 2
fi

echo "🔄 Fetching $REMOTE ($(git remote get-url "$REMOTE"))..."
git fetch --quiet --tags "$REMOTE"

behind_main=$(git rev-list --count "main..$REMOTE/main")
ahead_main=$(git rev-list --count "$REMOTE/main..main")

latest_tag_local=$(git describe --tags --abbrev=0 main 2>/dev/null || echo "none")
latest_tag_remote=$(git describe --tags --abbrev=0 "$REMOTE/main" 2>/dev/null || echo "none")

echo ""
echo "📍 local main:        $(git rev-parse --short main)  (tag: $latest_tag_local)"
echo "📍 $REMOTE/main:  $(git rev-parse --short "$REMOTE/main")  (tag: $latest_tag_remote)"
echo ""

status=0

if [ "$behind_main" -gt 0 ]; then
    echo "⚠️  local main is $behind_main commit(s) behind $REMOTE/main"
    echo "    → git merge --ff-only $REMOTE/main   (after confirming no local-only commits)"
    status=1
else
    echo "✅ local main is caught up with $REMOTE/main"
fi

if [ "$ahead_main" -gt 0 ]; then
    echo "ℹ️  local main has $ahead_main commit(s) not on $REMOTE/main (expected if you carry local fixes on top)"
fi

if git rev-parse --verify "$REMOTE/develop" >/dev/null 2>&1; then
    behind_develop=$(git rev-list --count "main..$REMOTE/develop")
    if [ "$behind_develop" -gt 0 ]; then
        echo "ℹ️  $REMOTE/develop is $behind_develop commit(s) ahead of local main (expected — develop is the trunk, main is the release branch)"
    fi
fi

exit $status
