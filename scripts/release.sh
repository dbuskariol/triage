#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/triage-release.sh"

MODE="${1:-prepare}"
case "$MODE" in
  prepare|finalize) ;;
  *)
    printf 'Usage: scripts/release.sh [prepare|finalize]\n' >&2
    exit 64
    ;;
esac

if [[ "$MODE" == "finalize" ]]; then
  [[ "${TRIAGE_ALLOW_DIRTY:-0}" != "1" ]] \
    || triage_fail 'final releases can never be built from a dirty worktree'
  export TRIAGE_REQUIRE_RELEASE_TAG=1
fi

triage_assert_clean_worktree "$ROOT_DIR"
IFS=$'\t' read -r VERSION BUILD < <(triage_assert_release_metadata "$ROOT_DIR")
triage_note "Preparing Triage $VERSION ($BUILD) in $MODE mode"

"$ROOT_DIR/scripts/build-release.sh"

if [[ "$MODE" == "prepare" ]]; then
  TRIAGE_NOTARY_PREPARE_ONLY=1 "$ROOT_DIR/scripts/notarize-release.sh"
  TRIAGE_SKIP_BUILD=1 \
    TRIAGE_ALLOW_UNNOTARIZED_PACKAGE=1 \
    "$ROOT_DIR/scripts/package-update.sh"
  TRIAGE_ALLOW_UNNOTARIZED_PACKAGE=1 \
    "$ROOT_DIR/scripts/generate-appcast.sh"
  TRIAGE_ALLOW_UNNOTARIZED_PACKAGE=1 \
    "$ROOT_DIR/scripts/create-release-manifest.sh"
  triage_note 'Release rehearsal passed; no Apple service or publishing state was changed'
  exit 0
fi

"$ROOT_DIR/scripts/notarize-release.sh"
"$ROOT_DIR/scripts/create-release-manifest.sh"

triage_note "Triage $VERSION ($BUILD) is signed, notarized, stapled, Sparkle-signed, and ready to publish"
