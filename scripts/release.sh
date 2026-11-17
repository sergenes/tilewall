#!/bin/zsh
# Builds dist/tilewall.app. With signing settings present it also signs, notarizes and staples it,
# and writes dist/tilewall-<version>.dmg ready to publish.
#
# Signing settings come from private/release.env, which is not part of the repository:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   APPLE_ID="you@example.com"
#   APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx"
#   APPLE_TEAM_ID="TEAMID"
# Without that file the script produces an unsigned app for local use.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
grep -q "badge/version-$VERSION-" README.md || { echo "README.md version badge does not say $VERSION"; exit 1; }
[[ -f "docs/releases/$VERSION.md" ]] || { echo "docs/releases/$VERSION.md is missing: write the release notes first"; exit 1; }
./scripts/changelog.sh --check
BUNDLE_ID="${BUNDLE_ID:-app.tilewall.tiler}"
APP="dist/tilewall.app"
ZIP="dist/tilewall-$VERSION.zip"
DMG="dist/tilewall-$VERSION.dmg"
[[ -f private/release.env ]] && source private/release.env

echo "==> Testing"
swift test 2>&1 | grep -E "Executed .* tests|error:" | tail -1

echo "==> Building $VERSION (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64 2>&1 | tail -1
BINARY="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/tilewall"

echo "==> Assembling $APP"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/tilewall"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>tilewall</string>
    <key>CFBundleDisplayName</key><string>tilewall</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>tilewall</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

if [[ -z "${DEVELOPER_ID:-}" ]]; then
    codesign --force --sign - "$APP"
    echo "==> Done: $APP (ad hoc signed, not notarized: no private/release.env)"
    exit 0
fi

echo "==> Signing as $DEVELOPER_ID"
codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

notarize() {
    xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --password "$APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait
}

# The app gets its own ticket first, so it still verifies offline after it is dragged out of the disk image.
echo "==> Notarizing the app (this takes a few minutes)"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
rm "$ZIP"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "==> Building $DMG"
# dmgbuild lays out the window (app on the left, Applications on the right) without scripting Finder.
# It lives in its own virtual environment under .build, created on first use.
DMGBUILD=".build/dmgvenv/bin/dmgbuild"
if [[ ! -x "$DMGBUILD" ]]; then
    python3 -m venv .build/dmgvenv
    .build/dmgvenv/bin/pip install --quiet "dmgbuild==2.0.0"
fi
"$DMGBUILD" -s scripts/dmg_settings.py -D app="$APP" "tilewall $VERSION" "$DMG" >/dev/null
codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"

echo "==> Notarizing the disk image"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "==> Done: $DMG"
shasum -a 256 "$DMG"
