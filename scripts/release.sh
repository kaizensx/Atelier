#!/bin/zsh
# Atelier releases: always tested first, then a beta, then (the same code) a stable release.
#
#   scripts/release.sh test      Run the tests, build VERSION, sign the update archive and install
#                                it on this Mac. Nothing leaves the Mac.
#   scripts/release.sh beta      Publish the tested build of VERSION (must be x.y.z-beta.N) as a
#                                GitHub pre-release. Only Macs on the Beta channel see it.
#   scripts/release.sh stable    Promote: build x.y.z from the commit of its last beta, test,
#                                install, then publish it as the release everyone gets.
#   scripts/release.sh status    What is built, tested and published.
#
# Keys live outside the repository, in ~/Library/Application Support/Atelier Release:
#   update-ed25519.key   signs update archives (the app checks it against its built-in public key)
#   "Atelier Release"    code-signing identity in the login keychain
set -euo pipefail
cd "${0:A:h}/.."

REPO="kaizensx/Atelier"
KEYDIR="$HOME/Library/Application Support/Atelier Release"
KEY="$KEYDIR/update-ed25519.key"
PUB=$(cat "$KEYDIR/update-ed25519.pub" 2>/dev/null || true)
TOOLS=".build/tools"; SIGNER="$TOOLS/sign-update"
VERSION=$(tr -d '[:space:]' < VERSION)

say() { print -P "%F{cyan}▸%f $*"; }
die() { print -P "%F{red}✗%f $*" >&2; exit 1; }

signer() {
  mkdir -p "$TOOLS"
  [[ "$SIGNER" -nt scripts/sign-update.swift ]] || swiftc -O scripts/sign-update.swift -o "$SIGNER"
}

notes_for() {   # the CHANGELOG section of a version, without its heading
  awk -v v="$1" '
    $0 ~ "^## \\[" v "\\]" { on = 1; next }
    on && /^## \[/ { exit }
    on { print }' CHANGELOG.md
}

install_archive() {   # unzip an archive over /Applications/Atelier.app, as the updater would
  local zip="$1" dest="/Applications/Atelier.app" tmp
  tmp=$(mktemp -d)
  ditto -x -k "$zip" "$tmp"
  [[ -f "$tmp/Atelier.app/Contents/Info.plist" ]] || die "archive has no Atelier.app"
  pkill -x DockStacks || true; pkill -x AtelierGuard || true; sleep 1
  rm -rf "$dest.new"; ditto "$tmp/Atelier.app" "$dest.new"
  rm -rf "$dest"; mv "$dest.new" "$dest"; rm -rf "$tmp"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest"
  open "$dest"
}

package() {     # $1 = version
  local v="$1" out="dist/$1"
  [[ -f "$KEY" ]] || die "No update key at $KEY"
  grep -q "static let publicKey = \"$PUB\"" Sources/DockStacks/Updater.swift || die "Updater.swift's public key is not $PUB"
  say "Tests"
  swift test 2>&1 | tail -1
  say "Build $v"
  zsh build.sh >/dev/null
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :AtelierVersion' build/Atelier.app/Contents/Info.plist)" == "$v" ]] || die "build is not $v"
  codesign --verify --deep --strict build/Atelier.app || die "code signature check failed"
  rm -rf "$out"; mkdir -p "$out"
  ditto -c -k --keepParent build/Atelier.app "$out/Atelier-$v.zip"
  signer
  "$SIGNER" "$out/Atelier-$v.zip" "$KEY" > "$out/Atelier-$v.zip.sig"
  "$SIGNER" --verify "$out/Atelier-$v.zip" "$out/Atelier-$v.zip.sig" "$PUB" >/dev/null || die "signature does not verify"
  (cd "$out" && shasum -a 256 "Atelier-$v.zip" > "Atelier-$v.zip.sha256")
  notes_for "$v" > "$out/NOTES.md"
  [[ -s "$out/NOTES.md" ]] || die "CHANGELOG.md has no section for [$v]"
  git rev-parse HEAD > "$out/COMMIT"
  say "Install on this Mac for testing: the very archive that will be published"
  install_archive "$out/Atelier-$v.zip"
  date -u +%FT%TZ > "$out/TESTED_BUILD"
  print -P "%F{green}✓%f Atelier $v is installed here. Try it, then: scripts/release.sh ${2:-beta}"
}

publish() {     # $1 = version, $2 = prerelease flag
  local v="$1" out="dist/$1" tag="v$1"
  [[ -f "$out/TESTED_BUILD" ]] || die "$v was not built and installed for testing: run scripts/release.sh test first"
  [[ "$(cat "$out/COMMIT")" == "$(git rev-parse HEAD)" ]] || die "the code changed since $v was tested: test again"
  git diff --quiet && git diff --cached --quiet || die "uncommitted changes: commit them, then test again"
  read -q "?Publish Atelier $v to GitHub${2:+ as a pre-release}? [y/N] " || { print; exit 1; }; print
  git tag -a "$tag" -m "Atelier $v" 2>/dev/null || true
  git push origin HEAD "$tag"
  gh release create "$tag" --repo "$REPO" ${2:+--prerelease} --title "Atelier $v" --notes-file "$out/NOTES.md" \
    "$out/Atelier-$v.zip" "$out/Atelier-$v.zip.sig" "$out/Atelier-$v.zip.sha256"
  print -P "%F{green}✓%f Published https://github.com/$REPO/releases/tag/$tag"
}

case "${1:-}" in
  test)
    package "$VERSION" "$([[ "$VERSION" == *-* ]] && echo beta || echo stable)" ;;
  beta)
    [[ "$VERSION" == *-beta.* ]] || die "VERSION ($VERSION) is not a beta like 1.2.0-beta.1"
    publish "$VERSION" yes ;;
  stable)
    [[ "$VERSION" == *-beta.* ]] || die "set VERSION to the beta you are promoting"
    final="${VERSION%%-*}"
    git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || die "v$VERSION was never published as a beta"
    git diff --quiet && git diff --cached --quiet || die "commit the release notes ([$final] in CHANGELOG.md) first"
    # Only the version and the release notes may differ from the beta that was tested.
    git diff --quiet "v$VERSION" HEAD -- . ':(exclude)VERSION' ':(exclude)CHANGELOG.md' \
      || die "the code changed since v$VERSION: publish a new beta first"
    print "$final" > VERSION
    git commit -qam "Release $final"
    VERSION="$final"
    package "$final" stable
    publish "$final" "" ;;
  status)
    print "VERSION $VERSION"
    for d in dist/*(N/); do print "  ${d:t}: built $( [[ -f $d/TESTED_BUILD ]] && cat $d/TESTED_BUILD || print no ) commit $(cut -c1-8 $d/COMMIT 2>/dev/null)"; done
    gh release list --repo "$REPO" --limit 8 2>/dev/null || true ;;
  *) sed -n '2,13p' "$0" ;;
esac
