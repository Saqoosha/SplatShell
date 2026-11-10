#!/bin/bash
# Build build/SplatShell.app: the release binary plus a SuperSplat build.
#
#   SUPERSPLAT_DIR  a SuperSplat checkout that has been built (npm run build).
#                   Default: ../supersplat next to this repo.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
supersplat="${SUPERSPLAT_DIR:-$root/../supersplat}"
app="$root/build/SplatShell.app"

if [[ ! -f "$supersplat/dist/index.html" ]]; then
    echo "no SuperSplat build at $supersplat/dist (run 'npm ci && npm run build' there)" >&2
    exit 1
fi

cd "$root"
swift build -c release

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/web"
cp "$root/.build/release/SplatShell" "$app/Contents/MacOS/SplatShell"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"

# Source maps are a third of the build and unused at runtime. Symlinks are
# skipped so nothing outside the build can end up in the bundle.
rsync -a --no-links --exclude '*.map' "$supersplat/dist/" "$app/Contents/Resources/web/"
cp "$supersplat/LICENSE" "$app/Contents/Resources/web/LICENSE-supersplat.txt"

codesign --force --sign - "$app"
echo "$app"
