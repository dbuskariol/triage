#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/triage-release.sh"

APP="${TRIAGE_DMG_APP:-$ROOT_DIR/dist/Triage.app}"
UPDATES_DIR="${TRIAGE_DMG_OUTPUT_DIR:-$ROOT_DIR/dist/updates}"
NOTARY_OUTPUT_DIR="${TRIAGE_NOTARY_OUTPUT_DIR:-$ROOT_DIR/dist/notarization}"
PREPARE_ONLY="${TRIAGE_NOTARY_PREPARE_ONLY:-0}"
SIGNING_IDENTITY="${TRIAGE_CODESIGN_IDENTITY:-}"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(triage_find_developer_id_identity)"
fi
[[ -n "$SIGNING_IDENTITY" ]] || triage_fail 'no Developer ID Application signing identity is available'
triage_assert_release_app "$APP" "${TRIAGE_DEVELOPMENT_TEAM:-}"
if [[ "$PREPARE_ONLY" != "1" ]]; then
  triage_assert_notarized_app "$APP"
fi

VERSION="$(triage_plist_value CFBundleShortVersionString "$APP/Contents/Info.plist")"
BUILD="$(triage_plist_value CFBundleVersion "$APP/Contents/Info.plist")"
BASE_NAME="Triage-$VERSION-$BUILD"
DISK_IMAGE="$UPDATES_DIR/$BASE_NAME.dmg"
SUBMISSION_JSON="$NOTARY_OUTPUT_DIR/notary-submit-dmg-$VERSION-$BUILD.json"
LOG_JSON="$NOTARY_OUTPUT_DIR/notary-log-dmg-$VERSION-$BUILD.json"
STAGING_DIR="$(/usr/bin/mktemp -d -t triage-dmg-stage.XXXXXX)"
MOUNT_POINT="$(/usr/bin/mktemp -d -t triage-dmg-mount.XXXXXX)"
IS_MOUNTED=0

cleanup() {
  if [[ "$IS_MOUNTED" == "1" ]]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  /bin/rm -rf "$STAGING_DIR" "$MOUNT_POINT"
}
trap cleanup EXIT INT TERM

/bin/mkdir -p "$UPDATES_DIR" "$NOTARY_OUTPUT_DIR"
/usr/bin/ditto "$APP" "$STAGING_DIR/Triage.app"
/bin/ln -s /Applications "$STAGING_DIR/Applications"
/bin/rm -f "$DISK_IMAGE" "$SUBMISSION_JSON" "$LOG_JSON"

triage_note "Creating compressed disk image $DISK_IMAGE"
/usr/bin/hdiutil create \
  -quiet \
  -ov \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -volname "Triage $VERSION" \
  -srcfolder "$STAGING_DIR" \
  "$DISK_IMAGE"
/usr/bin/codesign --sign "$SIGNING_IDENTITY" --timestamp "$DISK_IMAGE"
triage_assert_signed_disk_image "$DISK_IMAGE" "${TRIAGE_DEVELOPMENT_TEAM:-}"

if [[ "$PREPARE_ONLY" != "1" ]]; then
  triage_note 'Submitting the signed disk image to Apple notarization'
  triage_submit_notarization "$DISK_IMAGE" "$SUBMISSION_JSON" "$LOG_JSON"
  /usr/bin/xcrun stapler staple "$DISK_IMAGE"
  triage_assert_notarized_disk_image "$DISK_IMAGE" "${TRIAGE_DEVELOPMENT_TEAM:-}"
fi

/usr/bin/hdiutil attach \
  -quiet \
  -readonly \
  -nobrowse \
  -mountpoint "$MOUNT_POINT" \
  "$DISK_IMAGE"
IS_MOUNTED=1
[[ -d "$MOUNT_POINT/Triage.app" ]] || triage_fail 'the disk image does not contain Triage.app'
[[ -L "$MOUNT_POINT/Applications" ]] || triage_fail 'the disk image does not contain the Applications shortcut'
[[ "$(/usr/bin/readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] \
  || triage_fail 'the disk image Applications shortcut has an unexpected destination'
triage_assert_release_app "$MOUNT_POINT/Triage.app" "${TRIAGE_DEVELOPMENT_TEAM:-}"
if [[ "$PREPARE_ONLY" != "1" ]]; then
  triage_assert_notarized_app "$MOUNT_POINT/Triage.app"
fi

SOURCE_HASH="$(/usr/bin/shasum -a 256 "$APP/Contents/MacOS/Triage" | /usr/bin/awk '{print $1}')"
MOUNTED_HASH="$(/usr/bin/shasum -a 256 "$MOUNT_POINT/Triage.app/Contents/MacOS/Triage" | /usr/bin/awk '{print $1}')"
[[ "$SOURCE_HASH" == "$MOUNTED_HASH" ]] \
  || triage_fail 'the disk image app executable differs from the verified release app'
/usr/bin/hdiutil detach "$MOUNT_POINT" -quiet
IS_MOUNTED=0

if [[ "$PREPARE_ONLY" == "1" ]]; then
  triage_note "Prepared signed disk image $DISK_IMAGE without contacting Apple"
else
  triage_note "Created and verified notarized disk image $DISK_IMAGE"
fi
