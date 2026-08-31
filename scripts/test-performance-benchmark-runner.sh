#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT_DIR/scripts/run-performance-benchmarks.sh"
CONTRACT_DIRECTORY="$(mktemp -d -t triage-performance-contract.XXXXXX)"
RESULT_DIRECTORY="$CONTRACT_DIRECTORY/results"
COPIED_REPORT="$CONTRACT_DIRECTORY/copied-report.json"
MISMATCH_RUNNER="$CONTRACT_DIRECTORY/run-performance-with-mismatched-host.sh"

cleanup() {
  /bin/rm -rf "$CONTRACT_DIRECTORY"
}
trap cleanup EXIT

expect_unsupported_baseline() {
  local description="$1"
  shift
  local output
  local status

  set +e
  output="$(env "$@" "$RUNNER" 2>&1)"
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
  [[ "$output" != *"xcodebuild"* ]] || {
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

echo 'Performance benchmark runner contracts passed.'
