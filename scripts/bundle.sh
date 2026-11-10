#!/bin/bash
# Build build/SplatShell.app: the release binary, Sparkle and a SuperSplat build.
#
#   SUPERSPLAT_DIR  a SuperSplat checkout to use as is (built here if it has no
#                   dist/). Default: the pinned commit below, cloned into
#                   .build/supersplat.
#   SIGN_IDENTITY   codesign identity. Default "-" (ad hoc, runs on this Mac
#                   only). A Developer ID also turns on the hardened runtime
#                   and a secure timestamp, which notarization requires.
set -euo pipefail

# Rendering was measured against this commit (3.7.0 plus a few fixes). Bump it
# in its own commit and rerun the --bench checks in AGENTS.md.
SUPERSPLAT_REPO="https://github.com/playcanvas/supersplat.git"
SUPERSPLAT_COMMIT="c061d0d6a56c730487f90e7683eee09422864e56"

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/SplatShell.app"
identity="${SIGN_IDENTITY:--}"

cd "$root"

if [[ -n "${SUPERSPLAT_DIR:-}" ]]; then
    supersplat="$SUPERSPLAT_DIR"
else
    supersplat="$root/.build/supersplat"
    if [[ "$(git -C "$supersplat" rev-parse HEAD 2>/dev/null || true)" != "$SUPERSPLAT_COMMIT" ]]; then
        rm -rf "$supersplat"
        git init -q "$supersplat"
        git -C "$supersplat" fetch -q --depth 1 "$SUPERSPLAT_REPO" "$SUPERSPLAT_COMMIT"
        git -C "$supersplat" checkout -q FETCH_HEAD
    fi
fi
if [[ ! -f "$supersplat/dist/index.html" ]]; then
    (cd "$supersplat" && npm ci && npm run build)
fi

swift build -c release
bin="$(swift build -c release --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/web" "$app/Contents/Frameworks"
cp "$bin/SplatShell" "$app/Contents/MacOS/SplatShell"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
# ditto keeps the framework's internal symlinks (Versions/Current and friends)
ditto "$bin/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"

# Source maps are a third of the build and unused at runtime. Symlinks are
# skipped so nothing outside the build can end up in the bundle.
rsync -a --no-links --exclude '*.map' "$supersplat/dist/" "$app/Contents/Resources/web/"
cp "$supersplat/LICENSE" "$app/Contents/Resources/web/LICENSE-supersplat.txt"

sign=(codesign --force --sign "$identity")
if [[ "$identity" != "-" ]]; then
    sign+=(--options runtime --timestamp)
fi

# Inside out, in the order Sparkle documents: its helpers, the framework, then
# the app. --deep is not used; it would re-sign the helpers without the
# Downloader's entitlements.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
"${sign[@]}" "$sparkle/Versions/B/XPCServices/Installer.xpc"
"${sign[@]}" --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
"${sign[@]}" "$sparkle/Versions/B/Autoupdate"
"${sign[@]}" "$sparkle/Versions/B/Updater.app"
"${sign[@]}" "$sparkle"
"${sign[@]}" "$app"

codesign --verify --deep --strict "$app"
echo "$app"
