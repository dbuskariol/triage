#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULT_DIR="${TRIAGE_PERFORMANCE_RESULTS_DIR:-$(mktemp -d -t triage-performance.XXXXXX)}"
RESULT_PATH="$RESULT_DIR/performance-report.json"
FULL_RECONCILIATION_MEMORY_RESULT_PATH="$RESULT_DIR/full-reconciliation-memory-report.json"
UI_RESULT_PATH="$RESULT_DIR/ui-launch-report.json"
UI_SCROLL_RESULT_PATH="$RESULT_DIR/ui-scroll-report.json"
UI_RESULT_BUNDLE_PATH="$RESULT_DIR/ui-performance.xcresult"
UI_METRICS_PATH="$RESULT_DIR/ui-performance-metrics.json"
DERIVED_DATA=""
DERIVED_DATA_IS_EPHEMERAL=0
KEEP_DERIVED_DATA="${TRIAGE_PERFORMANCE_KEEP_DERIVED_DATA:-0}"
KEEP_RESULTS="${TRIAGE_PERFORMANCE_KEEP_RESULTS:-0}"
XCODEBUILD="${TRIAGE_PERFORMANCE_XCODEBUILD:-/usr/bin/xcodebuild}"

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
  # xcresult bundles and their raw metric JSON may include more test metadata
  # than this benchmark is permitted to retain. The extractor keeps only
  # whitelisted aggregate metrics in the privacy-safe scroll sidecar.
  /bin/rm -rf "$UI_RESULT_BUNDLE_PATH"
  /bin/rm -f "$UI_METRICS_PATH"
  if [[ "$KEEP_RESULTS" != "1" && -z "${TRIAGE_PERFORMANCE_RESULTS_DIR:-}" ]]; then
    /bin/rm -rf "$RESULT_DIR"
  fi
  if [[ "$DERIVED_DATA_IS_EPHEMERAL" == "1" && "$KEEP_DERIVED_DATA" != "1" && -n "$DERIVED_DATA" ]]; then
    /bin/rm -rf "$DERIVED_DATA"
  fi
}
trap cleanup EXIT

prepare_derived_data() {
  if [[ -n "${TRIAGE_PERFORMANCE_DERIVED_DATA:-}" ]]; then
    DERIVED_DATA="$TRIAGE_PERFORMANCE_DERIVED_DATA"
  elif [[ -n "${TRIAGE_CI_DERIVED_DATA:-}" ]]; then
    # CI owns this root. Keep benchmark products separate from the verifier's
    # build products while retaining them under the same recoverable CI tree.
    DERIVED_DATA="$TRIAGE_CI_DERIVED_DATA/Performance"
  else
    DERIVED_DATA="$(mktemp -d -t triage-performance-derived-data.XXXXXX)"
    DERIVED_DATA_IS_EPHEMERAL=1
  fi
}

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
BENCHMARK_SESSION="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
export TRIAGE_PERFORMANCE_BENCHMARK_SESSION="$BENCHMARK_SESSION"
prepare_derived_data

# A caller may reuse a results directory, but prior nonempty sidecars must not
# be accepted as evidence for this distinct benchmark session.
/bin/mkdir -p "$RESULT_DIR"
/bin/rm -f "$RESULT_PATH" "$FULL_RECONCILIATION_MEMORY_RESULT_PATH" "$UI_RESULT_PATH" "$UI_SCROLL_RESULT_PATH"
/bin/rm -rf "$UI_RESULT_BUNDLE_PATH"

# Capture full-reconciliation memory only when explicitly requested. It remains
# measured-unbaselined and deliberately prevents a green aggregate report until
# a supported profile has an approved memory ceiling.
if [[ "${TRIAGE_PERFORMANCE_INCLUDE_FULL_RECONCILIATION_MEMORY:-0}" == "1" ]]; then
  export TRIAGE_FULL_RECONCILIATION_MEMORY_BENCHMARK=1
  export TRIAGE_FULL_RECONCILIATION_MEMORY_RESULT_PATH="$FULL_RECONCILIATION_MEMORY_RESULT_PATH"
  if ! "$XCODEBUILD" \
    -project "$ROOT_DIR/Triage.xcodeproj" \
    -scheme Triage \
    -configuration Debug \
    -destination "platform=macOS,arch=$HOST_ARCHITECTURE" \
    -derivedDataPath "$DERIVED_DATA" \
    -only-testing:TriageTests/FullReconciliationMemoryAcceptanceTests \
    test; then
    echo 'Triage performance result: full-reconciliation memory benchmark failed' >&2
    exit 1
  fi

  [[ -s "$FULL_RECONCILIATION_MEMORY_RESULT_PATH" ]] || {
    echo 'Triage performance result: full-reconciliation memory benchmark produced no report' >&2
    exit 66
  }
fi

if [[ "${TRIAGE_PERFORMANCE_INCLUDE_UI:-0}" == "1" ]]; then
  export TRIAGE_PERFORMANCE_UI_BENCHMARK=1
  export TRIAGE_PERFORMANCE_UI_RESULT_PATH="$UI_RESULT_PATH"
  export TRIAGE_PERFORMANCE_UI_SCROLL_RESULT_PATH="$UI_SCROLL_RESULT_PATH"
  if ! "$XCODEBUILD" \
    -project "$ROOT_DIR/Triage.xcodeproj" \
    -scheme Triage \
    -configuration Debug \
    -destination "platform=macOS,arch=$HOST_ARCHITECTURE" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$UI_RESULT_BUNDLE_PATH" \
    -only-testing:TriageUITests/TriagePerformanceLaunchTests \
    -only-testing:TriageUITests/TriagePerformanceScrollTests \
    test; then
    echo 'Triage performance result: UI benchmark failed' >&2
    exit 1
  fi
  [[ -s "$UI_RESULT_PATH" ]] || {
    echo 'Triage performance result: UI benchmark requested but no launch report was produced' >&2
    exit 66
  }
  [[ -s "$UI_SCROLL_RESULT_PATH" ]] || {
    echo 'Triage performance result: UI benchmark requested but no scroll report was produced' >&2
    exit 66
  }
  /usr/bin/xcrun xcresulttool get test-results metrics \
    --schema-version 0.4.0 \
    --path "$UI_RESULT_BUNDLE_PATH" \
    > "$UI_METRICS_PATH"
  /usr/bin/ruby "$ROOT_DIR/scripts/extract-performance-scroll-metrics.rb" \
    "$UI_SCROLL_RESULT_PATH" \
    "$UI_METRICS_PATH" \
    "$BENCHMARK_SESSION"
  /bin/rm -rf "$UI_RESULT_BUNDLE_PATH"
  /bin/rm -f "$UI_METRICS_PATH"
  export TRIAGE_PERFORMANCE_UI_RESULT_PATH="$UI_RESULT_PATH"
fi

if ! "$XCODEBUILD" \
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

if [[ "${TRIAGE_PERFORMANCE_INCLUDE_UI:-0}" == "1" ]]; then
  /usr/bin/ruby "$ROOT_DIR/scripts/extract-performance-scroll-metrics.rb" \
    --mark-top-level-unbaselined \
    "$RESULT_PATH" \
    "$UI_SCROLL_RESULT_PATH" \
    "$BENCHMARK_SESSION"
fi

if ! /usr/bin/ruby "$ROOT_DIR/scripts/extract-performance-scroll-metrics.rb" \
  --require-top-level-status "$RESULT_PATH" passed; then
  echo 'Triage performance result: benchmark did not produce a passing report' >&2
  /bin/cat "$RESULT_PATH"
  copy_report_if_present
  exit 67
fi

/bin/cat "$RESULT_PATH"
copy_report_if_present
