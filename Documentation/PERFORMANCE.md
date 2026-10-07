# Performance

## Expected timings

Measured on Apple silicon with about 215 items of personal work in one large organization.

| Stage | Typical |
|---|---|
| Launch to saved list | Immediate (from the local store) |
| GitHub refresh (all relationships) | 30–45 s, two concurrent searches, 25 results per page |
| Copilot batch (15 items) | 20–45 s, one batch at a time |
| First full analysis (about 215 items) | 8–10 min, most urgent first; later cycles analyze only changed items |
| Done, Snooze, Restore | Instant (optimistic UI, saved in the background) |

Changing instructions or rules, **Re-analyze All**, and prompt-version updates re-analyze every item once in the background; existing decisions remain visible meanwhile.

## Measuring

Use the unified log, which records every stage with its duration:

```sh
log show --last 30m --style compact \
  --predicate 'subsystem == "com.triage.mac" AND (category == "Engine" OR category == "Copilot")'
```

## Benchmarks

The production-scale database benchmark and its fixtures belonged to the pre-rebuild architecture and were removed. `scripts/run-performance-benchmarks.sh` still references those retired suites (`PerformanceBudgetTests`, `FullReconciliationMemoryAcceptanceTests`) and the UI launch and scroll tests, and needs to be rewritten for the AI-first core before use. `scripts/test-performance-benchmark-runner.sh`, run by CI, only checks the runner script's argument handling.
