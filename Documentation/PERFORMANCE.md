# Performance verification

`TriageTests/Performance/PerformanceFixture.swift` is the committed generator
for the production-scale data contract in the implementation plan. It streams
bounded batches rather than checking a private database fixture into source
control. The generated store contains 10,000 Work Items, 100,000 timeline
events, 250 repositories, 50 Projects with 10,000 items, 5,000 discussions,
5,000 discussion replies, 25,000 searchable comments, and 500 actionable
items.

Normal tests verify the counts, deterministic shape, bounded generation batch
size, representative page limits, opt-in gate, and nearest-rank median/p95
calculation. Existing workspace query-plan regression tests retain the ordinary
test coverage for the selected indexes. Full-scale database seeding is reserved
for the opt-in benchmark, so canonical CI does not spend its normal unit-test
budget inserting more than 150,000 rows.

The benchmark opens the fixture through `AccountVault`, with its production
SQLCipher configuration and migrations. It then measures the production
workspace observation stream, `WorkItemRepository` graph decode and native
Inbox eligibility rule, and `SearchRepository` search path. Detail presentation
receives the selected production `WorkItem`; it does not issue benchmark-only
timeline or comment SQL. Its fixed 32-byte key is a test-only input for an
isolated temporary directory; it is never written to the repository as a
credential. Timing is opt-in because a wall-clock result on an arbitrary
developer or hosted CI machine is not a reliable regression signal.

Run the benchmark only on a declared supported baseline:

```sh
TRIAGE_PERFORMANCE_BASELINE_PROFILE=entry-apple-silicon-macbookair10,1 \
  TRIAGE_PERFORMANCE_COPY_REPORT_TO=/tmp/triage-performance.json \
  scripts/run-performance-benchmarks.sh
```

The runner independently verifies the physical model and architecture. Its
currently declared profiles are `MacBookAir10,1` (`arm64`, entry Apple silicon)
and `Macmini9,1` (`x86_64`, oldest Intel). A model/profile mismatch exits with
an explicit `unsupported-baseline` result; it never records a green benchmark
for an unrecognised machine.

The JSON report records three warm-ups and eleven post-warm-up samples, median,
and p95. Its `status` is explicitly `passed`, `failed`, or
`unsupported-baseline`; a failed threshold cannot be mistaken for a green
measurement, and the runner refuses to complete successfully unless its status
is `passed`. It uses nearest-rank percentiles: for eleven samples, median is the
sixth sorted observation and p95 is the slowest observation. Median
targets are 150 ms for cached workspace switch, 100 ms for the Inbox first
page, 150 ms for local search, and 100 ms for initial detail data. P95 has a
documented 20% host-noise tolerance. The Xcode test fails when an identified
baseline exceeds either threshold.

Set `TRIAGE_PERFORMANCE_INCLUDE_UI=1` on an XCUITest-capable baseline host to
add an eleven-sample launch measurement to the same report. Its median target
is one second and p95 tolerance is 1.2 seconds. The interactive-ready signal is
the deterministic DEBUG-only workspace fixture's `Triage sidebar` readiness.
The launch test is still opt-in and is never enabled merely because a hosted
runner has the correct architecture.

GitHub Actions may opt in by setting
`TRIAGE_PERFORMANCE_APPLE_SILICON_PROFILE` and/or
`TRIAGE_PERFORMANCE_INTEL_PROFILE` to the exact profile installed on its
corresponding runner. Without either variable, the performance step is absent
rather than silently using a different machine as a baseline.
To include UI launch measurement in one of those jobs, also set the matching
`TRIAGE_PERFORMANCE_APPLE_SILICON_UI_PROFILE` or
`TRIAGE_PERFORMANCE_INTEL_UI_PROFILE` to exactly the same declared baseline
profile, and only after that runner has been confirmed XCUITest-capable.
Reports are printed to the job log and may be copied to a local temporary path;
the workflow does not upload benchmark data or send telemetry.

The runner's shell contracts can be checked without building or seeding a
database. `scripts/verify-ci.sh` runs these contracts after shell syntax checks
and before its Swift typecheck, unit-test build, or release build:

```sh
scripts/test-performance-benchmark-runner.sh
```
