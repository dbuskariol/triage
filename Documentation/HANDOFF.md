# Handoff

Current state for anyone picking up Triage. For the full design, read [Architecture](ARCHITECTURE.md).

## What Triage is

An AI-first GitHub triage app for one person in one organization at a time: GitHub personal-work search → encrypted local store → Copilot decisions → user rules → a native Inbox.

## Invariants

- **Local-first and private.** No telemetry, analytics, or uploads. Item content is never logged.
- **Read-only on GitHub.** Never add mutations; the GraphQL registry rejects them.
- **Discovery never waits on Copilot.** AI problems pause analysis; they never block the list.
- **The built-in prompt is fixed.** User control lives in rules and instructions. Bump `TriageRules.promptVersion` when the prompt changes materially.
- **Wire changes need both sides.** A new Copilot response field must be added to the Rust schema, the Swift Codable types, *and* the strict allowlist in `CopilotWireSchema`.
- **Observed tables must be rowid tables** (no `WITHOUT ROWID`) or live UI updates stop.
- **No legacy architecture.** Do not reintroduce organization-wide sync, evidence receipts, or the old derived-intelligence pipeline.

## Working on it

```sh
xcodegen generate
scripts/verify-ci.sh
```

After UI changes, exercise the built app with the keyboard, VoiceOver, light and dark appearance, resizing, and the menu bar. Watch behavior with `log stream --predicate 'subsystem == "com.triage.mac"'`.

## Known gaps

- The production-scale performance benchmark was retired with the rebuild and needs replacing; see [Performance](PERFORMANCE.md).
- Avatars are deterministic initials by design; Triage does not download profile images.
