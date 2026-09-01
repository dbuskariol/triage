#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_LIBRARY="$ROOT_DIR/scripts/lib/triage-release.sh"
CONTRACT_DIRECTORY="$(mktemp -d -t triage-release-verification.XXXXXX)"
SAFE_ENTITLEMENTS="$CONTRACT_DIRECTORY/safe.entitlements"
UNSAFE_ENTITLEMENTS="$CONTRACT_DIRECTORY/unsafe.entitlements"

cleanup() {
  /bin/rm -rf "$CONTRACT_DIRECTORY"
}
trap cleanup EXIT

/usr/bin/plutil -create xml1 "$SAFE_ENTITLEMENTS"
/bin/bash -c '
  source "$1"
  triage_assert_no_unsafe_entitlements "$2" "safe entitlement fixture"
' _ "$RELEASE_LIBRARY" "$SAFE_ENTITLEMENTS"

# A helper with no entitlement blob is still constrained: it has no special
# entitlement to relax runtime protections. The release verifier must accept
# that normal signed-code shape and continue to inspect an actual blob when
# one is present.
/bin/bash -c '
  source "$1"
  triage_assert_safe_signed_entitlements /usr/bin/true "system code fixture"
' _ "$RELEASE_LIBRARY"

# `codesign` includes the independent `adhoc` flag in unsigned CI builds. The
# hardened-runtime verifier must recognize `runtime` as a flag-list member in
# both CI and Developer ID signature renderings, without accepting substrings.
/bin/bash -c '
  source "$1"
  triage_signing_details_enable_hardened_runtime \
    "CodeDirectory v=20500 flags=0x10002(adhoc,runtime)"
  triage_signing_details_enable_hardened_runtime \
    "CodeDirectory v=20500 flags=0x10000(runtime)"
  ! triage_signing_details_enable_hardened_runtime \
    "CodeDirectory v=20500 flags=0x2(adhoc)"
  ! triage_signing_details_enable_hardened_runtime \
    "CodeDirectory v=20500 flags=0x0(notruntime)"
' _ "$RELEASE_LIBRARY"

unsafe_entitlements=(
  com.apple.security.get-task-allow
  com.apple.security.cs.disable-library-validation
  com.apple.security.cs.allow-dyld-environment-variables
  com.apple.security.cs.allow-unsigned-executable-memory
  com.apple.security.cs.allow-jit
  com.apple.security.cs.debugger
  com.apple.security.cs.disable-executable-page-protection
)

for entitlement in "${unsafe_entitlements[@]}"; do
  /usr/bin/plutil -create xml1 "$UNSAFE_ENTITLEMENTS"
  escaped_entitlement="${entitlement//./\\.}"
  /usr/bin/plutil -insert "$escaped_entitlement" -bool YES "$UNSAFE_ENTITLEMENTS"
  if /bin/bash -c '
    source "$1"
    triage_assert_no_unsafe_entitlements "$2" "unsafe entitlement fixture"
  ' _ "$RELEASE_LIBRARY" "$UNSAFE_ENTITLEMENTS" >/dev/null 2>&1; then
    echo "unsafe entitlement fixture: accepted $entitlement" >&2
    exit 1
  fi
done

echo 'Release verification helper contracts passed.'
