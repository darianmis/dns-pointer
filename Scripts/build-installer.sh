#!/bin/bash
# Builds a universal (Apple Silicon + Intel) Release of DNS Redirect and packages the
# "DNS Redirect Installer" app into a distributable, compressed DMG.
#
#   Scripts/build-installer.sh
#
# Environment (all optional):
#   DEVELOPER_DIR      Xcode to use (default: xcode-select's)
#   BUILD_ROOT         Scratch directory (default: $TMPDIR/dnsredirect-build — must not be in an
#                      iCloud-synced folder, or codesign fails on Finder metadata)
#   OUTPUT_DIR         Where the .dmg goes (default: ./dist)
#   DEVELOPER_ID       "Developer ID Application: Name (TEAMID)". Signs with hardened runtime
#                      for distribution outside this Mac. Without it, builds are ad-hoc signed.
#   NOTARY_PROFILE     notarytool keychain profile (xcrun notarytool store-credentials). With
#                      DEVELOPER_ID, the DMG is notarized and stapled so Gatekeeper accepts it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-${TMPDIR:-/tmp}/dnsredirect-build}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
DERIVED="$BUILD_ROOT/DerivedData"
STAGE="$BUILD_ROOT/dmg-stage"
VOLNAME="DNS Redirect"

step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

step "Building universal Release (arm64 + x86_64)"
xcodebuild -project "$ROOT/DNSRedirect.xcodeproj" -scheme DNSRedirectInstaller -configuration Release \
  -derivedDataPath "$DERIVED" -destination "generic/platform=macOS" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build -quiet

PRODUCTS="$DERIVED/Build/Products/Release"
INSTALLER="$PRODUCTS/DNS Redirect Installer.app"
APP="$INSTALLER/Contents/Resources/DNS Redirect.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

step "Checking architectures and minimum macOS"
for bin in "$INSTALLER/Contents/MacOS/DNS Redirect Installer" "$APP/Contents/MacOS/DNS Redirect" "$APP/Contents/MacOS/dnsredirect-helper"; do
  archs=$(lipo -archs "$bin")
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "$(basename "$bin") is not universal ($archs)"
  minos=$(vtool -show-build "$bin" | awk '/minos/{print $2}' | sort -u | tr '\n' ' ')
  echo "  $(basename "$bin"): $archs · minos $minos"
done

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  step "Signing with $DEVELOPER_ID (hardened runtime)"
  ENT="$BUILD_ROOT/app.entitlements"
  cat > "$ENT" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <!-- Needed for the in-process "do shell script … with administrator privileges" prompt. -->
  <key>com.apple.security.automation.apple-events</key><true/>
</dict></plist>
EOF
  SIGN=(codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID")
  "${SIGN[@]}" "$APP/Contents/MacOS/dnsredirect-helper"
  "${SIGN[@]}" --entitlements "$ENT" "$APP"
  "${SIGN[@]}" --entitlements "$ENT" "$INSTALLER"
fi

step "Verifying code signatures"
codesign --verify --deep --strict --verbose=1 "$INSTALLER"
codesign --verify --deep --strict --verbose=1 "$APP"

step "Running installer self-check"
"$INSTALLER/Contents/MacOS/DNS Redirect Installer" --unattended check | grep -E '"(arch|os|payload)"|result' || true

step "Staging disk image"
rm -rf "$STAGE"; mkdir -p "$STAGE/.background"
ditto "$INSTALLER" "$STAGE/Install DNS Redirect.app"
swift "$ROOT/Scripts/make-dmg-background.swift" "$STAGE/.background" >/dev/null
tiffutil -cathidpicheck "$STAGE/.background/background.png" "$STAGE/.background/background@2x.png" \
  -out "$STAGE/.background/background.tiff" 2>/dev/null
rm "$STAGE/.background/background.png" "$STAGE/.background/background@2x.png"

# Volume icon from the app icon.
ICONSET="$BUILD_ROOT/VolumeIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
SRC="$ROOT/DNSRedirect/Assets.xcassets/AppIcon.appiconset"
# iconset name -> source pixel size
for pair in 16x16:16 16x16@2x:32 32x32:32 32x32@2x:64 128x128:128 128x128@2x:256 256x256:256 256x256@2x:512 512x512:512 512x512@2x:1024; do
  cp "$SRC/icon_${pair#*:}.png" "$ICONSET/icon_${pair%%:*}.png"
done
VOLICON="$BUILD_ROOT/VolumeIcon.icns"; rm -f "$VOLICON"
iconutil -c icns "$ICONSET" -o "$VOLICON" 2>/dev/null || echo "  (no volume icon: icon files not found)"

step "Creating disk image"
mkdir -p "$OUTPUT_DIR"
RW="$BUILD_ROOT/rw.dmg"; FINAL="$OUTPUT_DIR/DNS-Redirect-$VERSION.dmg"
rm -f "$RW" "$FINAL"
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ -format UDRW -size 80m "$RW"
MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')
[[ -d "$MOUNT" ]] || fail "could not mount the image"

# Finder window layout (icon position, background). Needs Finder automation permission; the
# DMG still works without it, just with Finder's default layout.
DISK=$(basename "$MOUNT")
if osascript >/dev/null 2>&1 <<EOF
tell application "Finder"
  tell disk "$DISK"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Install DNS Redirect.app" of container window to {320, 190}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
then echo "  Finder layout applied"; else echo "  (Finder layout skipped: no automation permission. DMG uses default layout.)"; fi
# Volume icon last: Finder rewrites the volume root while applying the layout.
if [[ -f "$VOLICON" ]]; then
  cp "$VOLICON" "$MOUNT/.VolumeIcon.icns"
  SetFile -a C "$MOUNT" 2>/dev/null || xattr -wx com.apple.FinderInfo "0000000000000000040000000000000000000000000000000000000000000000" "$MOUNT"
fi
sync
hdiutil detach -quiet "$MOUNT" || { sleep 2; hdiutil detach -force -quiet "$MOUNT"; }
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$FINAL"
rm -f "$RW"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$FINAL"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    step "Notarizing (this can take a few minutes)"
    xcrun notarytool submit "$FINAL" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$FINAL"
  fi
fi

step "Verifying disk image"
hdiutil verify -quiet "$FINAL" && echo "  checksum OK"
echo "  Gatekeeper: $(spctl -a -t open --context context:primary-signature -vv "$FINAL" 2>&1 | head -1)"
printf '\n\033[1;32m✔ %s (%s)\033[0m\n' "$FINAL" "$(du -h "$FINAL" | cut -f1)"
