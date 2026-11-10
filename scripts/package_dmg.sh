#!/usr/bin/env bash
set -euo pipefail

# Build, sign, notarize and staple SplatShell.app, then wrap it in a signed,
# notarized DMG at build/SplatShell-<version>.dmg.
#
#   DEVELOPER_ID      codesign identity (default below)
#   KEYCHAIN_PROFILE  notarytool credentials profile (default below). First
#                     time on a Mac:
#                     xcrun notarytool store-credentials notarytool-profile \
#                       --apple-id <apple id> --team-id VCFY2GFR89 --password <app-specific password>

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"

APP_NAME="SplatShell"
DEVELOPER_ID="${DEVELOPER_ID:-Developer ID Application: Tomohiko Koyama (VCFY2GFR89)}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-notarytool-profile}"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${ROOT_DIR}/Resources/Info.plist")
DMG_NAME="${APP_NAME}-${VERSION}"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
DMG_ROOT="${BUILD_DIR}/dmg-root"
OUT_DMG="${BUILD_DIR}/${DMG_NAME}.dmg"

if ! security find-identity -v -p codesigning | grep -qF "$DEVELOPER_ID"; then
  echo "Error: signing identity not in this Mac's keychain: $DEVELOPER_ID" >&2
  exit 1
fi

# Zip, DMG and both notarytool submissions happen in /tmp, and only the
# finished DMG is copied into build/. Time Machine holds I/O locks under the
# home folder while it backs up, which hangs notarytool's
# xar_open_digest_verify on files there; /tmp is never backed up. See
# AGENTS.md "Time Machine notarize hang".
TMP_WORK=$(mktemp -d /tmp/splatshell-dmg.XXXXXX)
# Detach before removing, in that order. notarytool mounts the DMG it is
# submitting, and that mount is of the copy in here, so `rm -rf` alone leaves
# it attached: an image outlives the deletion of its backing file, and the
# next release then hangs in notarytool. See AGENTS.md "notarytool DMG-mount
# hang". A cleanup failure is logged, not fatal: the trap also runs after a
# release that already produced its DMG.
trap '"${ROOT_DIR}/scripts/detach_dmg_mounts.sh" "$TMP_WORK" >/dev/null 2>&1 || \
      echo "warning: could not detach images under $TMP_WORK; run scripts/detach_dmg_mounts.sh before the next release" >&2
      rm -rf "$TMP_WORK"' EXIT INT TERM
TMP_DMG="${TMP_WORK}/${DMG_NAME}.dmg"
TMP_ZIP="${TMP_WORK}/${APP_NAME}.zip"

echo "=== Checking for leftover DMG mounts ==="
mkdir -p "${BUILD_DIR}"
if ! "${ROOT_DIR}/scripts/detach_dmg_mounts.sh" "${BUILD_DIR}" "$TMP_WORK"; then
  echo "Error: could not confirm that nothing under ${BUILD_DIR} is attached." >&2
  echo "Not proceeding; 'hdiutil info' lists what is attached." >&2
  exit 1
fi

echo "=== Building and signing ${APP_NAME}.app ==="
SIGN_IDENTITY="$DEVELOPER_ID" "${ROOT_DIR}/scripts/bundle.sh"

echo "=== Notarizing app ==="
ditto -c -k --keepParent "$APP_PATH" "$TMP_ZIP"
xcrun notarytool submit "$TMP_ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "=== Creating DMG ==="
rm -rf "${DMG_ROOT}"
mkdir -p "${DMG_ROOT}"
cp -R "${APP_PATH}" "${DMG_ROOT}/"
ln -s /Applications "${DMG_ROOT}/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_ROOT}" -ov -format UDZO "${TMP_DMG}"
rm -rf "${DMG_ROOT}"

echo "=== Notarizing DMG ==="
codesign --force --sign "$DEVELOPER_ID" "${TMP_DMG}"
xcrun notarytool submit "${TMP_DMG}" --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "${TMP_DMG}"

rm -f "${OUT_DMG}"
cp "${TMP_DMG}" "${OUT_DMG}"

echo "=== Done ==="
echo "${OUT_DMG}"
