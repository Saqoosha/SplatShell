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

# Moved to each new SuperSplat release by scripts/follow_supersplat.sh, through
# a pull request. Bumping it by hand: its own commit, and rerun the --bench
# checks in AGENTS.md. The line format is read by that script.
SUPERSPLAT_REPO="https://github.com/playcanvas/supersplat.git"
SUPERSPLAT_COMMIT="919f0e5d60a94470ed8ebcbc7353a29d0a4344f0"

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/SplatShell.app"
identity="${SIGN_IDENTITY:--}"

cd "$root"

if [[ -n "${SUPERSPLAT_DIR:-}" ]]; then
    # used as is: patches/ is not applied
    supersplat="$SUPERSPLAT_DIR"
else
    supersplat="$root/.build/supersplat"
    # The pinned commit plus patches/*.patch, applied in name order. A change
    # to either starts again from a clean checkout.
    shopt -s nullglob
    patches=("$root"/patches/*.patch)
    shopt -u nullglob
    stamp="$SUPERSPLAT_COMMIT $(cat /dev/null "${patches[@]}" | shasum -a 256 | cut -c1-16)"
    if [[ "$(cat "$supersplat/.splatshell-stamp" 2>/dev/null || true)" != "$stamp" ]]; then
        rm -rf "$supersplat"
        git init -q "$supersplat"
        git -C "$supersplat" fetch -q --depth 1 "$SUPERSPLAT_REPO" "$SUPERSPLAT_COMMIT"
        git -C "$supersplat" checkout -q FETCH_HEAD
        for patch in "${patches[@]}"; do
            git -C "$supersplat" apply "$patch"
        done
        (cd "$supersplat" && npm ci && npm run build)
        echo "$stamp" > "$supersplat/.splatshell-stamp"
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
# SwiftPM adds rpaths into the build machine's toolchains (Xcode, and the
# Metal Toolchain's temporary mount). The app loads Swift from /usr/lib/swift
# and Sparkle from its own Frameworks folder, so only those two stay.
otool -l "$app/Contents/MacOS/SplatShell" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }' |
    while read -r rpath; do
        case "$rpath" in
            /usr/lib/swift | @executable_path/../Frameworks) ;;
            *) install_name_tool -delete_rpath "$rpath" "$app/Contents/MacOS/SplatShell" ;;
        esac
    done
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
