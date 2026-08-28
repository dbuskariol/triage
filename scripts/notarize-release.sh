#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/triage-release.sh"

APP="${TRIAGE_NOTARY_APP:-$ROOT_DIR/dist/Triage.app}"
OUTPUT_DIR="${TRIAGE_NOTARY_OUTPUT_DIR:-$ROOT_DIR/dist/notarization}"
PREPARE_ONLY="${TRIAGE_NOTARY_PREPARE_ONLY:-0}"

triage_assert_release_app "$APP" "${TRIAGE_DEVELOPMENT_TEAM:-}"

SHORT_VERSION="$(triage_plist_value CFBundleShortVersionString "$APP/Contents/Info.plist")"
BUILD_VERSION="$(triage_plist_value CFBundleVersion "$APP/Contents/Info.plist")"
ARCHIVE="$OUTPUT_DIR/Triage-$SHORT_VERSION-$BUILD_VERSION-notarization.zip"
SUBMISSION_JSON="$OUTPUT_DIR/notary-submit-app-$SHORT_VERSION-$BUILD_VERSION.json"
LOG_JSON="$OUTPUT_DIR/notary-log-app-$SHORT_VERSION-$BUILD_VERSION.json"

/bin/mkdir -p "$OUTPUT_DIR"
/bin/rm -f "$ARCHIVE" "$SUBMISSION_JSON" "$LOG_JSON"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

if [[ "$PREPARE_ONLY" == "1" ]]; then
  /usr/bin/unzip -tqq "$ARCHIVE" || triage_fail 'the notarization archive is unreadable'
  TRIAGE_NOTARY_PREPARE_ONLY=1 "$ROOT_DIR/scripts/create-dmg.sh"
  triage_note "Prepared $ARCHIVE"
  exit 0
fi

triage_note 'Submitting the signed app to Apple notarization'
triage_submit_notarization "$ARCHIVE" "$SUBMISSION_JSON" "$LOG_JSON"

/usr/bin/xcrun stapler staple "$APP"
triage_assert_release_app "$APP" "${TRIAGE_DEVELOPMENT_TEAM:-}"
triage_assert_notarized_app "$APP"

TRIAGE_SKIP_BUILD=1 "$ROOT_DIR/scripts/package-update.sh"
"$ROOT_DIR/scripts/generate-appcast.sh"
"$ROOT_DIR/scripts/create-dmg.sh"

triage_note "Notarized, stapled, and packaged $APP"
