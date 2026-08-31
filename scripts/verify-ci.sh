#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/triage-release.sh"

DERIVED_DATA="${TRIAGE_CI_DERIVED_DATA:-$(triage_default_derived_data CI)}"
HOST_ARCH="$(/usr/bin/uname -m)"

while IFS= read -r -d '' script; do
  /bin/bash -n "$script"
done < <(/usr/bin/find "$ROOT_DIR/scripts" -type f -name '*.sh' -print0)
/bin/bash "$ROOT_DIR/scripts/test-performance-benchmark-runner.sh"
/bin/bash "$ROOT_DIR/scripts/test-build-copilot-helper.sh"
/bin/bash "$ROOT_DIR/scripts/test-release-verification-helpers.sh"
/bin/bash "$ROOT_DIR/scripts/verify-xpc-package-mirror.sh"
/usr/bin/xcrun swiftc -typecheck "$ROOT_DIR/scripts/sparkle-public-key.swift"
/usr/bin/plutil -lint "$ROOT_DIR/Configuration/Triage-Info.plist" >/dev/null
/usr/bin/plutil -lint "$ROOT_DIR/Triage/Triage.entitlements" >/dev/null
/usr/bin/plutil -lint "$ROOT_DIR/Triage/TriageDebug.entitlements" >/dev/null
/usr/bin/plutil -lint "$ROOT_DIR/Configuration/TriageCopilotXPC-Info.plist" >/dev/null
/usr/bin/plutil -lint "$ROOT_DIR/TriageCopilotXPC/TriageCopilotXPC.entitlements" >/dev/null
triage_assert_no_unsafe_entitlements \
  "$ROOT_DIR/TriageCopilotXPC/TriageCopilotXPC.entitlements" \
  'Copilot XPC source'
/usr/bin/plutil -lint "$ROOT_DIR/Triage/PrivacyInfo.xcprivacy" >/dev/null
/bin/bash "$ROOT_DIR/scripts/verify-vendored-dependencies.sh" >/dev/null
/usr/bin/grep -Fq '"revision" : "b6496a74a087257ef5e6da1c5b29a447a60f5bd7"' \
  "$ROOT_DIR/Triage.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
  || triage_fail 'the Xcode Sparkle dependency is not revision-locked'
/usr/bin/git -C "$ROOT_DIR" diff --check
triage_assert_release_metadata "$ROOT_DIR" >/dev/null

/usr/bin/xcodebuild \
  -project "$ROOT_DIR/Triage.xcodeproj" \
  -scheme Triage \
  -configuration Debug \
  -destination "platform=macOS,arch=$HOST_ARCH" \
  -derivedDataPath "$DERIVED_DATA" \
  test
/usr/bin/xcodebuild \
  -project "$ROOT_DIR/Triage.xcodeproj" \
  -scheme Triage \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CLANG_ENABLE_CODE_COVERAGE=NO \
  GCC_GENERATE_TEST_COVERAGE_FILES=NO \
  GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=NO \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO \
  build

UNSIGNED_APP="$DERIVED_DATA/Build/Products/Release/Triage.app"
[[ -d "$UNSIGNED_APP" ]] || triage_fail "CI release app was not produced at $UNSIGNED_APP"
INFO="$UNSIGNED_APP/Contents/Info.plist"
[[ "$(triage_plist_value CFBundleIdentifier "$INFO")" == "$TRIAGE_EXPECTED_BUNDLE_ID" ]] \
  || triage_fail 'CI release has an unexpected bundle identifier'
[[ "$(triage_plist_value LSMinimumSystemVersion "$INFO")" == "$TRIAGE_EXPECTED_MINIMUM_SYSTEM" ]] \
  || triage_fail 'CI release has an unexpected deployment target'
[[ "$(triage_plist_value SUFeedURL "$INFO")" == "$TRIAGE_EXPECTED_FEED_URL" ]] \
  || triage_fail 'CI release has an unexpected Sparkle feed URL'
[[ -f "$UNSIGNED_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" ]] \
  || triage_fail 'CI release is missing Sparkle'
XPC_SERVICE="$UNSIGNED_APP/Contents/XPCServices/TriageCopilotXPC.xpc"
[[ -d "$XPC_SERVICE" ]] || triage_fail 'CI release is missing the Copilot XPC service'
[[ "$(triage_plist_value CFBundleIdentifier "$XPC_SERVICE/Contents/Info.plist")" == "com.triage.mac.TriageCopilotXPC" ]] \
  || triage_fail 'CI release has an unexpected Copilot XPC service bundle identifier'
[[ -x "$XPC_SERVICE/Contents/MacOS/TriageCopilotXPC" ]] \
  || triage_fail 'CI release is missing the Copilot XPC service executable'
COPILOT_HELPER="$XPC_SERVICE/Contents/Resources/TriageCopilotHelper"
[[ -x "$COPILOT_HELPER" ]] \
  || triage_fail 'CI release is missing the Copilot helper executable'
/usr/bin/codesign --verify --strict --verbose=2 "$COPILOT_HELPER" \
  || triage_fail 'CI release Copilot helper signature is invalid'
triage_assert_code_identifier \
  "$COPILOT_HELPER" 'com.triage.mac.TriageCopilotHelper' 'CI release Copilot helper'
grep -Eq '^CodeDirectory .*flags=.*\(runtime\)' <<<"$(triage_codesign_details "$COPILOT_HELPER")" \
  || triage_fail 'CI release Copilot helper does not enable the hardened runtime'
triage_assert_safe_signed_entitlements "$COPILOT_HELPER" 'CI release Copilot helper'
PRIVACY_MANIFEST="$UNSIGNED_APP/Contents/Resources/PrivacyInfo.xcprivacy"
[[ -f "$PRIVACY_MANIFEST" ]] || triage_fail 'CI release is missing its privacy manifest'
/usr/bin/plutil -lint "$PRIVACY_MANIFEST" >/dev/null \
  || triage_fail 'CI release contains an invalid privacy manifest'
[[ "$(triage_plist_value NSPrivacyTracking "$PRIVACY_MANIFEST")" == "false" ]] \
  || triage_fail 'CI release unexpectedly declares tracking'
[[ "$(/usr/bin/plutil -extract NSPrivacyCollectedDataTypes raw -o - "$PRIVACY_MANIFEST")" == "0" ]] \
  || triage_fail 'CI release unexpectedly declares collected data'
[[ "$(/usr/bin/plutil -extract NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPIType raw -o - "$PRIVACY_MANIFEST")" == "NSPrivacyAccessedAPICategoryUserDefaults" ]] \
  || triage_fail 'CI release is missing its UserDefaults required-reason declaration'
[[ "$(/usr/bin/plutil -extract NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons.0 raw -o - "$PRIVACY_MANIFEST")" == "CA92.1" ]] \
  || triage_fail 'CI release has an unexpected UserDefaults required reason'

triage_assert_expected_architectures "$UNSIGNED_APP/Contents/MacOS/Triage" 'CI release app executable'
triage_assert_expected_architectures "$XPC_SERVICE/Contents/MacOS/TriageCopilotXPC" 'CI release Copilot XPC service executable'
triage_assert_expected_architectures "$COPILOT_HELPER" 'CI release Copilot helper executable'

triage_note 'CI verification passed'
