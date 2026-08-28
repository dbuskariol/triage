#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/triage-release.sh"

DERIVED_DATA="${TRIAGE_CI_DERIVED_DATA:-$(triage_default_derived_data CI)}"
HOST_ARCH="$(/usr/bin/uname -m)"

while IFS= read -r -d '' script; do
  /bin/bash -n "$script"
done < <(/usr/bin/find "$ROOT_DIR/scripts" -type f -name '*.sh' -print0)
/usr/bin/xcrun swiftc -typecheck "$ROOT_DIR/scripts/sparkle-public-key.swift"
/usr/bin/plutil -lint "$ROOT_DIR/Configuration/Triage-Info.plist" >/dev/null
/usr/bin/plutil -lint "$ROOT_DIR/Triage/Triage.entitlements" >/dev/null
/usr/bin/plutil -lint "$ROOT_DIR/Triage/TriageDebug.entitlements" >/dev/null
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

ARCHITECTURES="$(/usr/bin/lipo -archs "$UNSIGNED_APP/Contents/MacOS/Triage")"
for architecture in "${TRIAGE_EXPECTED_ARCHITECTURES[@]}"; do
  [[ " $ARCHITECTURES " == *" $architecture "* ]] \
    || triage_fail "CI release is missing $architecture (found: $ARCHITECTURES)"
done

triage_note 'CI verification passed'
