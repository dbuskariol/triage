#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT_DIR/scripts/build-copilot-helper.sh"
CONTRACT_DIRECTORY="$(mktemp -d -t triage-copilot-helper-build.XXXXXX)"
FAKE_BIN="$CONTRACT_DIRECTORY/bin"
BUILD_DIRECTORY="$CONTRACT_DIRECTORY/build"
DERIVED_DIRECTORY="$CONTRACT_DIRECTORY/derived"
CACHE_DIRECTORY="$CONTRACT_DIRECTORY/shared-derived-data"
LOG="$CONTRACT_DIRECTORY/log"
mkdir -p "$FAKE_BIN" "$BUILD_DIRECTORY" "$DERIVED_DIRECTORY" "$CACHE_DIRECTORY"
INLINE_RUNNER="$DERIVED_DIRECTORY/inlined-xcode-build-phase.sh"
/bin/cp "$RUNNER" "$INLINE_RUNNER"
/bin/chmod 755 "$INLINE_RUNNER"

cleanup() {
  /bin/rm -rf "$CONTRACT_DIRECTORY"
}
trap cleanup EXIT

cat >"$FAKE_BIN/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'cargo %s\n' "$*" >>"$TRIAGE_TEST_LOG"
printf 'cargo-target-dir %s\n' "$CARGO_TARGET_DIR" >>"$TRIAGE_TEST_LOG"
[[ "${CARGO_NET_OFFLINE:-}" == true ]]
[[ "${COPILOT_SKIP_CLI_DOWNLOAD:-}" == 1 ]]
target=""
for ((index = 1; index <= $#; index++)); do
  if [[ "${!index}" == --target ]]; then
    next=$((index + 1))
    target="${!next}"
  fi
done
[[ -n "$target" ]]
profile=debug
[[ " $* " == *' --release '* ]] && profile=release
output="$CARGO_TARGET_DIR/$target/$profile/triage-copilot-helper"
mkdir -p "$(dirname "$output")"
printf '#!/usr/bin/env bash\nexit 0\n' >"$output"
chmod 755 "$output"
EOF
cat >"$FAKE_BIN/lipo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'lipo %s\n' "$*" >>"$TRIAGE_TEST_LOG"
[[ "$1" == -create ]]
while [[ "$1" != -output ]]; do shift; done
output="$2"
printf '#!/usr/bin/env bash\nexit 0\n' >"$output"
chmod 755 "$output"
EOF
cat >"$FAKE_BIN/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'codesign %s\n' "$*" >>"$TRIAGE_TEST_LOG"
[[ " $* " == *' --identifier com.triage.mac.TriageCopilotHelper '* ]]
[[ " $* " == *' --options runtime '* ]]
EOF
chmod +x "$FAKE_BIN/cargo" "$FAKE_BIN/lipo" "$FAKE_BIN/codesign"

run_contract() {
  : >"$LOG"
  env \
    ARCHS='arm64 x86_64' \
    CONFIGURATION=Release \
    CODE_SIGNING_ALLOWED=NO \
    TARGET_BUILD_DIR="$BUILD_DIRECTORY" \
    UNLOCALIZED_RESOURCES_FOLDER_PATH='TriageCopilotXPC.xpc/Contents/Resources' \
    DERIVED_FILE_DIR="$DERIVED_DIRECTORY" \
    TRIAGE_CI_DERIVED_DATA="$CACHE_DIRECTORY" \
    SRCROOT="$ROOT_DIR" \
    TRIAGE_COPILOT_HELPER_CARGO="$FAKE_BIN/cargo" \
    TRIAGE_COPILOT_HELPER_LIPO="$FAKE_BIN/lipo" \
    TRIAGE_COPILOT_HELPER_CODESIGN="$FAKE_BIN/codesign" \
    TRIAGE_TEST_LOG="$LOG" \
    "$INLINE_RUNNER"
}

run_contract
HELPER="$BUILD_DIRECTORY/TriageCopilotXPC.xpc/Contents/Resources/TriageCopilotHelper"
[[ -x "$HELPER" ]] || { echo 'helper build contract: helper was not embedded' >&2; exit 1; }
[[ "$(grep -c '^cargo ' "$LOG")" -eq 2 ]] || { echo 'helper build contract: expected two offline Cargo slices' >&2; exit 1; }
grep -Fq -- '--locked --offline --target aarch64-apple-darwin --release' "$LOG"
grep -Fq -- '--locked --offline --target x86_64-apple-darwin --release' "$LOG"
grep -Fq -- "--manifest-path $ROOT_DIR/TriageCopilotHelper/Cargo.toml" "$LOG"
[[ "$(grep -Fc "cargo-target-dir $CACHE_DIRECTORY/TriageCopilotHelper-Cargo/Release" "$LOG")" -eq 2 ]] \
  || { echo 'helper build contract: Release slices must share the CI derived-data cache' >&2; exit 1; }
grep -q '^lipo -create ' "$LOG"
grep -Fq -- '--sign - ' "$LOG"

if env SRCROOT="$CONTRACT_DIRECTORY/not-a-repository" "$INLINE_RUNNER" >/dev/null 2>&1; then
  echo 'helper build contract: an invalid Xcode SRCROOT was accepted' >&2
  exit 1
fi

: >"$LOG"
env \
  ARCHS=arm64 \
  CONFIGURATION=Debug \
  CODE_SIGNING_ALLOWED=YES \
  EXPANDED_CODE_SIGN_IDENTITY=0123456789ABCDEF \
  TARGET_BUILD_DIR="$BUILD_DIRECTORY/debug" \
  UNLOCALIZED_RESOURCES_FOLDER_PATH='TriageCopilotXPC.xpc/Contents/Resources' \
  DERIVED_FILE_DIR="$DERIVED_DIRECTORY/debug" \
  TRIAGE_CI_DERIVED_DATA="$CACHE_DIRECTORY" \
  TRIAGE_COPILOT_HELPER_CARGO="$FAKE_BIN/cargo" \
  TRIAGE_COPILOT_HELPER_LIPO="$FAKE_BIN/lipo" \
  TRIAGE_COPILOT_HELPER_CODESIGN="$FAKE_BIN/codesign" \
  TRIAGE_TEST_LOG="$LOG" \
  "$RUNNER"
[[ -x "$BUILD_DIRECTORY/debug/TriageCopilotXPC.xpc/Contents/Resources/TriageCopilotHelper" ]] \
  || { echo 'helper build contract: Debug helper was not embedded' >&2; exit 1; }
[[ "$(grep -c '^cargo ' "$LOG")" -eq 1 ]] \
  || { echo 'helper build contract: Debug must build one active architecture' >&2; exit 1; }
grep -Fq -- '--locked --offline --target aarch64-apple-darwin' "$LOG"
grep -Fq -- "cargo-target-dir $CACHE_DIRECTORY/TriageCopilotHelper-Cargo/Debug" "$LOG"
if grep -Fq -- '--release' "$LOG"; then
  echo 'helper build contract: Debug must not request the Cargo release profile' >&2
  exit 1
fi
if grep -q '^lipo ' "$LOG"; then
  echo 'helper build contract: Debug single architecture must not invoke lipo' >&2
  exit 1
fi
grep -Fq -- '--sign 0123456789ABCDEF ' "$LOG"

echo 'Copilot helper build contracts passed.'
