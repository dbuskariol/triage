#!/usr/bin/env bash

# Shared, fail-closed release invariants. Every script that can create a
# distributable Triage artifact sources this file so local and CI releases are
# held to the same standard.

if [[ -n "${TRIAGE_RELEASE_LIB_LOADED:-}" ]]; then
  return 0
fi
readonly TRIAGE_RELEASE_LIB_LOADED=1

readonly TRIAGE_EXPECTED_BUNDLE_ID="com.triage.mac"
readonly TRIAGE_EXPECTED_MINIMUM_SYSTEM="26.0"
readonly TRIAGE_EXPECTED_ARCHITECTURES=(arm64 x86_64)
readonly TRIAGE_EXPECTED_GITHUB_REPOSITORY="${TRIAGE_GITHUB_REPOSITORY:-dbuskariol/triage}"
readonly TRIAGE_EXPECTED_FEED_URL="https://github.com/$TRIAGE_EXPECTED_GITHUB_REPOSITORY/releases/latest/download/appcast.xml"

triage_fail() {
  printf 'Triage release error: %s\n' "$1" >&2
  exit 1
}

triage_note() {
  printf '==> %s\n' "$1"
}

triage_default_derived_data() {
  local purpose="$1"
  local base="${TRIAGE_DERIVED_DATA_ROOT:-${HOME:?}/Library/Developer/Xcode/DerivedData/Triage}"

  # Build and test hosts are executable code. Keep them out of protected user
  # folders so macOS never mistakes routine verification for Documents access.
  printf '%s/%s\n' "$base" "$purpose"
}

triage_require_tool() {
  /usr/bin/command -v "$1" >/dev/null 2>&1 || triage_fail "required tool is unavailable: $1"
}

triage_plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null || true
}

triage_assert_expected_architectures() {
  local executable="$1"
  local label="$2"
  local architectures architecture

  architectures="$(/usr/bin/lipo -archs "$executable")" \
    || triage_fail "$label architectures could not be inspected: $executable"
  for architecture in "${TRIAGE_EXPECTED_ARCHITECTURES[@]}"; do
    [[ " $architectures " == *" $architecture "* ]] \
      || triage_fail "$label is missing $architecture (found: $architectures)"
  done
}

triage_assert_no_unsafe_entitlements() {
  local entitlements="$1"
  local label="$2"
  local entitlement
  local unsafe_entitlements=(
    com.apple.security.get-task-allow
    com.apple.security.cs.disable-library-validation
    com.apple.security.cs.allow-dyld-environment-variables
    com.apple.security.cs.allow-unsigned-executable-memory
    com.apple.security.cs.allow-jit
    com.apple.security.cs.debugger
    com.apple.security.cs.disable-executable-page-protection
  )

  /usr/bin/plutil -lint "$entitlements" >/dev/null \
    || triage_fail "$label entitlements are invalid: $entitlements"
  for entitlement in "${unsafe_entitlements[@]}"; do
    [[ -z "$(triage_plist_value "$entitlement" "$entitlements")" ]] \
      || triage_fail "$label contains forbidden entitlement: $entitlement"
  done
}

triage_json_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$2" 2>/dev/null || true
}

triage_codesign_details() {
  /usr/bin/codesign -dvvv --verbose=4 "$1" 2>&1
}

triage_signature_team() {
  /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$(triage_codesign_details "$1")"
}

triage_assert_code_identifier() {
  local signed_path="$1"
  local expected_identifier="$2"
  local label="$3"
  local actual_identifier

  actual_identifier="$(/usr/bin/awk -F= '/^Identifier=/{print $2; exit}' <<<"$(triage_codesign_details "$signed_path")")"
  [[ "$actual_identifier" == "$expected_identifier" ]] \
    || triage_fail "$label has an unexpected code identifier: ${actual_identifier:-missing}"
}

triage_assert_safe_signed_entitlements() {
  local signed_path="$1"
  local label="$2"
  local entitlements

  entitlements="$(/usr/bin/mktemp -t triage-signed-entitlements.XXXXXX)"
  /usr/bin/codesign -d --entitlements :- "$signed_path" >"$entitlements" 2>/dev/null \
    || { /bin/rm -f "$entitlements"; triage_fail "unable to inspect $label entitlements"; }
  # A code object without an entitlements blob is constrained by no special
  # entitlement. Treat that as safe while still linting any blob that exists.
  if [[ -s "$entitlements" ]]; then
    if ! (triage_assert_no_unsafe_entitlements "$entitlements" "$label"); then
      /bin/rm -f "$entitlements"
      triage_fail "$label contains unsafe entitlements"
    fi
  fi
  /bin/rm -f "$entitlements"
}

triage_assert_developer_id_signature() {
  local signed_path="$1"
  local expected_team="${2:-}"
  local require_hardened_runtime="${3:-0}"
  local signing_details team

  /usr/bin/codesign --verify --strict --verbose=2 "$signed_path" \
    || triage_fail "the code signature is invalid: $signed_path"
  signing_details="$(triage_codesign_details "$signed_path")"
  /usr/bin/grep -q '^Authority=Developer ID Application:' <<<"$signing_details" \
    || triage_fail "Developer ID Application did not sign: $signed_path"
  /usr/bin/grep -Eq '^Timestamp=.+$' <<<"$signing_details" \
    || triage_fail "the signature is missing a trusted timestamp: $signed_path"
  if [[ "$require_hardened_runtime" == "1" ]]; then
    /usr/bin/grep -Eq '^CodeDirectory .*flags=.*\(runtime\)' <<<"$signing_details" \
      || triage_fail "the hardened runtime is not enabled: $signed_path"
  fi
  team="$(/usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$signing_details")"
  [[ -n "$team" && "$team" != "not set" ]] \
    || triage_fail "the signature is missing its team identifier: $signed_path"
  if [[ -n "$expected_team" && "$team" != "$expected_team" ]]; then
    triage_fail "signature team $team does not match expected team $expected_team: $signed_path"
  fi
}

triage_find_developer_id_identity() {
  /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/awk -F\" '/Developer ID Application/ { print $2; exit }'
}

triage_assert_clean_worktree() {
  local root="$1"
  if [[ "${TRIAGE_ALLOW_DIRTY:-0}" == "1" ]]; then
    return 0
  fi
  [[ -z "$(/usr/bin/git -C "$root" status --porcelain --untracked-files=normal)" ]] \
    || triage_fail 'the worktree is dirty; commit the verified release source first (or set TRIAGE_ALLOW_DIRTY=1 for a non-shipping rehearsal)'
}

triage_assert_release_metadata() {
  local root="$1"
  local settings version build notes_heading tag
  settings="$(/usr/bin/xcodebuild \
    -project "$root/Triage.xcodeproj" \
    -scheme Triage \
    -configuration Release \
    -showBuildSettings 2>/dev/null)"
  version="$(/usr/bin/awk '/MARKETING_VERSION =/{print $3; exit}' <<<"$settings")"
  build="$(/usr/bin/awk '/CURRENT_PROJECT_VERSION =/{print $3; exit}' <<<"$settings")"

  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] \
    || triage_fail "MARKETING_VERSION is not a release version: ${version:-missing}"
  [[ "$build" =~ ^[1-9][0-9]*$ ]] \
    || triage_fail "CURRENT_PROJECT_VERSION must be a positive integer: ${build:-missing}"

  notes_heading="$(/usr/bin/sed -n '1p' "$root/Documentation/RELEASE_NOTES.md" 2>/dev/null || true)"
  [[ "$notes_heading" == "# Triage $version" ]] \
    || triage_fail "release notes must start with '# Triage $version'"

  tag="${TRIAGE_RELEASE_TAG:-}"
  if [[ -z "$tag" && "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
    tag="${GITHUB_REF_NAME:-}"
  fi
  # An exact tag describes the committed tree, not uncommitted version work.
  # Release builds already require a clean worktree; local verification must
  # remain usable while preparing the next version directly from a release tag.
  if [[ -z "$tag" && -z "$(/usr/bin/git -C "$root" status --porcelain --untracked-files=normal)" ]]; then
    tag="$(/usr/bin/git -C "$root" describe --tags --exact-match 2>/dev/null || true)"
  fi
  if [[ -n "$tag" ]]; then
    [[ "$tag" == "v$version" ]] \
      || triage_fail "release tag $tag does not match MARKETING_VERSION $version"
  elif [[ "${TRIAGE_REQUIRE_RELEASE_TAG:-0}" == "1" ]]; then
    triage_fail "a v$version release tag is required"
  fi

  printf '%s\t%s\n' "$version" "$build"
}

triage_assert_release_app() {
  local app="$1"
  local expected_team="${2:-}"
  local info executable bundle_id minimum_system version build team entitlements

  [[ -d "$app" ]] || triage_fail "app bundle not found: $app"
  info="$app/Contents/Info.plist"
  [[ -f "$info" ]] || triage_fail "Info.plist is missing from $app"
  /usr/bin/plutil -lint "$info" >/dev/null || triage_fail 'Info.plist is invalid'

  bundle_id="$(triage_plist_value CFBundleIdentifier "$info")"
  minimum_system="$(triage_plist_value LSMinimumSystemVersion "$info")"
  version="$(triage_plist_value CFBundleShortVersionString "$info")"
  build="$(triage_plist_value CFBundleVersion "$info")"
  executable="$app/Contents/MacOS/$(triage_plist_value CFBundleExecutable "$info")"

  [[ "$bundle_id" == "$TRIAGE_EXPECTED_BUNDLE_ID" ]] \
    || triage_fail "unexpected bundle identifier: ${bundle_id:-missing}"
  [[ "$minimum_system" == "$TRIAGE_EXPECTED_MINIMUM_SYSTEM" ]] \
    || triage_fail "minimum system must be macOS $TRIAGE_EXPECTED_MINIMUM_SYSTEM"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] \
    || triage_fail "invalid app version: ${version:-missing}"
  [[ "$build" =~ ^[1-9][0-9]*$ ]] \
    || triage_fail "invalid app build: ${build:-missing}"
  [[ -x "$executable" ]] || triage_fail "main executable is missing: $executable"
  /usr/bin/codesign --verify --strict --deep --verbose=2 "$app" \
    || triage_fail 'the app signature is invalid'
  triage_assert_developer_id_signature "$app" "$expected_team" 1
  team="$(triage_signature_team "$app")"

  triage_assert_expected_architectures "$executable" 'the release app executable'

  entitlements="$(/usr/bin/mktemp -t triage-entitlements.XXXXXX)"
  /usr/bin/codesign -d --entitlements :- "$app" >"$entitlements" 2>/dev/null \
    || { /bin/rm -f "$entitlements"; triage_fail 'unable to inspect release entitlements'; }
  if ! (triage_assert_no_unsafe_entitlements "$entitlements" 'release app'); then
    /bin/rm -f "$entitlements"
    triage_fail 'release app contains unsafe entitlements'
  fi
  /bin/rm -f "$entitlements"

  [[ -f "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" ]] \
    || triage_fail 'the embedded Sparkle framework is missing'
  local copilot_xpc copilot_xpc_executable copilot_helper copilot_xpc_entitlements
  copilot_xpc="$app/Contents/XPCServices/TriageCopilotXPC.xpc"
  [[ -d "$copilot_xpc" ]] || triage_fail 'the embedded Copilot XPC service is missing'
  [[ "$(triage_plist_value CFBundleIdentifier "$copilot_xpc/Contents/Info.plist")" == "com.triage.mac.TriageCopilotXPC" ]] \
    || triage_fail 'the embedded Copilot XPC service has an unexpected bundle identifier'
  copilot_xpc_executable="$copilot_xpc/Contents/MacOS/TriageCopilotXPC"
  [[ -x "$copilot_xpc_executable" ]] \
    || triage_fail 'the embedded Copilot XPC service executable is missing'
  triage_assert_expected_architectures "$copilot_xpc_executable" 'the embedded Copilot XPC service executable'
  triage_assert_developer_id_signature "$copilot_xpc" "$team" 1
  copilot_xpc_entitlements="$(/usr/bin/mktemp -t triage-copilot-xpc-entitlements.XXXXXX)"
  /usr/bin/codesign -d --entitlements :- "$copilot_xpc" >"$copilot_xpc_entitlements" 2>/dev/null \
    || { /bin/rm -f "$copilot_xpc_entitlements"; triage_fail 'unable to inspect Copilot XPC entitlements'; }
  if ! (triage_assert_no_unsafe_entitlements "$copilot_xpc_entitlements" 'embedded Copilot XPC service'); then
    /bin/rm -f "$copilot_xpc_entitlements"
    triage_fail 'embedded Copilot XPC service contains unsafe entitlements'
  fi
  /bin/rm -f "$copilot_xpc_entitlements"
  copilot_helper="$copilot_xpc/Contents/Resources/TriageCopilotHelper"
  [[ -x "$copilot_helper" ]] \
    || triage_fail 'the embedded Copilot helper executable is missing'
  triage_assert_expected_architectures "$copilot_helper" 'the embedded Copilot helper executable'
  triage_assert_developer_id_signature "$copilot_helper" "$team" 1
  triage_assert_code_identifier \
    "$copilot_helper" 'com.triage.mac.TriageCopilotHelper' 'the embedded Copilot helper executable'
  triage_assert_safe_signed_entitlements "$copilot_helper" 'the embedded Copilot helper executable'
  local sparkle_code
  for sparkle_code in \
    "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" \
    "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" \
    "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
    "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
    "$app/Contents/Frameworks/Sparkle.framework"
  do
    [[ -e "$sparkle_code" ]] || triage_fail "embedded Sparkle code is missing: $sparkle_code"
    triage_assert_developer_id_signature "$sparkle_code" "$team" 1
  done
  local privacy_manifest="$app/Contents/Resources/PrivacyInfo.xcprivacy"
  [[ -f "$privacy_manifest" ]] || triage_fail 'the app privacy manifest is missing'
  /usr/bin/plutil -lint "$privacy_manifest" >/dev/null \
    || triage_fail 'the app privacy manifest is invalid'
  [[ "$(triage_plist_value NSPrivacyTracking "$privacy_manifest")" == "false" ]] \
    || triage_fail 'the app privacy manifest unexpectedly declares tracking'
  [[ "$(/usr/bin/plutil -extract NSPrivacyCollectedDataTypes raw -o - "$privacy_manifest")" == "0" ]] \
    || triage_fail 'the app privacy manifest unexpectedly declares collected data'
  [[ "$(/usr/bin/plutil -extract NSPrivacyTrackingDomains raw -o - "$privacy_manifest")" == "0" ]] \
    || triage_fail 'the app privacy manifest unexpectedly declares tracking domains'
  [[ "$(/usr/bin/plutil -extract NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPIType raw -o - "$privacy_manifest")" == "NSPrivacyAccessedAPICategoryUserDefaults" ]] \
    || triage_fail 'the app privacy manifest is missing its UserDefaults required-reason declaration'
  [[ "$(/usr/bin/plutil -extract NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons.0 raw -o - "$privacy_manifest")" == "CA92.1" ]] \
    || triage_fail 'the app privacy manifest has an unexpected UserDefaults required reason'
  local feed_url public_key
  feed_url="$(triage_plist_value SUFeedURL "$info")"
  public_key="$(triage_plist_value SUPublicEDKey "$info")"
  [[ "$feed_url" == "$TRIAGE_EXPECTED_FEED_URL" ]] \
    || triage_fail "unexpected Sparkle feed URL: ${feed_url:-missing}"
  [[ "$public_key" =~ ^[A-Za-z0-9+/=]{40,}$ ]] \
    || triage_fail 'the Sparkle EdDSA public key is invalid'
  [[ "$(triage_plist_value SURequireSignedFeed "$info")" == "true" ]] \
    || triage_fail 'signed Sparkle feeds are not required by the app'
  [[ "$(triage_plist_value SUVerifyUpdateBeforeExtraction "$info")" == "true" ]] \
    || triage_fail 'Sparkle update verification before extraction is disabled'
}

triage_assert_notarized_app() {
  local app="$1"
  /usr/bin/xcrun stapler validate "$app" >/dev/null \
    || triage_fail 'the app does not contain a valid stapled notarization ticket'
  /usr/sbin/spctl --assess --type execute --verbose=4 "$app" \
    || triage_fail 'Gatekeeper rejected the app'
}

triage_assert_signed_disk_image() {
  local disk_image="$1"
  local expected_team="${2:-}"

  [[ -f "$disk_image" ]] || triage_fail "disk image not found: $disk_image"
  /usr/bin/hdiutil verify "$disk_image" >/dev/null \
    || triage_fail 'the disk image failed its integrity check'
  triage_assert_developer_id_signature "$disk_image" "$expected_team"
}

triage_assert_notarized_disk_image() {
  local disk_image="$1"
  local expected_team="${2:-}"

  triage_assert_signed_disk_image "$disk_image" "$expected_team"
  /usr/bin/xcrun stapler validate "$disk_image" >/dev/null \
    || triage_fail 'the disk image does not contain a valid stapled notarization ticket'
  /usr/sbin/spctl \
    --assess \
    --type open \
    --context context:primary-signature \
    --verbose=4 \
    "$disk_image" \
    || triage_fail 'Gatekeeper rejected the disk image'
}

TRIAGE_NOTARY_ARGS=()

triage_configure_notary_credentials() {
  TRIAGE_NOTARY_ARGS=()
  if [[ -n "${TRIAGE_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    TRIAGE_NOTARY_ARGS=(--keychain-profile "$TRIAGE_NOTARY_KEYCHAIN_PROFILE")
  elif [[ -n "${TRIAGE_NOTARY_KEY_PATH:-}" \
    && -n "${TRIAGE_NOTARY_KEY_ID:-}" \
    && -n "${TRIAGE_NOTARY_ISSUER_ID:-}" ]]; then
    [[ -f "$TRIAGE_NOTARY_KEY_PATH" ]] \
      || triage_fail "App Store Connect API key is missing: $TRIAGE_NOTARY_KEY_PATH"
    TRIAGE_NOTARY_ARGS=(
      --key "$TRIAGE_NOTARY_KEY_PATH"
      --key-id "$TRIAGE_NOTARY_KEY_ID"
      --issuer "$TRIAGE_NOTARY_ISSUER_ID"
    )
  else
    /bin/cat >&2 <<'EOF'
Notarization credentials are not configured. Use a stored Keychain profile:

  TRIAGE_NOTARY_KEYCHAIN_PROFILE="Triage Notary" scripts/release.sh finalize

CI may instead provide TRIAGE_NOTARY_KEY_PATH, TRIAGE_NOTARY_KEY_ID, and
TRIAGE_NOTARY_ISSUER_ID. Passwords and Apple IDs are never accepted inline.
EOF
    exit 1
  fi
}

triage_submit_notarization() {
  local artifact="$1"
  local submission_json="$2"
  local log_json="$3"
  local submission_id status log_status issue_count issue_type

  triage_configure_notary_credentials
  /bin/rm -f "$submission_json" "$log_json"
  /usr/bin/xcrun notarytool submit \
    "$artifact" \
    "${TRIAGE_NOTARY_ARGS[@]}" \
    --wait \
    --output-format json >"$submission_json"

  submission_id="$(triage_json_value id "$submission_json")"
  status="$(triage_json_value status "$submission_json")"
  [[ -n "$submission_id" ]] || triage_fail 'Apple notarization returned no submission identifier'
  /usr/bin/xcrun notarytool log \
    "$submission_id" \
    "$log_json" \
    "${TRIAGE_NOTARY_ARGS[@]}" \
    >/dev/null

  log_status="$(triage_json_value status "$log_json")"
  if ! issue_count="$(/usr/bin/plutil -extract issues raw -o - "$log_json" 2>/dev/null)"; then
    issue_type="$(/usr/bin/plutil -type issues "$log_json" 2>/dev/null || true)"
    [[ "$issue_type" == "(any)" ]] \
      || triage_fail "Apple's notarization log has an unreadable issues field; inspect $log_json"
    issue_count=0
  fi
  [[ "$status" == "Accepted" && "$log_status" == "Accepted" ]] \
    || triage_fail "notarization failed with status ${status:-unknown}; inspect $log_json"
  [[ "$issue_count" == "0" ]] \
    || triage_fail "notarization reported ${issue_count:-unknown} issues; inspect $log_json"
}

triage_resolve_sparkle_tool() {
  local root="$1"
  local derived_data="$2"
  local tool="$3"
  local path="$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin/$tool"
  if [[ ! -x "$path" ]]; then
    /usr/bin/xcodebuild \
      -project "$root/Triage.xcodeproj" \
      -scheme Triage \
      -configuration Release \
      -destination 'generic/platform=macOS' \
      -derivedDataPath "$derived_data" \
      -resolvePackageDependencies >/dev/null
  fi
  [[ -x "$path" ]] || triage_fail "Sparkle tool was not resolved: $tool"
  printf '%s\n' "$path"
}

triage_assert_sparkle_signing_key() {
  local root="$1"
  local app="$2"
  local derived_data="$3"
  local embedded_key actual_key generate_keys
  embedded_key="$(triage_plist_value SUPublicEDKey "$app/Contents/Info.plist")"

  if [[ -n "${TRIAGE_SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
    [[ -f "$TRIAGE_SPARKLE_PRIVATE_KEY_FILE" ]] \
      || triage_fail "Sparkle private key file is missing: $TRIAGE_SPARKLE_PRIVATE_KEY_FILE"
    actual_key="$(/usr/bin/xcrun swift "$root/scripts/sparkle-public-key.swift" "$TRIAGE_SPARKLE_PRIVATE_KEY_FILE")" \
      || triage_fail 'unable to derive the Sparkle public key'
  else
    generate_keys="$(triage_resolve_sparkle_tool "$root" "$derived_data" generate_keys)"
    actual_key="$("$generate_keys" --account "${TRIAGE_SPARKLE_KEY_ACCOUNT:-ed25519}" -p 2>/dev/null)" \
      || triage_fail 'unable to read the Sparkle signing key from Keychain'
  fi
  [[ "$actual_key" == "$embedded_key" ]] \
    || triage_fail 'the Sparkle signing key does not match SUPublicEDKey embedded in Triage'
}
