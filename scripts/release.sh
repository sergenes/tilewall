#!/bin/zsh
# Builds dist/tilewall.app. With signing settings present it also signs, notarizes and staples it,
# and writes dist/tilewall-<version>.zip ready to publish.
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
BUNDLE_ID="${BUNDLE_ID:-app.tilewall.tiler}"
APP="dist/tilewall.app"
ZIP="dist/tilewall-$VERSION.zip"
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

echo "==> Notarizing (this takes a few minutes)"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --apple-id "$APPLE_ID" --password "$APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait
xcrun stapler staple "$APP"

# The zip that was notarized does not contain the stapled ticket, so zip again.
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP"
echo "==> Done: $ZIP"
shasum -a 256 "$ZIP"
