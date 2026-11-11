#!/bin/zsh
# After publishing: waits for the website to rebuild and checks that the site and the update
# feed both show the new version. Usage: scripts/postflight.sh <version>
set -uo pipefail
V="$1"; TAG="v$V"; REPO="kaizensx/Atelier"
SITE="https://kaizensx.github.io/Atelier"
say() { print -P "%F{cyan}▸%f $*"; }

say "Waiting for the website to rebuild"
for _ in {1..60}; do
  run=$(gh run list --repo "$REPO" --workflow pages.yml --limit 1 --json status,conclusion --jq '.[0].status + " " + .[0].conclusion')
  [[ "$run" == completed* ]] && break
  sleep 10
done
[[ "$run" == "completed success" ]] || { gh workflow run pages.yml --repo "$REPO" >/dev/null; sleep 60; }

fail=0
if curl -fsS "$SITE/data/releases.json?t=$(date +%s)" | grep -q "\"$TAG\""; then
  print -P "%F{green}✓%f website lists $TAG"
else
  print -P "%F{red}✗%f website does not list $TAG yet"; fail=1
fi
if gh api "repos/$REPO/releases?per_page=5" --jq '.[].tag_name' | grep -qx "$TAG"; then
  print -P "%F{green}✓%f update feed (GitHub releases API) has $TAG"
else
  print -P "%F{red}✗%f update feed does not have $TAG"; fail=1
fi
if curl -fsS "$SITE/data/mods.json?t=$(date +%s)" | grep -q '"mods"'; then
  print -P "%F{green}✓%f website has the live mods catalog"
else
  print -P "%F{red}✗%f website is missing the live mods catalog"; fail=1
fi
exit $fail
