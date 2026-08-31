#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULT_DIR="${TRIAGE_PERFORMANCE_RESULTS_DIR:-$(mktemp -d -t triage-performance.XXXXXX)}"
RESULT_PATH="$RESULT_DIR/performance-report.json"
UI_RESULT_PATH="$RESULT_DIR/ui-launch-report.json"
DERIVED_DATA="${TRIAGE_PERFORMANCE_DERIVED_DATA:-${HOME:?}/Library/Developer/Xcode/DerivedData/Triage/Performance}"
KEEP_RESULTS="${TRIAGE_PERFORMANCE_KEEP_RESULTS:-0}"

unsupported_baseline() {
  echo 'Triage performance result: unsupported-baseline' >&2
  echo "$1" >&2
  exit 64
}

copy_report_if_present() {
  [[ -n "${TRIAGE_PERFORMANCE_COPY_REPORT_TO:-}" && -s "$RESULT_PATH" ]] || return 0
  /bin/mkdir -p "$(dirname "$TRIAGE_PERFORMANCE_COPY_REPORT_TO")"
  /bin/cp "$RESULT_PATH" "$TRIAGE_PERFORMANCE_COPY_REPORT_TO"
}

cleanup() {
  if [[ "$KEEP_RESULTS" != "1" && -z "${TRIAGE_PERFORMANCE_RESULTS_DIR:-}" ]]; then
    /bin/rm -rf "$RESULT_DIR"
  fi
}
trap cleanup EXIT

if [[ -z "${TRIAGE_PERFORMANCE_BASELINE_PROFILE:-}" ]]; then
  unsupported_baseline "No TRIAGE_PERFORMANCE_BASELINE_PROFILE was declared. Declare one of: entry-apple-silicon-macbookair10,1 or oldest-intel-macmini9,1."
fi

# A declared profile is never authority to benchmark arbitrary hosted hardware.
# Check it before invoking Xcode so unsupported hosts fail closed cheaply.
HOST_ARCHITECTURE="$(/usr/bin/uname -m)"
HOST_MODEL="$(/usr/sbin/sysctl -n hw.model 2>/dev/null || true)"
case "${TRIAGE_PERFORMANCE_BASELINE_PROFILE}:${HOST_ARCHITECTURE}:${HOST_MODEL}" in
  entry-apple-silicon-macbookair10,1:arm64:MacBookAir10,1|oldest-intel-macmini9,1:x86_64:Macmini9,1)
    ;;
  *)
    unsupported_baseline "Declared profile ${TRIAGE_PERFORMANCE_BASELINE_PROFILE} does not match ${HOST_ARCHITECTURE}/${HOST_MODEL:-unknown}."
    ;;
esac

export TRIAGE_PERFORMANCE_BENCHMARK=1
export TRIAGE_PERFORMANCE_RESULT_PATH="$RESULT_PATH"

if [[ "${TRIAGE_PERFORMANCE_INCLUDE_UI:-0}" == "1" ]]; then
  export TRIAGE_PERFORMANCE_UI_BENCHMARK=1
  export TRIAGE_PERFORMANCE_UI_RESULT_PATH="$UI_RESULT_PATH"
  /usr/bin/xcodebuild \
    -project "$ROOT_DIR/Triage.xcodeproj" \
    -scheme Triage \
    -configuration Debug \
    -destination "platform=macOS,arch=$HOST_ARCHITECTURE" \
    -derivedDataPath "$DERIVED_DATA" \
    -only-testing:TriageUITests/TriagePerformanceLaunchTests \
    test
  [[ -s "$UI_RESULT_PATH" ]] || {
    echo 'Triage performance result: UI benchmark requested but no launch report was produced' >&2
    exit 66
  }
  export TRIAGE_PERFORMANCE_UI_RESULT_PATH="$UI_RESULT_PATH"
fi

if ! /usr/bin/xcodebuild \
  -project "$ROOT_DIR/Triage.xcodeproj" \
  -scheme Triage \
  -configuration Debug \
  -destination "platform=macOS,arch=$HOST_ARCHITECTURE" \
  -derivedDataPath "$DERIVED_DATA" \
  -only-testing:TriageTests/PerformanceBudgetTests \
  test; then
  copy_report_if_present
  [[ -s "$RESULT_PATH" ]] && /bin/cat "$RESULT_PATH"
  exit 1
fi

if [[ ! -s "$RESULT_PATH" ]]; then
  echo 'Triage performance result: unsupported-baseline (benchmark did not produce a report)' >&2
  exit 65
fi

/usr/bin/grep -Eq '"status"[[:space:]]*:[[:space:]]*"passed"' "$RESULT_PATH" || {
  echo 'Triage performance result: benchmark did not produce a passing report' >&2
  /bin/cat "$RESULT_PATH"
  copy_report_if_present
  exit 67
}

/bin/cat "$RESULT_PATH"
copy_report_if_present
