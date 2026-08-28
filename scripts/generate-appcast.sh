#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/triage-release.sh"

DERIVED_DATA="${TRIAGE_DERIVED_DATA:-$(triage_default_derived_data Release)}"
UPDATES_DIR="$ROOT_DIR/dist/updates"
APP="$ROOT_DIR/dist/Triage.app"
REPOSITORY="$TRIAGE_EXPECTED_GITHUB_REPOSITORY"
DOWNLOAD_PREFIX="https://github.com/$REPOSITORY/releases/latest/download/"
APPCAST_STAGE="$(/usr/bin/mktemp -d -t triage-appcast.XXXXXX)"

cleanup() {
  /bin/rm -rf "$APPCAST_STAGE"
}
trap cleanup EXIT INT TERM

[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || triage_fail "invalid GitHub repository: $REPOSITORY"
triage_assert_release_app "$APP" "${TRIAGE_DEVELOPMENT_TEAM:-}"
if [[ "${TRIAGE_ALLOW_UNNOTARIZED_PACKAGE:-0}" != "1" ]]; then
  triage_assert_notarized_app "$APP"
fi
GENERATE_APPCAST="$(triage_resolve_sparkle_tool "$ROOT_DIR" "$DERIVED_DATA" generate_appcast)"
triage_assert_sparkle_signing_key "$ROOT_DIR" "$APP" "$DERIVED_DATA"

if [[ ! -d "$UPDATES_DIR" || -z "$(/usr/bin/find "$UPDATES_DIR" -maxdepth 1 -name 'Triage-*.zip' -print -quit)" ]]; then
  "$ROOT_DIR/scripts/package-update.sh"
fi

# Sparkle treats every supported archive in its input directory as an update.
# Keep the GitHub-facing DMG beside the ZIP in dist/updates, but give Sparkle a
# ZIP-only workspace so two containers for the same build cannot be mistaken
# for duplicate updates.
for archive in "$UPDATES_DIR"/Triage-*.zip; do
  [[ -f "$archive" ]] || continue
  /bin/cp "$archive" "$APPCAST_STAGE/"
  notes="${archive%.zip}.md"
  if [[ -f "$notes" ]]; then
    /bin/cp "$notes" "$APPCAST_STAGE/"
  fi
done
for delta in "$UPDATES_DIR"/*.delta; do
  [[ -f "$delta" ]] || continue
  /bin/cp "$delta" "$APPCAST_STAGE/"
done
if [[ -f "$UPDATES_DIR/appcast.xml" ]]; then
  /bin/cp "$UPDATES_DIR/appcast.xml" "$APPCAST_STAGE/appcast.xml"
fi
[[ -n "$(/usr/bin/find "$APPCAST_STAGE" -maxdepth 1 -name 'Triage-*.zip' -print -quit)" ]] \
  || triage_fail 'no Sparkle update ZIP is available for appcast generation'

SIGNING_ARGS=(--account "${TRIAGE_SPARKLE_KEY_ACCOUNT:-ed25519}")
if [[ -n "${TRIAGE_SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  SIGNING_ARGS=(--ed-key-file "$TRIAGE_SPARKLE_PRIVATE_KEY_FILE")
fi

"$GENERATE_APPCAST" \
  "${SIGNING_ARGS[@]}" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --release-notes-url-prefix "$DOWNLOAD_PREFIX" \
  --maximum-versions 5 \
  --maximum-deltas 4 \
  --delta-compression lzfse \
  --phased-rollout-interval "${TRIAGE_PHASED_ROLLOUT_INTERVAL:-86400}" \
  "$APPCAST_STAGE"

[[ -f "$APPCAST_STAGE/appcast.xml" ]] \
  || triage_fail 'Sparkle did not generate an appcast'
/bin/cp "$APPCAST_STAGE/appcast.xml" "$UPDATES_DIR/appcast.xml"
for notes in "$APPCAST_STAGE"/Triage-*.md; do
  [[ -f "$notes" ]] || continue
  /bin/cp "$notes" "$UPDATES_DIR/"
done
for delta in "$APPCAST_STAGE"/*.delta; do
  [[ -f "$delta" ]] || continue
  /bin/cp "$delta" "$UPDATES_DIR/"
done

triage_note "Generated $UPDATES_DIR/appcast.xml"
