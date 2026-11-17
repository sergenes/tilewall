#!/bin/zsh
# Publishes the release that scripts/release.sh built: pushes main, tags it, and creates the GitHub release
# with the notes from docs/releases/<version>.md and the notarized disk image.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
DMG="dist/tilewall-$VERSION.dmg"
NOTES="docs/releases/$VERSION.md"
[[ -f "$DMG" ]] || { echo "$DMG is missing, run scripts/release.sh first"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "commit or stash your changes first"; exit 1; }
xcrun stapler validate "$DMG" >/dev/null || { echo "$DMG is not notarized"; exit 1; }
# The disk image must come from the commit that gets the tag.
[[ "$(git log -1 --format=%ct)" -le "$(stat -f %m "$DMG")" ]] || { echo "$DMG is older than the last commit, run scripts/release.sh again"; exit 1; }

BODY="$(mktemp)"
{
    tail -n +2 "$NOTES" | sed 's/^### /## /'
    echo
    echo "## Install"
    echo
    echo "Download \`tilewall-$VERSION.dmg\`, open it, and drag \`tilewall.app\` to Applications, replacing any older copy."
    echo "Requires macOS 13 or later, Apple silicon or Intel. The app and the disk image are signed and notarized."
    echo
    echo "SHA-256 of \`tilewall-$VERSION.dmg\`:"
    echo "\`$(shasum -a 256 "$DMG" | cut -d' ' -f1)\`"
} > "$BODY"

git push origin main
git tag "v$VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" "$DMG" --verify-tag --title "tilewall $VERSION" --notes-file "$BODY"
rm -f "$BODY"
