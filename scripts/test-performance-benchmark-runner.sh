#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT_DIR/scripts/run-performance-benchmarks.sh"
CONTRACT_DIRECTORY="$(mktemp -d -t triage-performance-contract.XXXXXX)"
RESULT_DIRECTORY="$CONTRACT_DIRECTORY/results"
COPIED_REPORT="$CONTRACT_DIRECTORY/copied-report.json"
MISMATCH_RUNNER="$CONTRACT_DIRECTORY/run-performance-with-mismatched-host.sh"
SUPPORTED_RUNNER="$CONTRACT_DIRECTORY/run-performance-with-supported-host.sh"
XCODEBUILD_SHIM="$CONTRACT_DIRECTORY/xcodebuild-shim.sh"
XCODEBUILD_MARKER="$CONTRACT_DIRECTORY/xcodebuild-invoked"
XCODEBUILD_ARGUMENTS="$CONTRACT_DIRECTORY/xcodebuild-arguments"

cleanup() {
  /bin/rm -rf "$CONTRACT_DIRECTORY"
}
trap cleanup EXIT

# The explicitly opt-in full-reconciliation sidecar must be collected before
# optional UI launch/scroll and the database report that consumes their paths.
# Keep each output path distinct so a stale or malformed sidecar cannot
# masquerade as another measurement.
MEMORY_OPT_IN_LINE="$(/usr/bin/grep -n -- 'TRIAGE_PERFORMANCE_INCLUDE_FULL_RECONCILIATION_MEMORY:-0' "$RUNNER" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
MEMORY_LINE="$(/usr/bin/grep -n -- '-only-testing:TriageTests/FullReconciliationMemoryAcceptanceTests' "$RUNNER" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
UI_LAUNCH_LINE="$(/usr/bin/grep -n -- '-only-testing:TriageUITests/TriagePerformanceLaunchTests' "$RUNNER" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
UI_SCROLL_LINE="$(/usr/bin/grep -n -- '-only-testing:TriageUITests/TriagePerformanceScrollTests' "$RUNNER" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
DATABASE_LINE="$(/usr/bin/grep -n -- '-only-testing:TriageTests/PerformanceBudgetTests' "$RUNNER" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
[[ -n "$MEMORY_OPT_IN_LINE" && -n "$MEMORY_LINE" && -n "$UI_LAUNCH_LINE" && -n "$UI_SCROLL_LINE" && -n "$DATABASE_LINE" ]] || {
  echo 'runner must select full-reconciliation, launch, scroll, and database benchmark tests' >&2
  exit 1
}
[[ "$MEMORY_OPT_IN_LINE" -lt "$MEMORY_LINE" && "$MEMORY_LINE" -lt "$UI_LAUNCH_LINE" && "$UI_LAUNCH_LINE" -le "$UI_SCROLL_LINE" && "$UI_SCROLL_LINE" -lt "$DATABASE_LINE" ]] || {
  echo 'runner must sequence memory, UI launch/scroll, then database reporting' >&2
  exit 1
}
/usr/bin/grep -Fq 'TRIAGE_FULL_RECONCILIATION_MEMORY_RESULT_PATH="$FULL_RECONCILIATION_MEMORY_RESULT_PATH"' "$RUNNER" || {
  echo 'runner must export the full-reconciliation sidecar path' >&2
  exit 1
}
/usr/bin/grep -Fq 'TRIAGE_PERFORMANCE_UI_RESULT_PATH="$UI_RESULT_PATH"' "$RUNNER" || {
  echo 'runner must export the UI launch sidecar path' >&2
  exit 1
}
/usr/bin/grep -Fq 'TRIAGE_PERFORMANCE_UI_SCROLL_RESULT_PATH="$UI_SCROLL_RESULT_PATH"' "$RUNNER" || {
  echo 'runner must export the UI scroll sidecar path' >&2
  exit 1
}
/usr/bin/grep -Fq -- '-resultBundlePath "$UI_RESULT_BUNDLE_PATH"' "$RUNNER" || {
  echo 'runner must capture the UI result bundle for scroll/hitch extraction' >&2
  exit 1
}
/usr/bin/grep -Fq 'xcresulttool get test-results metrics' "$RUNNER" || {
  echo 'runner must extract XCTest scroll/hitch metrics from the result bundle' >&2
  exit 1
}
/usr/bin/grep -Fq 'extract-performance-scroll-metrics.rb' "$RUNNER" || {
  echo 'runner must reduce XCTest metrics through the privacy-safe extractor' >&2
  exit 1
}

/usr/bin/printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  ': "${TRIAGE_PERFORMANCE_XCODEBUILD_MARKER:?}"' \
  ': > "$TRIAGE_PERFORMANCE_XCODEBUILD_MARKER"' \
  ': "${TRIAGE_PERFORMANCE_XCODEBUILD_ARGUMENTS:?}"' \
  'printf "%s\\n" "$@" > "$TRIAGE_PERFORMANCE_XCODEBUILD_ARGUMENTS"' \
  'exit 99' >"$XCODEBUILD_SHIM"
/bin/chmod +x "$XCODEBUILD_SHIM"

expect_unsupported_baseline() {
  local description="$1"
  shift
  local output
  local status

  /bin/rm -f "$XCODEBUILD_MARKER"
  set +e
  output="$(env \
    TRIAGE_PERFORMANCE_XCODEBUILD="$XCODEBUILD_SHIM" \
    TRIAGE_PERFORMANCE_XCODEBUILD_MARKER="$XCODEBUILD_MARKER" \
    TRIAGE_PERFORMANCE_XCODEBUILD_ARGUMENTS="$XCODEBUILD_ARGUMENTS" \
    "$@" \
    "$RUNNER" 2>&1)"
  status=$?
  set -e

  [[ $status -eq 64 ]] || {
    echo "$description: expected exit 64, got $status" >&2
    exit 1
  }
  [[ "$output" == *"unsupported-baseline"* ]] || {
    echo "$description: expected explicit unsupported-baseline result" >&2
    exit 1
  }
  [[ ! -e "$XCODEBUILD_MARKER" ]] || {
    echo "$description: must fail before invoking Xcode" >&2
    exit 1
  }
}

expect_unsupported_baseline \
  "missing profile" \
  TRIAGE_PERFORMANCE_RESULTS_DIR="$RESULT_DIRECTORY" \
  TRIAGE_PERFORMANCE_COPY_REPORT_TO="$COPIED_REPORT"
[[ ! -e "$RESULT_DIRECTORY/performance-report.json" ]] || {
  echo 'missing profile: unsupported hosts must not write a benchmark report' >&2
  exit 1
}
[[ ! -e "$COPIED_REPORT" ]] || {
  echo 'missing profile: unsupported hosts must not copy a benchmark report' >&2
  exit 1
}

expect_unsupported_baseline \
  "unknown profile" \
  TRIAGE_PERFORMANCE_BASELINE_PROFILE=not-a-baseline \
  TRIAGE_PERFORMANCE_RESULTS_DIR="$RESULT_DIRECTORY" \
  TRIAGE_PERFORMANCE_COPY_REPORT_TO="$COPIED_REPORT"
[[ ! -e "$RESULT_DIRECTORY/performance-report.json" ]] || {
  echo 'unknown profile: unsupported hosts must not write a benchmark report' >&2
  exit 1
}
[[ ! -e "$COPIED_REPORT" ]] || {
  echo 'unknown profile: unsupported hosts must not copy a benchmark report' >&2
  exit 1
}

# Exercise the real matching branch with a recognized declared profile but an
# incompatible physical host. The temporary copy changes only host discovery;
# the production runner never accepts environment-overridden host identity.
/usr/bin/sed \
  -e 's|^HOST_ARCHITECTURE=.*$|HOST_ARCHITECTURE="arm64"|' \
  -e 's|^HOST_MODEL=.*$|HOST_MODEL="Macmini9,1"|' \
  "$RUNNER" >"$MISMATCH_RUNNER"
/bin/chmod +x "$MISMATCH_RUNNER"
RUNNER="$MISMATCH_RUNNER"
expect_unsupported_baseline \
  "recognized profile on mismatched physical host" \
  TRIAGE_PERFORMANCE_BASELINE_PROFILE=entry-apple-silicon-macbookair10,1 \
  TRIAGE_PERFORMANCE_RESULTS_DIR="$RESULT_DIRECTORY" \
  TRIAGE_PERFORMANCE_COPY_REPORT_TO="$COPIED_REPORT"
[[ ! -e "$RESULT_DIRECTORY/performance-report.json" ]] || {
  echo 'mismatched host: unsupported hosts must not write a benchmark report' >&2
  exit 1
}
[[ ! -e "$COPIED_REPORT" ]] || {
  echo 'mismatched host: unsupported hosts must not copy a benchmark report' >&2
  exit 1
}

# Exercise only the derived-data routing after a recognized host passes. The
# copied runner changes host discovery for this shell contract; production code
# never accepts an environment-overridden host identity.
/usr/bin/sed \
  -e 's|^HOST_ARCHITECTURE=.*$|HOST_ARCHITECTURE="arm64"|' \
  -e 's|^HOST_MODEL=.*$|HOST_MODEL="MacBookAir10,1"|' \
  "$ROOT_DIR/scripts/run-performance-benchmarks.sh" >"$SUPPORTED_RUNNER"
/bin/chmod +x "$SUPPORTED_RUNNER"

expect_derived_data_path() {
  local description="$1"
  local expected_path="$2"
  shift 2
  local status
  local actual_path

  /bin/rm -f "$XCODEBUILD_MARKER" "$XCODEBUILD_ARGUMENTS"
  set +e
  env \
    TRIAGE_PERFORMANCE_BASELINE_PROFILE=entry-apple-silicon-macbookair10,1 \
    TRIAGE_PERFORMANCE_XCODEBUILD="$XCODEBUILD_SHIM" \
    TRIAGE_PERFORMANCE_XCODEBUILD_MARKER="$XCODEBUILD_MARKER" \
    TRIAGE_PERFORMANCE_XCODEBUILD_ARGUMENTS="$XCODEBUILD_ARGUMENTS" \
    "$@" \
    "$SUPPORTED_RUNNER" >/dev/null 2>&1
  status=$?
  set -e

  [[ $status -eq 1 ]] || {
    echo "$description: expected shimmed benchmark to exit 1, got $status" >&2
    exit 1
  }
  [[ -e "$XCODEBUILD_MARKER" && -s "$XCODEBUILD_ARGUMENTS" ]] || {
    echo "$description: expected benchmark to invoke the Xcode shim" >&2
    exit 1
  }
  actual_path="$(/usr/bin/awk 'previous == "-derivedDataPath" { print; exit } { previous = $0 }' "$XCODEBUILD_ARGUMENTS")"
  [[ "$actual_path" == "$expected_path" ]] || {
    echo "$description: expected derived data at $expected_path, got ${actual_path:-missing}" >&2
    exit 1
  }
}

CI_DERIVED_DATA="$CONTRACT_DIRECTORY/ci-derived-data"
expect_derived_data_path \
  'CI derived data' \
  "$CI_DERIVED_DATA/Performance" \
  TRIAGE_CI_DERIVED_DATA="$CI_DERIVED_DATA"
! /usr/bin/grep -Fq -- '-only-testing:TriageTests/FullReconciliationMemoryAcceptanceTests' "$XCODEBUILD_ARGUMENTS" || {
  echo 'default benchmark run must not invoke full-reconciliation memory collection' >&2
  exit 1
}

# The memory collector is an explicit non-green diagnostic. Its first runner
# invocation must select only the memory test when it is opted in.
/bin/rm -f "$XCODEBUILD_MARKER" "$XCODEBUILD_ARGUMENTS"
set +e
env \
  TRIAGE_PERFORMANCE_BASELINE_PROFILE=entry-apple-silicon-macbookair10,1 \
  TRIAGE_PERFORMANCE_INCLUDE_FULL_RECONCILIATION_MEMORY=1 \
  TRIAGE_PERFORMANCE_XCODEBUILD="$XCODEBUILD_SHIM" \
  TRIAGE_PERFORMANCE_XCODEBUILD_MARKER="$XCODEBUILD_MARKER" \
  TRIAGE_PERFORMANCE_XCODEBUILD_ARGUMENTS="$XCODEBUILD_ARGUMENTS" \
  "$SUPPORTED_RUNNER" >/dev/null 2>&1
status=$?
set -e
[[ $status -eq 1 ]] || {
  echo "opt-in memory benchmark: expected shimmed exit 1, got $status" >&2
  exit 1
}
/usr/bin/grep -Fq -- '-only-testing:TriageTests/FullReconciliationMemoryAcceptanceTests' "$XCODEBUILD_ARGUMENTS" || {
  echo 'opt-in memory benchmark must invoke full-reconciliation collection first' >&2
  exit 1
}

# A local benchmark owns an mktemp-derived path and must reclaim it after a
# failed invocation, avoiding a persistent per-user Performance tree.
/bin/rm -f "$XCODEBUILD_MARKER" "$XCODEBUILD_ARGUMENTS"
set +e
env \
  TRIAGE_PERFORMANCE_BASELINE_PROFILE=entry-apple-silicon-macbookair10,1 \
  TRIAGE_PERFORMANCE_XCODEBUILD="$XCODEBUILD_SHIM" \
  TRIAGE_PERFORMANCE_XCODEBUILD_MARKER="$XCODEBUILD_MARKER" \
  TRIAGE_PERFORMANCE_XCODEBUILD_ARGUMENTS="$XCODEBUILD_ARGUMENTS" \
  "$SUPPORTED_RUNNER" >/dev/null 2>&1
status=$?
set -e
[[ $status -eq 1 ]] || {
  echo "ephemeral derived data: expected shimmed benchmark to exit 1, got $status" >&2
  exit 1
}
LOCAL_DERIVED_DATA="$(/usr/bin/awk 'previous == "-derivedDataPath" { print; exit } { previous = $0 }' "$XCODEBUILD_ARGUMENTS")"
[[ "$LOCAL_DERIVED_DATA" == *'/triage-performance-derived-data.'* ]] || {
  echo "ephemeral derived data: expected a mktemp performance path, got ${LOCAL_DERIVED_DATA:-missing}" >&2
  exit 1
}
[[ ! -e "$LOCAL_DERIVED_DATA" ]] || {
  echo 'ephemeral derived data: runner did not clean its owned derived data' >&2
  exit 1
}

echo 'Performance benchmark runner contracts passed.'
