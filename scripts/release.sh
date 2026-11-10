#!/usr/bin/env bash
set -euo pipefail

# Release a version: bump Info.plist, build a notarized DMG, commit, tag, push
# and create the GitHub Release. Release notes and the appcast come after; see
# the "Next steps" this prints.
#
#   MODEL_NAME="<model>" ./scripts/release.sh <version>

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
PLIST="${ROOT_DIR}/Resources/Info.plist"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <version>   (e.g. $0 0.2.0)"
  exit 1
fi

VERSION="$1"
TAG="v${VERSION}"
# checked here, not at the commit: that comes after a ten-minute build
: "${MODEL_NAME:?set MODEL_NAME to the model running the release, for the Co-Authored-By line}"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: Invalid version format. Use X.Y.Z (e.g. 0.2.0)"
  exit 1
fi

cd "$ROOT_DIR"

# the release commit must hold the version bump and nothing else
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Error: the working tree has uncommitted changes" >&2
  exit 1
fi

CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
NEW_BUILD=$((CURRENT_BUILD + 1))

echo "=== Bumping version to ${VERSION} (build ${NEW_BUILD}) ==="
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NEW_BUILD}" "$PLIST"

echo "=== Building and packaging DMG ==="
"${ROOT_DIR}/scripts/package_dmg.sh"

DMG_PATH="${BUILD_DIR}/SplatShell-${VERSION}.dmg"
if [[ ! -f "$DMG_PATH" ]]; then
  echo "Error: DMG not found at $DMG_PATH"
  exit 1
fi

echo "=== Creating commit and tag ==="
git add "$PLIST"
git commit -m "Release ${VERSION}

- Bump version to ${VERSION} (build ${NEW_BUILD})

Co-Authored-By: Claude ${MODEL_NAME} <noreply@anthropic.com>"
git push origin main

# force-update the tag when re-releasing the same version
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Tag $TAG already exists, updating to current commit"
  git tag -d "$TAG"
  git push origin ":refs/tags/$TAG" 2>/dev/null || true
fi
git tag "$TAG"
git push origin "$TAG"

echo "=== Creating GitHub Release ==="
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Release $TAG already exists, uploading DMG"
  gh release upload "$TAG" "$DMG_PATH" --clobber
else
  gh release create "$TAG" "$DMG_PATH" \
    --title "SplatShell ${VERSION}" \
    --notes "### Changes
- (Add release notes here)"
fi

echo "=== Release complete ==="
echo "Version: ${VERSION}"
echo "Tag: ${TAG}"
echo "DMG: ${DMG_PATH}"
echo ""
echo "Next steps:"
echo "  1. Update release notes:  gh release edit ${TAG} --notes '...'"
echo "  2. Update appcast:        ./scripts/update_appcast.sh ${VERSION}"
