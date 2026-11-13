#!/bin/zsh
# Builds Atelier.app. Pass --install to copy it to /Applications.
set -euo pipefail
cd "${0:A:h}"

# Build a universal (arm64 + x86_64) app so Atelier runs natively on both Apple silicon and Intel.
# SwiftPM lipos the per-arch products together and `--show-bin-path` points at the merged output
# directory (.build/apple/Products/Release), so the binaries copied below are already universal.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}" 2>&1 | tail -3
APP="build/Atelier.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BINDIR=$(swift build -c release "${ARCHS[@]}" --show-bin-path)
BIN="$BINDIR/DockStacks"
cp "$BIN" "$APP/Contents/MacOS/DockStacks"
cp "$BINDIR/AtelierGuard" "$APP/Contents/MacOS/AtelierGuard"
# Fan Control's root helper. Only copied into /Library when the owner installs it from the card.
cp "$BINDIR/AtelierFans" "$APP/Contents/MacOS/AtelierFans"
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp Resources/net.dasantos.atelier.guard.plist "$APP/Contents/Library/LaunchAgents/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Version: VERSION holds the full semver (1.0.0-beta.1); macOS gets the numeric part, Atelier's
# updater reads AtelierVersion. The build number is the commit count, so it always grows.
VERSION=$(tr -d '[:space:]' < VERSION)
BUILDNUM=$(git rev-list --count HEAD 2>/dev/null || echo 1)
plutil -replace CFBundleShortVersionString -string "${VERSION%%-*}" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILDNUM" "$APP/Contents/Info.plist"
plutil -replace AtelierVersion -string "$VERSION" "$APP/Contents/Info.plist"

# --- Dock Bridge: scripting addition + loader (ported from yabai, MIT). Universal: an arm64e slice
# injects into the arm64e Dock on Apple silicon, an x86_64 slice into the Intel Dock. A single clang
# invocation with both -arch flags compiles each slice and lipos them into one universal binary.
# They are placed in Resources; DockBridge installs the .osax to /Library only when the owner
# explicitly asks and SIP permits. Keep this before codesign so the app seals them.
BRIDGE_VERSION="1.0.0"
OSAX="$APP/Contents/Resources/Atelier.osax"
PAYLOAD_MACOS="$OSAX/Contents/Resources/payload.bundle/Contents/MacOS"
mkdir -p "$OSAX/Contents/MacOS" "$PAYLOAD_MACOS"
clang -arch arm64e -arch x86_64 -dynamiclib -fno-objc-arc -fmodules -Wno-deprecated-declarations \
  -Wl,-undefined,dynamic_lookup -framework Foundation -framework CoreGraphics \
  Native/payload.m -o "$PAYLOAD_MACOS/payload"
clang -arch arm64e -arch x86_64 -fobjc-arc -framework Cocoa \
  Native/loader.m -o "$OSAX/Contents/MacOS/loader"
cp "$OSAX/Contents/MacOS/loader" "$APP/Contents/Resources/atelier-loader"
cat > "$OSAX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>loader</string>
  <key>CFBundleIdentifier</key><string>net.dasantos.atelier.osax</string>
  <key>CFBundleName</key><string>Atelier</string>
  <key>CFBundlePackageType</key><string>osax</string>
  <key>CFBundleShortVersionString</key><string>${BRIDGE_VERSION}</string>
  <key>CFBundleVersion</key><string>${BRIDGE_VERSION}</string>
  <key>OSAXHandlers</key><dict></dict>
</dict></plist>
PLIST
cat > "$PAYLOAD_MACOS/../Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>payload</string>
  <key>CFBundleIdentifier</key><string>net.dasantos.atelier.sa</string>
  <key>CFBundleName</key><string>payload</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>${BRIDGE_VERSION}</string>
  <key>CFBundleVersion</key><string>${BRIDGE_VERSION}</string>
</dict></plist>
PLIST
chmod +x "$OSAX/Contents/MacOS/loader" "$PAYLOAD_MACOS/payload" "$APP/Contents/Resources/atelier-loader"
codesign -f -s - "$OSAX/Contents/MacOS/loader" 2>/dev/null || true
codesign -f -s - "$PAYLOAD_MACOS/payload" 2>/dev/null || true

# Stamped for macOS 14 so every supported release loads it; the source rides along as a
# fallback the engine compiles at run time if a release refuses the precompiled library.
xcrun -sdk macosx metal -mmacosx-version-min=14.0 Shaders/Living.metal -o "$APP/Contents/Resources/default.metallib"
cp Shaders/Living.metal "$APP/Contents/Resources/"
# The icon: rendered from branding/src/icon.swift (the 8K master), committed as AppIcon.icns.
cp branding/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Example themes and plugins, copied into the owner's folders on first run.
rm -rf "$APP/Contents/Resources/Examples"
mkdir -p "$APP/Contents/Resources/Examples"
cp -R examples/themes examples/plugins "$APP/Contents/Resources/Examples/"
# The plugin templates the Mods Playground (Create) offers, shared with the atelier-mod CLI.
rm -rf "$APP/Contents/Resources/ModTemplates"
cp -R sdk/cli/templates "$APP/Contents/Resources/ModTemplates"
# A stable identity keeps Screen Recording and Accessibility grants across rebuilds.
# Ad-hoc signing changes the code hash, so macOS forgets them every time.
# Releases are signed with "Atelier Release", a certificate that carries no personal details;
# its designated requirement stays the same from version to version, so permissions survive
# updates. Without it, an Apple Development or Developer ID identity, else ad hoc.
if [[ -z "${IDENTITY:-}" ]]; then
  IDENTITY=$(security find-identity -p codesigning | awk '/"Atelier Release"/{print $2; exit}')
  [[ -z "$IDENTITY" ]] && IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application|Apple Development/{print $2; exit}')
fi
codesign --force --sign "${IDENTITY:--}" "$APP/Contents/MacOS/AtelierGuard"
codesign --force --sign "${IDENTITY:--}" "$APP/Contents/MacOS/AtelierFans"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built: $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x DockStacks || true
  pkill -x AtelierGuard || true
  # SIGTERM is a clean quit now (restores run): wait for it to finish before copying.
  for _ in {1..100}; do pgrep -x DockStacks >/dev/null || break; sleep 0.1; done
  LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  [[ -d "/Applications/Dock Stacks.app" ]] && { $LS -u "/Applications/Dock Stacks.app"; rm -rf "/Applications/Dock Stacks.app"; }
  # Copy beside, check, then swap: a half-copied bundle (no Info.plist) cannot launch, and the
  # crash guard agent may try to start the app while the copy is still running.
  rm -rf "/Applications/Atelier.app.new"
  cp -R "$APP" "/Applications/Atelier.app.new"
  [[ -f "/Applications/Atelier.app.new/Contents/Info.plist" ]] || { echo "install: copy incomplete"; exit 1; }
  rm -rf "/Applications/Atelier.app"
  mv "/Applications/Atelier.app.new" "/Applications/Atelier.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Atelier.app"
  echo "Installed: /Applications/Atelier.app"
fi
