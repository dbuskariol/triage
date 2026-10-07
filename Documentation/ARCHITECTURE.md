# Architecture

Triage is a local-first macOS app with one job: show the signed-in user the GitHub work that needs their attention, prioritized by Copilot. This document explains how it does that.

## Overview

```mermaid
flowchart TB
    subgraph App["Triage.app (Swift 6, SwiftUI)"]
        UI[Views<br/>Workspace · Detail · Settings]
        Model[TriageAppModel]
        Engine[TriageEngine actor]
        Discovery[GitHubPersonalWorkDiscovery]
        Store[(GRDBTriageStore<br/>SQLCipher vault)]
        Decider[CopilotTriageDecider]
    end
    subgraph Helper["Copilot boundary"]
        XPC[TriageCopilotXPC service]
        Rust[TriageCopilotHelper (Rust)<br/>pinned Copilot runtime]
    end
    GitHub[(GitHub GraphQL)]
    Copilot[(GitHub Copilot)]

    UI <--> Model
    Model --> Engine
    Model <-- live entries --> Store
    Engine --> Discovery --> GitHub
    Engine --> Store
    Engine --> Decider --> XPC --> Rust --> Copilot
```

| Component | Responsibility |
|---|---|
| `TriageCore.swift` | Domain types (`PersonalWorkItem`, `TriageDecision`, `TriageEntry`, `LocalStatus`, `TriageStatus`) and the `PersonalWorkDiscovering`, `TriageStore`, and `TriageDeciding` protocols. |
| `GitHubPersonalWorkDiscovery` | One GraphQL search per relationship (review requested, assigned, authored, mentioned, commented), 25 per page, two concurrent queries, transient-failure retries. Mentions and comments look back 60 days. |
| `GRDBTriageStore` | Items, decisions, analysis failures, local status (done/snoozed), refresh times, and rules, per account and organization. Publishes live entries through GRDB `ValueObservation`. |
| `TriageEngine` | The loop: refresh → save → analyze changed items → wait. Publishes `TriageStatus` (phase, problem, last/next refresh, handled count). |
| `CopilotTriageDecider` | Builds bounded Copilot requests, reuses one authenticated helper session, and maps responses to decisions. |
| `TriageRules` | Hard rules, free-text instructions, and the decision digest. |
| `WorkspacePresentation` | Pure grouping and sorting of entries into sections after applying rules. Views never sort raw data. |

## The engine cycle

1. **Refresh.** Discovery returns every item involving the user. The store upserts them and deactivates items that no longer match (merged, closed, unassigned). Inactive work is kept for 30 days.
2. **Select.** The store returns active items whose decision is missing or stale (see *Fingerprints and digests*), excluding items waiting on a retry and items muted by a rule.
3. **Prioritize.** Items the user has acted on since their last decision go first, then by relationship urgency and recency.
4. **Analyze.** Batches of up to 15 items (90 KB cap) go to Copilot one at a time; the helper serves one request at a time. Valid decisions are saved as they arrive. Items Copilot skips are retried immediately once, then after 2 minutes.
5. **Wait** for the configured interval (2 min to hourly, or manual), ⌘R, or app activation if enabled. Interval changes apply live.

GitHub discovery never waits for Copilot. If Copilot is unavailable (consent off, signed out, runtime missing), analysis pauses and items stay pending instead of failing.

## Fingerprints and digests

A decision is current only when both match:

- **Item fingerprint:** SHA-256 of the item's facts (title, body, state, labels, reviews, checks, head commit, recent comments, relationships). Any change on GitHub re-queues the item.
- **Rules digest:** hash of the prompt version, enabled rules, instructions, and a re-analysis token. Changing instructions or rules, pressing **Re-analyze All**, or shipping a new prompt re-queues every item.

Stale items keep their previous decision and section while Copilot re-checks them, so the Inbox never flickers. They also appear in **Analyzing**.

## Rules

Hard rules are evaluated in `WorkspacePresentation`, not stored on decisions, so they apply instantly and are reversible. The first matching rule with a disposition effect wins (*Always Inbox* never downgrades *Needs Action*); priority adjustments accumulate (±25 each, clamped 0–100). *Mute* moves items to the Muted section and the engine never sends them to Copilot. Matching rules are also sent to Copilot as `rule_hints` so its wording agrees with the enforced outcome.

## Done, snooze, and handled detection

`LocalStatus.done` records when the item was marked done. Done work becomes visible again only when someone **other than the viewer** comments, reviews, or pushes after that time. The viewer's own follow-up never resurfaces it.

When an Inbox item with a next step has viewer activity since its decision, the engine sends Copilot the previous `next_action` and a plain list of what the viewer did. Copilot returns `handled: yes | partial | no` with one sentence of evidence. On `yes`, the store marks the item done with that evidence (unless the user already set a status), the UI labels it **Handled by You**, and **Move Back to Inbox** undoes it. This is controlled by *Settings ▸ Inbox ▸ Mark work done when you handle it*.

Done, Snooze, and Restore update the UI optimistically and save in the background.

## Prompting

Copilot receives four layers, highest precedence first:

1. **Fixed system policy** (in the Rust helper): role, untrusted-data handling, dispositions and priority bands, writing rules with good and bad examples, handled-check rules, and the JSON schema. It is not user-editable; this keeps output parseable, protects against instructions embedded in GitHub content, and lets improvements ship with updates. `TriageRules.promptVersion` is bumped when it changes materially.
2. **User preferences**: the organization's instructions, appended in a delimited `<user_preferences>` block that cannot change the format or policy.
3. **Per-item hints**: `rule_hints`, and for handled checks `previous_next_action` and `viewer_activity`.
4. **Untrusted data**: today's date, then the items as JSON.

Output is parsed leniently (Markdown fences tolerated, over-long text clamped, malformed decisions dropped individually) and then validated strictly on both sides of the XPC boundary. A partial response saves the valid decisions and retries the rest.

## Copilot boundary

`TriageCopilotXPC` launches the signed Rust `TriageCopilotHelper` with a verified, pinned Copilot runtime. The helper supports only `health`, `authenticate`, `models`, `triage`, `cancel`, and `shutdown`. It runs Copilot with all tools denied and no file, MCP, or extra network access. One authenticated session per account and organization is reused across batches and recreated if it expires. The Copilot sign-in is separate from the GitHub connection and stored in an account-private profile.

## Storage

Each GitHub account has its own SQLCipher database under `~/Library/Application Support/Triage/Vaults/<account>/`, keyed from the Keychain. A single schema reconciler (`TriageDatabaseMigrator`) rebuilds known tables from canonical DDL, drops unknown ones, and validates foreign keys before commit. Observed tables are rowid tables so SQLite's update hook, and therefore live UI updates, fire on every write.

## Observability

All logging uses `os.Logger` with subsystem `com.triage.mac` and categories `App`, `Engine`, `Discovery`, `Copilot`, `Store`, `API`, and `GitHub`. Item content is never logged.

```sh
log stream --predicate 'subsystem == "com.triage.mac" AND category != "API"'
```

Typical lines: `refresh outcome=success items=215 duration=41s`, `analysis started items=19 withYourActivity=2`, `batch outcome=decided items=15 duration=28s`, `handled-by-viewer items=2`.

## Distribution

A universal (`arm64` + `x86_64`) macOS 26 app with Hardened Runtime, Developer ID signing, notarization, and Sparkle EdDSA-verified updates. See [Releasing](RELEASING.md).
