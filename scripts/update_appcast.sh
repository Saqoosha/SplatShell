#!/usr/bin/env bash
set -euo pipefail

# Update Sparkle's appcast.xml and push it to the gh-pages branch, where the
# app's SUFeedURL (https://saqoosha.github.io/SplatShell/appcast.xml) reads it.
#
#   ./scripts/update_appcast.sh <version>
#
# Release notes are taken from the GitHub Release body and embedded in the
# feed, so finish editing them first. Delta updates from the previous two
# releases are generated and uploaded to the GitHub Release.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
SPARKLE_BIN="${ROOT_DIR}/.build/artifacts/sparkle/Sparkle/bin"
APPCAST_DIR="${BUILD_DIR}/appcast"
REPO_URL="https://github.com/Saqoosha/SplatShell"

# generate_appcast attaches every DMG it inspects for delta generation and
# does not detach them. They pile up as mounts with no /Volumes entry, and a
# stale mount hangs the next release's notarization (AGENTS.md "notarytool
# DMG-mount hang"). Eject anything attached from a DMG under $APPCAST_DIR on
# exit, including when the script aborts midway. `|| true` so a failed eject
# cannot abort the rest of the trap; package_dmg.sh's preflight is what stops
# the next release if one is left behind.
cleanup_appcast_mounts() {
  "${SCRIPT_DIR}/detach_dmg_mounts.sh" "$APPCAST_DIR" || true
}
trap cleanup_appcast_mounts EXIT

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${ROOT_DIR}/Resources/Info.plist")
  echo "No version specified, using current: ${VERSION}"
fi

DMG_NAME="SplatShell-${VERSION}.dmg"

if [[ ! -x "${SPARKLE_BIN}/generate_appcast" ]]; then
  echo "Error: generate_appcast not found. Run 'swift build -c release' first to fetch Sparkle."
  exit 1
fi

cd "$ROOT_DIR"
mkdir -p "$APPCAST_DIR"
# stale deltas would be re-listed in the feed
rm -f "$APPCAST_DIR"/*.delta

DMG_PATH="${BUILD_DIR}/${DMG_NAME}"
if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found locally, downloading from GitHub Release..."
  gh release download "v${VERSION}" --pattern "${DMG_NAME}" --dir "$BUILD_DIR"
fi
cp "$DMG_PATH" "$APPCAST_DIR/"

# generate_appcast picks up a .md next to a DMG of the same name as its notes
write_notes() {
  local tag="$1" path="$2" body
  body=$(gh release view "$tag" --json body --jq '.body' 2>/dev/null || echo "")
  if [[ -n "$body" ]]; then
    echo "$body" > "$path"
  fi
}

echo "Fetching release notes from GitHub Release v${VERSION}..."
write_notes "v${VERSION}" "${APPCAST_DIR}/SplatShell-${VERSION}.md"

echo "Downloading previous DMGs for delta generation..."
for TAG in $(gh release list --limit 3 --json tagName --jq '.[].tagName'); do
  [[ "$TAG" == "v${VERSION}" ]] && continue
  PREV_VERSION="${TAG#v}"
  PREV_DMG_NAME="SplatShell-${PREV_VERSION}.dmg"
  if [[ ! -f "${APPCAST_DIR}/${PREV_DMG_NAME}" ]]; then
    echo "  Downloading ${PREV_DMG_NAME} from ${TAG}..."
    gh release download "$TAG" --pattern "${PREV_DMG_NAME}" --dir "$APPCAST_DIR" 2>/dev/null || \
      echo "  Skipping ${TAG} (no DMG found)"
  fi
  if [[ ! -f "${APPCAST_DIR}/SplatShell-${PREV_VERSION}.md" ]]; then
    write_notes "$TAG" "${APPCAST_DIR}/SplatShell-${PREV_VERSION}.md"
  fi
done

# Start from the published feed so older versions stay listed
git fetch -q origin gh-pages 2>/dev/null || true
if git show origin/gh-pages:appcast.xml > "${APPCAST_DIR}/appcast.xml.fetched" 2>/dev/null; then
  mv "${APPCAST_DIR}/appcast.xml.fetched" "${APPCAST_DIR}/appcast.xml"
  echo "Fetched existing appcast.xml from gh-pages"
else
  rm -f "${APPCAST_DIR}/appcast.xml.fetched"
fi

"${SPARKLE_BIN}/generate_appcast" \
  --download-url-prefix "${REPO_URL}/releases/download/v${VERSION}/" \
  --link "${REPO_URL}" \
  --embed-release-notes \
  "$APPCAST_DIR"

if [[ ! -f "${APPCAST_DIR}/appcast.xml" ]]; then
  echo "Error: generate_appcast failed to create appcast.xml"
  exit 1
fi

# generate_appcast appends a <title> on every run; replace everything between
# <channel> and the first <item> with fixed metadata.
python3 - "$APPCAST_DIR/appcast.xml" "$REPO_URL" <<'PYEOF'
import re
import sys

path, repo_url = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()

meta = (
    '\n        <title>SplatShell Changelog</title>\n'
    f'        <link>{repo_url}</link>\n'
    '        <description>Most recent changes with links to updates.</description>\n'
    '        <language>en</language>\n        '
)
updated = re.sub(r'(<channel>).*?(<item>)', lambda m: m.group(1) + meta + m.group(2), content, count=1, flags=re.DOTALL)
if updated != content:
    with open(path, 'w') as f:
        f.write(updated)
PYEOF

echo "Generated appcast.xml:"
cat "${APPCAST_DIR}/appcast.xml"

DELTAS=("$APPCAST_DIR"/*.delta)
if [[ -e "${DELTAS[0]}" ]]; then
  echo "Uploading delta updates to GitHub Release v${VERSION}..."
  for DELTA in "${DELTAS[@]}"; do
    echo "  Uploading $(basename "$DELTA") ($(du -h "$DELTA" | cut -f1))"
    gh release upload "v${VERSION}" "$DELTA" --clobber
  done
else
  echo "No delta files generated"
fi

# Push appcast.xml to gh-pages from a throwaway worktree. Mount cleanup goes
# first in the trap: under `set -e` a failing command in a trap body skips the
# rest of it, and a leaked temp dir costs nothing while a leaked mount costs
# the next release.
WORKTREE_DIR=$(mktemp -d)
trap 'cleanup_appcast_mounts; rm -rf "$WORKTREE_DIR"' EXIT

if git rev-parse --verify origin/gh-pages >/dev/null 2>&1; then
  git worktree add "$WORKTREE_DIR" origin/gh-pages --detach
  cd "$WORKTREE_DIR"
  git checkout -B gh-pages origin/gh-pages
else
  git worktree add --detach "$WORKTREE_DIR"
  cd "$WORKTREE_DIR"
  git checkout --orphan gh-pages
  git rm -rf . 2>/dev/null || true
fi

cp "${APPCAST_DIR}/appcast.xml" "$WORKTREE_DIR/appcast.xml"

git add appcast.xml
if git diff --cached --quiet; then
  echo "appcast.xml unchanged, skipping push"
else
  git commit -m "Update appcast for v${VERSION}"
  git push origin gh-pages
  echo "Pushed appcast.xml to gh-pages"
fi

cd "$ROOT_DIR"
git worktree remove "$WORKTREE_DIR" 2>/dev/null || true
