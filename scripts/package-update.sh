#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/triage-release.sh"

APP="$ROOT_DIR/dist/Triage.app"
UPDATES_DIR="$ROOT_DIR/dist/updates"
NOTES_SOURCE="${TRIAGE_RELEASE_NOTES_FILE:-$ROOT_DIR/Documentation/RELEASE_NOTES.md}"

if [[ "${TRIAGE_SKIP_BUILD:-0}" != "1" ]]; then
  "$ROOT_DIR/scripts/build-release.sh"
fi

[[ -d "$APP" ]] || triage_fail "app bundle not found: $APP"
[[ -f "$NOTES_SOURCE" ]] || triage_fail "release notes not found: $NOTES_SOURCE"
triage_assert_release_app "$APP" "${TRIAGE_DEVELOPMENT_TEAM:-}"
if [[ "${TRIAGE_ALLOW_UNNOTARIZED_PACKAGE:-0}" != "1" ]]; then
  triage_assert_notarized_app "$APP"
fi

SHORT_VERSION="$(triage_plist_value CFBundleShortVersionString "$APP/Contents/Info.plist")"
BUILD_VERSION="$(triage_plist_value CFBundleVersion "$APP/Contents/Info.plist")"
BASE_NAME="Triage-$SHORT_VERSION-$BUILD_VERSION"
ARCHIVE="$UPDATES_DIR/$BASE_NAME.zip"
NOTES="$UPDATES_DIR/$BASE_NAME.md"

[[ "$(/usr/bin/sed -n '1p' "$NOTES_SOURCE")" == "# Triage $SHORT_VERSION" ]] \
  || triage_fail "release notes do not match Triage $SHORT_VERSION"

/bin/mkdir -p "$UPDATES_DIR"
/bin/rm -f "$ARCHIVE" "$NOTES"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
/bin/cp "$NOTES_SOURCE" "$NOTES"
/usr/bin/unzip -tqq "$ARCHIVE" || triage_fail 'the generated update archive is unreadable'

triage_note "Packaged $ARCHIVE"
