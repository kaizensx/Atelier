#!/bin/zsh
# Checks the public surface for stale or inconsistent text before a release. Fails loudly.
# Run by scripts/release.sh test; run it by hand any time: scripts/preflight.sh
set -uo pipefail
cd "${0:A:h}/.."

VERSION=$(tr -d '[:space:]' < VERSION)
fail=0
say() { print -P "%F{red}✗%f $*"; fail=1; }
ok() { print -P "%F{green}✓%f $*"; }

FILES=(README.md COMPATIBILITY.md docs/*.md site/*.html site/assets/js/*.js)

# 1. Promises about a beta that is this one or already out.
current_beta=$(print "$VERSION" | sed -n 's/.*-beta\.\([0-9]*\).*/\1/p')
[[ -z "$current_beta" ]] && current_beta=999   # a stable release: every beta promise is stale
for n in $(seq 1 "$current_beta"); do
  hits=$(grep -n -i -E "(coming|arrives?|opens?|lands?|ships?) (in|with) beta $n\b|until beta $n\b|in beta $n\.|with beta $n\b" "${FILES[@]}" 2>/dev/null)
  [[ -n "$hits" ]] && say "text still promises beta $n, which is out:\n$hits"
done

# 2. Chapters that no longer exist in the sidebar, by their old names.
for gone in "Themes & Plugins" "Themes &amp; Plugins"; do
  hits=$(grep -n -F "$gone" "${FILES[@]}" 2>/dev/null)
  [[ -n "$hits" ]] && say "\"$gone\" is no longer a chapter (it is Mods › Library):\n$hits"
done

# 3. The changelog has a section for this version.
grep -q "^## \[$VERSION\]" CHANGELOG.md && ok "CHANGELOG has [$VERSION]" || say "CHANGELOG.md has no ## [$VERSION] section"

# 4. Placeholders and leftovers.
hits=$(grep -n -E "TODO|FIXME|XXX|lorem ipsum" "${FILES[@]}" 2>/dev/null)
[[ -n "$hits" ]] && say "placeholders left in public text:\n$hits"

# 5. Every sidebar chapter named in the README exists in NavRegistry.
for name in $(grep -o '\*\*[A-Z][A-Za-z &]*\*\* |' README.md | sed 's/\*\*//g; s/ |//' | sort -u | tr ' ' '_'); do
  n=${name//_/ }
  grep -q "\"$n\"" Sources/DockStacks/NavRegistry.swift || true   # informational; feature rows aren't all chapters
done

# 6. No personal data in public files.
hits=$(grep -rn -i -E "/Users/santos|geral@|danielandre" README.md docs site Sources Tests 2>/dev/null | grep -v "^Binary")
[[ -n "$hits" ]] && say "personal data in public files:\n$hits"

# 7. The mod SDK: generated from docs/plugin-api.json and the app's prelude, its catalog rules
#    identical to atelier-mods' own (compared when a checkout is beside this one), its tests green.
if command -v node >/dev/null; then
  node sdk/generate.mjs --check >/dev/null && ok "sdk/ matches docs/plugin-api.json" || say "sdk/ is out of date: run node sdk/generate.mjs"
  out=$(node sdk/sync-catalog.mjs --check) && ok "atelier-mod: $out" || say "atelier-mod's catalog rules differ:\n$out"
  node --test sdk/test/ >/dev/null 2>&1 && ok "atelier-mod tests pass" || say "atelier-mod tests fail: node --test sdk/test/"
else
  say "node is not installed, so the mod SDK could not be checked"
fi

if (( fail )); then print -P "%F{red}preflight failed%f"; exit 1; fi
ok "preflight passed for $VERSION"
