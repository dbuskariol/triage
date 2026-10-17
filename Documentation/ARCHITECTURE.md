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
4. **Analyze.** Batches of up to 10 items (90 KB cap) go to Copilot one at a time; the helper serves one request at a time. Valid decisions are saved as they arrive. Items Copilot skips are retried immediately once. A batch that fails is split in half and retried immediately, down to single items, so one problem item never holds back the rest.
5. **Wait** for the configured interval (2 min to hourly, or manual), ⌘R, or app activation if enabled. Interval changes apply live. If any item failed, the engine also wakes when its retry is due (2 minutes) and re-analyzes without searching GitHub again.

GitHub discovery never waits for Copilot. If Copilot is unavailable (consent off, signed out, runtime missing), analysis pauses and items stay pending instead of failing.

## Fingerprints and digests

A decision is current only when both match:

- **Item fingerprint:** SHA-256 of the item's facts (title, body, state, labels, reviews, checks, head commit, recent comments, relationships). Any change on GitHub re-queues the item.
- **Rules digest:** hash of the prompt version, enabled rules, instructions, and a re-analysis token. Changing instructions or rules, pressing **Re-analyze All**, or shipping a new prompt re-queues every item.

Stale items keep their previous decision and section while Copilot re-checks them, so the Inbox never flickers. They also appear in **Analyzing**.

## Rules

Hard rules are evaluated in `WorkspacePresentation`, not stored on decisions, so they apply instantly and are reversible. The first matching rule with a disposition effect wins (*Always Inbox* never downgrades *Needs Action*); priority adjustments accumulate (±25 each, clamped 0–100). *Mute* moves items to the Muted section and the engine never sends them to Copilot. Matching rules are also sent to Copilot as `rule_hints` so its wording agrees with the enforced outcome.

## Workspace navigation

`WorkspaceDestination` is the sidebar selection: a list `Section`, a saved search, the Briefing, or the Weekly Review. Lists pair with the detail column in a resizable split; the Briefing and Review are full-width dashboards whose items open in their list (`show(_:)`). Destination changes are recorded for Back and Forward. `WorkspaceBriefing` and `WorkspaceReview` are pure values derived from the same `WorkspacePresentation` as the lists, and `WorkInsights` holds the shared derivations (references between items, waiting times, follow-ups, done dates, grouping). Saved searches are stored per organization in user defaults.

## Notifications

`AttentionTracker` (pure, persisted per organization) decides what is news: the first update only takes a baseline, an item is announced once when it first needs action, and again only if it leaves and returns. More than three at once become one summary. Follow-up reminders are at most daily, and quiet hours suppress delivery. `AttentionNotifier` posts local notifications and sets the Dock badge to the number of items needing action. Each notification carries an `AttentionTarget` (an item, the needs-action list, or the follow-up Briefing, plus its organization). The notifier is the notification center delegate from `applicationWillFinishLaunching`, so clicks that launch Triage are buffered; `TriageAppModel.open(_:)` switches organization and holds the target until the presentation that contains it is published.

## Done, snooze, and handled detection

**Snooze** choices are Later Today, Tomorrow, In 3 Days, Next Week (the next Monday, so a week away on a Monday), and In 7 Days; all but Later Today return at the user's morning hour.

`LocalStatus.done` records when the item was marked done. Done work becomes visible again only when someone **other than the viewer** comments, reviews, or pushes after that time. The viewer's own follow-up never resurfaces it.

When an Inbox item with a next step has viewer activity since its decision, the engine sends Copilot the previous `next_action` and a plain list of what the viewer did. Copilot returns `handled: yes | partial | no` with one sentence of evidence. On `yes`, the store marks the item done with that evidence (unless the user already set a status), the UI labels it **Handled by You**, and **Move Back to Inbox** undoes it. This is controlled by *Settings ▸ Inbox ▸ Mark work done when you handle it*.

**Columns.** Lists and details sit in `ListDetailSplitView`, an `NSSplitViewController` whose hosted panes have empty `sizingOptions`, so item content can never resize the columns; only fixed minimums and maximums apply. The divider position is saved with `autosaveName`, so it survives switching sections and relaunching. The window title is set outside the hosted panes.

**Selection** is a set (`TriageAppModel.selection`); `selectedEntryID` is the single selection when exactly one row is chosen. Bulk actions (`markDone`, `snooze`, `restore`, `setRead`, `openOnGitHub`) take arrays, with single-item conveniences in a protocol extension. `ListSelection` holds the shared rules for keyboard movement and for selecting the next row after items leave the list. The list's context menu is attached with `contextMenu(forSelectionType:)`, so it acts on the clicked rows or the selection they belong to.

**Read state** is stored per item in `triage_read_state`. An entry is unread when it has never been viewed or when someone other than the viewer acted after `readAt` (the same `latestActivity(excluding:)` rule that brings back done work). `WorkspacePresentation` sets `isUnread` for the viewer. The detail view marks an item read after the user's chosen delay, so lists and Focus behave the same. `OptimisticChanges` shows Done, Snooze, Restore, and read changes immediately until the store confirms them. The first time an organization's work loads, existing items start as read, so the dot means new rather than flagging the backlog.

`LocalStatus.hides(_:at:viewer:)` is the single rule for whether a status still applies. When it no longer does (someone else answered done work, a snooze elapsed), the presentation shows the item as active, and `markHandled` may replace it; a status that still applies is never overridden.

Done and Snoozed are separate sections: Done is newest first with a *Handled by You* / *Marked Done* filter; Snoozed is ordered by when items return. Done, Snooze, and Restore update the UI optimistically and save in the background.

## Prompting

Copilot receives four layers, highest precedence first:

1. **Fixed system policy** (in the Rust helper): role, untrusted-data handling, dispositions and priority bands, writing rules with good and bad examples, a `situation` sentence (what the item is, what's happened, and why it's in the user's notifications), handled-check rules, and the JSON schema. It is not user-editable; this keeps output parseable, protects against instructions embedded in GitHub content, and lets improvements ship with updates. `TriageRules.promptVersion` is bumped when it changes materially. The Inbox shows the why (`reason`) under the title, with the next step. The View menu's List Shows switches that to why only, or next step only. A `situation` sentence, when Copilot has one, stays above those lines.
2. **User preferences**: the organization's instructions, appended in a delimited `<user_preferences>` block that cannot change the format or policy.
3. **Per-item hints**: `rule_hints`, and for handled checks `previous_next_action` and `viewer_activity`.
4. **Untrusted data**: today's date, then the items as JSON.

Output is parsed leniently: fences, prose, and `{"decisions": [...]}` wrappers are tolerated; every complete decision is salvaged from a truncated or partly malformed reply; over-long text is clamped. Unreadable replies report only their shape (length and first character), never content. Parsed output is then validated strictly on both sides of the XPC boundary. A partial response saves the valid decisions and retries the rest.

**Draft Reply** uses a separate fixed prompt: write as the viewer, ground every statement in the item, never invent facts or commitments, and leave bracketed placeholders for details only the viewer knows. The item's next action is the goal, and the user's writing style (*Settings ▸ Copilot ▸ Draft Replies*) follows in a delimited `<writing_style>` block. Output is trimmed and unwrapped, limited to 8,000 bytes, and never posted.

## Copilot boundary

`TriageCopilotXPC` launches the signed Rust `TriageCopilotHelper` with a verified, pinned Copilot runtime. The helper supports only `health`, `authenticate`, `models`, `triage`, `draft`, `cancel`, and `shutdown`. Triage and drafts share one session runner in the helper. In the app, `CopilotHelperSession` owns one authenticated connection; the triage decider and the draft writer each have their own, so a draft never waits behind a triage batch. It runs Copilot with all tools denied and no file, MCP, or extra network access. One authenticated session per account and organization is reused across batches and recreated if it expires. The Copilot sign-in is separate from the GitHub connection and stored in an account-private profile.

**Caller validation.** The XPC service accepts only a caller whose running code matches the signed Triage bundle on disk. If Triage was replaced while running, the service rejects it (`callerRejected`), the service and client log the stable error code under category `CopilotXPC`, and the app shows a relaunch-required problem with a Quit button instead of retrying.

**Versions.** The helper uses the Rust `github-copilot-sdk` (pinned exactly, `runtime` feature only) and a pinned Copilot CLI release whose archive and executable SHA-256 digests are checked by both the app and the XPC service, along with GitHub's Developer ID signature. Updating the CLI means updating the version and all four digests in `CopilotRuntimeAcquisition.swift` and `CopilotHelperProcess.swift`, verified against the release's `SHA256SUMS.txt`. When an app update changes the pin, a previously installed runtime is upgraded automatically and superseded versions are deleted.

**Model options.** Each organization stores a model, reasoning effort, and context tier for prioritizing, and optionally a separate set for Draft Reply (otherwise drafts use the prioritizing choice). Settings offers only the efforts and tiers the selected model reports through the SDK, and the helper applies them to each session.

**Disk hygiene.** Every triage session is disconnected and deleted through the SDK after its batch. After each sign-in, sessions left by an interrupted run are listed and deleted through the SDK, the CLI runs at error-only log level, and only its five newest log files are kept.

## GitHub credentials

Every GitHub response says something about the credential that made it. `GitHubGraphQLClient` reports a `GitHubCredentialObservation`: *accepted*, with the expiration from GitHub's `GitHub-Authentication-Token-Expiration` header, or *rejected* on a 401. In production one task per workspace saves these in order through `GitHubCredentialHealthRecorder`, independently of the request that produced them, and streams the updated account to the app model. `CredentialLifecycle` holds the rules: a personal access token is *expiring* within seven days of its expiration and *expired* after it; a rejected token is *expired* if past its expiration and otherwise *revoked*. Connecting or replacing a token records its expiration from the `/user` response.

When GitHub rejects the token, the engine reports `gitHubCredentialRejected` and stops scheduling automatic refreshes (Refresh Now still tries). `GitHubCredentialNotice` turns the account and that problem into the workspace banner: a warning a week before a token expires, and a blocking notice with **Replace Token…** once it stops working. Settings ▸ Accounts replaces a personal access token in place (classic and fine-grained can replace each other), keeping the account's organizations, rules, and history; the workspace restarts with the new token.

## Storage

Each GitHub account has its own SQLCipher database under `~/Library/Application Support/Triage/Vaults/<account>/`, keyed from the Keychain. A single schema reconciler (`TriageDatabaseMigrator`) rebuilds known tables from canonical DDL, drops unknown ones, and validates foreign keys before commit. Observed tables are rowid tables so SQLite's update hook, and therefore live UI updates, fire on every write.

## Observability

All logging uses `os.Logger` with subsystem `com.triage.mac` and categories `App`, `Engine`, `Discovery`, `Copilot`, `Store`, `API`, `GitHub`, and `CopilotXPC`. Item content is never logged.

```sh
log stream --predicate 'subsystem == "com.triage.mac" AND category != "API"'
```

Typical lines: `refresh outcome=success items=215 duration=41s`, `analysis started items=19 withYourActivity=2`, `batch outcome=decided items=15 duration=28s`, `handled-by-viewer items=2`.

## UI-test fixture

`TriageUITests` launch Triage with `-triage-ui-fixture` and `TRIAGE_UI_TEST_MODE=1`. Only Debug builds contain `TriageUITestFixture` (`#if DEBUG`), and both values are required, so Release and notarized builds can never enter it. A fixture launch composes the app from local fake data: in-memory accounts and organizations, a static `PersonalWorkDiscovering`, a deterministic `TriageDeciding`, and the no-op Copilot provider. The production store, engine, and consent repository run unchanged against encrypted vaults in a temporary directory with a session-derived key. It never reads the Keychain, the user's vaults, GitHub, or the Copilot runtime, skips notifications and Sparkle, and keeps preferences in a per-session suite (`UserDefaults.triage`).

| Variable | Meaning |
| --- | --- |
| `TRIAGE_UI_TEST_SCENARIO` | `workspace` (default), `performance-workspace` (10,000 items), `onboarding`, `personal-access-token`, `personal-access-token-replacement`, `notification-route`, `account-recovery`, `refresh-failure` |
| `TRIAGE_UI_TEST_SESSION` | Names the preferences suite and vault directory; letters, digits, `-`, and `_` |
| `TRIAGE_UI_TEST_RESET` | `1` erases the session's preferences and vaults before launch; `0` keeps them to test relaunch |

## Distribution

A universal (`arm64` + `x86_64`) macOS 26 app with Hardened Runtime, Developer ID signing, notarization, and Sparkle EdDSA-verified updates. See [Releasing](RELEASING.md).
