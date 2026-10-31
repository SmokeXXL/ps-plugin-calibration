#!/bin/sh
# ABOUTME: Cuts a GitHub release of the plugin bundle: tags the current commit
# ABOUTME: with the manifest version and attaches an installable zip.
# ABOUTME: With --local, only builds the zip (no tag, push, or GitHub release).
set -e
cd "$(dirname "$0")"

LOCAL=0
case "$1" in
    --local) LOCAL=1 ;;
    "") ;;
    *) echo "usage: $0 [--local]"; exit 1 ;;
esac

BUNDLE=build.erik.calibration
[ -f "$BUNDLE/manifest.json" ] || { echo "$BUNDLE/manifest.json not found; the bundle must live in ./$BUNDLE"; exit 1; }
VERSION=$(python3 -c "import json; print(json.load(open('$BUNDLE/manifest.json'))['version'])")
TAG="v$VERSION"
ZIP="$BUNDLE-$TAG.zip"

if [ "$LOCAL" = 1 ]; then
    rm -f "$ZIP"
    zip -qr "$ZIP" "$BUNDLE" -x '*.DS_Store'
    echo "built $ZIP"
    exit 0
fi

[ -z "$(git status --porcelain)" ] || { echo "working tree not clean"; exit 1; }
git fetch --tags --quiet
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "tag $TAG already exists; bump \"version\" in $BUNDLE/manifest.json"
    exit 1
fi

rm -f "$ZIP"
zip -qr "$ZIP" "$BUNDLE" -x '*.DS_Store'
git tag "$TAG"
git push --quiet origin main "$TAG"
gh release create "$TAG" "$ZIP" --title "$TAG" \
    --notes "Install: unzip and copy \`$BUNDLE\` into PrusaSlicer's user plugin folder (see the README for per-OS paths), then **Menu > Plugins > Rescan Plugins**. Requires PrusaSlicer 3.0.0-alpha11 or newer."
rm -f "$ZIP"
echo "released $TAG"
