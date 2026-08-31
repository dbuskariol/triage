#!/usr/bin/env bash
set -euo pipefail

# Builds Triage's own Rust process boundary only. The helper intentionally has
# no packaged Copilot CLI/runtime; Cargo is offline and the SDK's CLI download
# path is explicitly disabled for every architecture slice.

if [[ -n "${SRCROOT:-}" ]]; then
  ROOT_DIR="$(cd "$SRCROOT" && pwd)" \
    || { echo "Unable to resolve Xcode SRCROOT: $SRCROOT" >&2; exit 64; }
  [[ -f "$ROOT_DIR/TriageCopilotHelper/Cargo.toml" && -f "$ROOT_DIR/TriageCopilotHelper/Cargo.lock" ]] \
    || { echo "Xcode SRCROOT is not the Triage repository root: $ROOT_DIR" >&2; exit 64; }
else
  # Direct contract tests execute the script from the checkout. XcodeGen
  # inlines it into a DerivedData script, so build invocations must use
  # SRCROOT above rather than BASH_SOURCE.
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
HELPER_DIR="$ROOT_DIR/TriageCopilotHelper"
HELPER_NAME="TriageCopilotHelper"
HELPER_IDENTIFIER="com.triage.mac.TriageCopilotHelper"
CARGO="${TRIAGE_COPILOT_HELPER_CARGO:-cargo}"
LIPO="${TRIAGE_COPILOT_HELPER_LIPO:-/usr/bin/lipo}"
CODESIGN="${TRIAGE_COPILOT_HELPER_CODESIGN:-/usr/bin/codesign}"

# macOS 27's linker-generated ad-hoc signature can leave proc-macro dylibs with
# a misaligned LINKEDIT string pool. Cargo only needs those dylibs during the
# build, and this script explicitly signs the final helper below, so suppress
# linker ad-hoc signing for Rust intermediates while preserving caller flags.
rustflags="${RUSTFLAGS:-}"
rustflags="${rustflags:+$rustflags }-C link-arg=-Wl,-no_adhoc_codesign"
cargo_executable="$(command -v "$CARGO")" \
  || { echo "Unable to resolve the configured Cargo executable: $CARGO" >&2; exit 69; }
cargo_path="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$HOME/.cargo/bin"

: "${ARCHS:?Xcode must provide ARCHS for the Copilot helper build}"
: "${TARGET_BUILD_DIR:?Xcode must provide TARGET_BUILD_DIR for the Copilot helper build}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?Xcode must provide UNLOCALIZED_RESOURCES_FOLDER_PATH}"

configuration="${CONFIGURATION:-Debug}"
case "$configuration" in
  Debug) cargo_profile=debug ;;
  Release) cargo_profile=release ;;
  *) echo "Unsupported Copilot helper build configuration: ${CONFIGURATION:-missing}" >&2; exit 64 ;;
esac

case "$ARCHS" in
  *' '* ) read -r -a requested_architectures <<<"$ARCHS" ;;
  *) requested_architectures=("$ARCHS") ;;
esac

declare -a rust_targets=()
for architecture in "${requested_architectures[@]}"; do
  case "$architecture" in
    arm64) rust_targets+=(aarch64-apple-darwin) ;;
    x86_64) rust_targets+=(x86_64-apple-darwin) ;;
    *) echo "Unsupported Copilot helper architecture requested by Xcode: $architecture" >&2; exit 64 ;;
  esac
done

[[ ${#rust_targets[@]} -gt 0 ]] || { echo 'No Copilot helper architectures were requested.' >&2; exit 64; }

# Keep Cargo intermediates outside the target's DerivedSources directory so
# app/test builds that share Xcode DerivedData reuse the compiled Rust crates.
# Configuration and Rust target remain part of the path. Cargo places host-built
# procedural macros outside the requested target subdirectory, so universal
# builds must not share one target directory between arm64 and x86_64 slices.
if [[ -n "${TRIAGE_CI_DERIVED_DATA:-}" ]]; then
  cargo_cache_root="$TRIAGE_CI_DERIVED_DATA"
elif [[ -n "${OBJROOT:-}" ]]; then
  cargo_cache_root="$OBJROOT"
else
  cargo_cache_root="${DERIVED_FILE_DIR:-$TARGET_BUILD_DIR/DerivedSources}"
fi
cargo_target_root="$cargo_cache_root/TriageCopilotHelper-Cargo/$configuration"
resource_directory="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
output_helper="$resource_directory/$HELPER_NAME"
slice_directory="$cargo_target_root/triage-helper-slices"
/bin/mkdir -p "$resource_directory" "$slice_directory"

declare -a slices=()
for index in "${!rust_targets[@]}"; do
  rust_target="${rust_targets[$index]}"
  architecture="${requested_architectures[$index]}"
  architecture_target_dir="$cargo_target_root/$rust_target"
  cargo_arguments=(build --locked --offline --target "$rust_target")
  if [[ "$cargo_profile" == release ]]; then
    cargo_arguments+=(--release)
  fi

  cargo_environment=(
    "HOME=$HOME"
    "PATH=$cargo_path"
    'CARGO_NET_OFFLINE=true'
    'COPILOT_SKIP_CLI_DOWNLOAD=1'
    "CARGO_TARGET_DIR=$architecture_target_dir"
    "RUSTFLAGS=$rustflags"
  )
  [[ -z "${TMPDIR:-}" ]] || cargo_environment+=("TMPDIR=$TMPDIR")
  [[ -z "${CARGO_HOME:-}" ]] || cargo_environment+=("CARGO_HOME=$CARGO_HOME")
  [[ -z "${RUSTUP_HOME:-}" ]] || cargo_environment+=("RUSTUP_HOME=$RUSTUP_HOME")
  [[ -z "${MACOSX_DEPLOYMENT_TARGET:-}" ]] \
    || cargo_environment+=("MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET")
  [[ -z "${TRIAGE_TEST_LOG:-}" ]] || cargo_environment+=("TRIAGE_TEST_LOG=$TRIAGE_TEST_LOG")

  /usr/bin/env -i "${cargo_environment[@]}" \
    "$cargo_executable" "${cargo_arguments[@]}" --manifest-path "$HELPER_DIR/Cargo.toml"

  slice="$architecture_target_dir/$rust_target/$cargo_profile/triage-copilot-helper"
  [[ -x "$slice" ]] || { echo "Cargo did not produce the $architecture Copilot helper slice: $slice" >&2; exit 1; }
  copied_slice="$slice_directory/$architecture"
  /bin/cp "$slice" "$copied_slice"
  /bin/chmod 755 "$copied_slice"
  slices+=("$copied_slice")
done

if [[ ${#slices[@]} -eq 1 ]]; then
  /bin/cp "${slices[0]}" "$output_helper"
else
  "$LIPO" -create "${slices[@]}" -output "$output_helper"
fi
/bin/chmod 755 "$output_helper"

# Xcode may deliberately disable signing for its unsigned CI Release build. In
# that case an ad-hoc signature preserves the nested-code shape Xcode would
# otherwise produce. Developer ID builds use the selected identity and receive
# the hardened runtime before Xcode signs the enclosing XPC service.
signing_identity="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
if [[ -z "$signing_identity" || "${CODE_SIGNING_ALLOWED:-YES}" == NO ]]; then
  signing_identity=-
fi
codesign_arguments=(--force --sign "$signing_identity" --identifier "$HELPER_IDENTIFIER" --options runtime)
if [[ "$signing_identity" != - && "$configuration" == Release ]]; then
  codesign_arguments+=(--timestamp)
fi
"$CODESIGN" "${codesign_arguments[@]}" "$output_helper"
