# Triage development handoff

**Handoff state:** paused after the synchronization, deterministic-intelligence,
native-shell, and XPC hardening batches. This document is intentionally
specific enough to move the checkout to a different computer without relying
on the previous agent session.

**Authoritative product scope:** `Documentation/IMPLEMENTATION_PLAN.md`.
Do not treat this handoff as a replacement for that plan. The plan remains the
source of truth for supported features, non-goals, source authority, security
boundaries, sequencing, and acceptance criteria.

## Repository and transfer state

- Repository root: `/Users/dbuskariol/Projects/swift/triage`
- Primary branch at handoff: `main`
- Last commit before the paused batch: `b8f1a71 Report bounded review refresh coverage`
- This handoff is committed together with every completed, previously
  uncommitted implementation slice listed below.
- No remote push occurred before this handoff. The user subsequently requested
  creation of `dbuskariol/triage` and a push of the complete history.
- The product is **not complete**. The final acceptance walkthrough and the
  remaining work below are still mandatory.

The application is a Swift 6 native macOS 26 app. It uses SwiftUI, AppKit only
where Mac-specific behavior requires it, GRDB/SQLCipher for per-account
encrypted vaults, and Sparkle 2.9.4 for updates. It is local-first, read-only
toward GitHub, and must never add telemetry, diagnostics upload, hosted
content, local-repository scanning, or GitHub mutations.

## Validation at handoff

| Check | Result | Notes |
| --- | --- | --- |
| `swift build` | Passed | Consolidated SwiftPM app target built successfully after all active agents completed. |
| `git diff --check` | Passed | No whitespace errors before this handoff was added. |
| Focused implementation reviews | Passed after fixes | Review-thread pagination, team membership/ETag handling, timeline continuation/cancellation, Project field preservation/date parsing/budgeting, and Waiting wake-up behavior were independently reviewed and corrected. |
| `swift test` | Blocked by environment | The selected Command Line Tools developer directory does not provide the `XCTest` module. This is not a test success. |
| `scripts/verify-ci.sh` | Blocked by environment before build/tests | `xcodebuild` fails because `xcode-select` points to `/Library/Developer/CommandLineTools`, not a full Xcode installation. The verifier stops during `xcodebuild -showBuildSettings`. |
| Xcode tests/release build | Not run | Requires full Xcode selected with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` (or the actual installed full-Xcode path). |

The package manager emitted cache safety warnings while fetching Sparkle and
SQLCipher, but completed its app build. Do not “fix” that by changing
dependencies: use a normal checkout with the existing locked dependencies and
a correctly configured developer environment.

Before resuming implementation, use a full Xcode developer directory and run:

```sh
xcodebuild -version
scripts/verify-ci.sh
```

Then run focused XCTest selectors for every changed source slice before making
new changes. The implementation plan requires the full verifier again before
any candidate release work.

## Completed foundations before this batch

The following work was already committed before this handoff:

- Native macOS app foundation, XcodeGen project, Sparkle wiring, Settings
  shell, privacy/signing/release scripts: `4cdc353`.
- Complete product, architecture, source-authority, security, and acceptance
  plan: `df53bf0`.
- Per-account encrypted SQLCipher vaults; Keychain lifecycle; OAuth PKCE and
  broker; OAuth/PAT capability handling; read-only REST/GraphQL boundaries;
  rate limiting; search/notification/XPC foundations.
- Discovery search sharding with atomic page persistence and durable
  high-water advancement.
- GraphQL hydration of current issue/PR data with adaptive 25--50-node
  batching, raw provenance, parser-failure retention, and one-transaction
  normalized writes.
- Full REST review history pagination and requested-reviewer reconciliation,
  including raw page provenance. Recent commits: `bd16939`, `92380cd`,
  `24890db`, `c7be1b1`, `e9f705d`, `4a56421`, `dc7dfd7`, and `b8f1a71`.

Important existing invariants:

- GitHub REST permits only `GET` and `HEAD`; GraphQL permits committed named
  query documents and rejects mutations.
- Every account owns an isolated encrypted vault. Views must not receive GRDB
  handles.
- Use `AccountVault.writeTransaction` for a logical change that must commit or
  roll back as one unit.
- Preserve encrypted bounded raw snapshots with endpoint/query name, parser
  version, timestamp, and scoped object identity. Parser failures retain raw
  provenance and must not replace authoritative normalized state.
- Coverage is scoped by account, organization, repository where applicable,
  feature, stream, credential revision, and capability revision. Partial,
  unavailable, SSO, approval, offline, and failed states must never be shown
  as an empty or fresh inbox.

## Newly committed implementation batch

### Repository and team inventory

Key files:

- `Triage/GitHub/REST/GitHubRepositoryTeamClient.swift`
- `Triage/GitHub/Sync/OrganizationInventoryRefreshService.swift`
- `Triage/Database/Repositories/RepositoryInventoryRepository.swift`
- `Triage/Database/Repositories/TeamInventoryRepository.swift`
- `TriageTests/GitHub/GitHubRepositoryTeamClientTests.swift`
- `TriageTests/Database/InventoryRepositoryTests.swift`

This implements paginated authoritative repository and team inventory,
transactional reconciliation, raw REST provenance, rename-safe replacement,
repository access state, team membership observations, coverage records, root
conditional `If-None-Match` reuse, safe `304` preservation, and daily
unconditional reconciliation. A team-membership `404` is deliberately
**unknown**, not an authoritative “not a member”: prior membership remains and
team coverage is partial. Hidden membership must never be used to claim
complete team-mention resolution.

`OrganizationInventoryRefreshService.refreshRepositories(...)` remains
compatible with existing discovery code. `refreshInventory(...)` exposes
repositories, teams, membership visibility, and per-feature coverage for
future full workspace refresh integration.

### Pull-request review threads and comments

Key files:

- `Triage/GitHub/GraphQL/GitHubGraphQLQueries.swift`
- `Triage/GitHub/GraphQL/GitHubPullRequestReviewThreadClient.swift`
- `Triage/Database/Repositories/PullRequestReviewThreadRepository.swift`
- `TriageTests/GitHub/GitHubPullRequestReviewThreadClientTests.swift`
- `TriageTests/Database/PullRequestReviewReconciliationTests.swift`

Two new committed named GraphQL operations fetch review-thread metadata and
review-thread comments. Threads are paginated separately per pull request;
then every thread starts a distinct comments traversal at `after: nil`.
Neither comments nor unresolved-thread evidence is inferred from REST review
summaries. Traversals enforce cancellation, cursor loop protection, 100-page
caps, raw-payload retention, duplicate detection, payload validation, and
GraphQL cost limits.

`PullRequestReviewThreadRepository.replace(...)` validates the complete
inventory before pruning stale thread/comment nodes, saves actors and generic
node/comment records, writes `review_threads`, and updates
`pull_requests.unresolved_thread_count` in one transaction. “Requires current
user response” is true only when a thread is unresolved, not outdated, has a
known latest comment author, and that author is not the current user.

**Still required:** create a dedicated review-thread refresh service (or extend
the existing review refresh safely) and invoke it from the organization
orchestration. It must persist raw failure provenance, map GraphQL SSO/approval
errors to scoped review-thread coverage, and avoid publishing completion until
the bounded candidate inventory is drained.

### REST timeline synchronization

Key files:

- `Triage/GitHub/REST/GitHubRESTClient.swift`
- `Triage/GitHub/REST/GitHubTimelineClient.swift`
- `Triage/GitHub/Normalization/GitHubTimelineNormalizer.swift`
- `Triage/GitHub/Sync/GitHubTimelineRefreshService.swift`
- `Triage/Database/Repositories/TimelineCandidateRepository.swift`
- `Triage/Database/Repositories/TimelineEventRepository.swift`
- `TriageTests/GitHub/GitHubTimelineClientTests.swift`
- `TriageTests/GitHub/GitHubTimelineNormalizerTests.swift`
- `TriageTests/Database/TimelineEventRepositoryTests.swift`

`GitHubPage` and `GitHubResponse` now preserve the raw `Link` header in
addition to parsed pagination metadata. Timeline synchronization validates that
every Link target is the exact current repository/issue-or-pull-request
timeline endpoint, rejects malformed nonempty Link headers, supports
conditional requests and `304`, retains raw payloads, normalizes event kinds,
and keeps a durable downloaded/finalization phase in existing shard state.
Malformed or cross-scope pages cannot erase prior events or mark coverage
complete; corrected final pages can recover. Cancellation is checked after
network/persistence boundaries and before final completion publication.

**Still required:** call `GitHubTimelineRefreshService` from normal
organization synchronization, translate its results into `.timelines`
coverage, and ensure the stream’s durable cursor/high-water is selected with
the organization’s lifecycle scheduler.

### Discussions and Projects V2

Key files:

- `Triage/GitHub/GraphQL/GitHubGraphQLQueries.swift`
- `Triage/GitHub/GraphQL/GitHubDiscussionClient.swift`
- `Triage/GitHub/GraphQL/GitHubProjectV2Client.swift`
- `Triage/GitHub/Normalization/GitHubDiscussionNormalizer.swift`
- `Triage/GitHub/Normalization/GitHubProjectV2Normalizer.swift`
- `Triage/GitHub/Sync/DiscussionProjectV2Synchronization.swift`
- `Triage/Database/Repositories/DiscussionRepository.swift`
- `Triage/Database/Repositories/ProjectV2Repository.swift`
- `Triage/Database/TriageDatabaseMigrator.swift` migration `024`
- `TriageTests/GitHub/DiscussionProjectV2GraphQLTests.swift`
- `TriageTests/Database/DiscussionRepositoryTests.swift`
- `Documentation/GITHUB_FEATURE_CONTRACTS.md`

Committed named GraphQL operations and clients now provide authoritative
discussion inventory and Projects V2 inventory/items/field values. Cursor
traversals have loop/page limits plus aggregate 500-point and 4 MiB budgets
per collected inventory. Raw GraphQL provenance is retained. Project `Date`
values parse strictly as UTC `yyyy-MM-dd`. Partial errors, malformed values,
aggregate-budget failures, and incomplete field unions preserve prior
authoritative state and downgrade only the affected coverage.

Migration `024-project-v2-field-provenance` adds `value_kind` and `context` to
project field values and `content_node_reference` to project items. Never edit
an already published migration; append a new migration if more schema is
needed.

Discussion comments/replies intentionally remain `.unavailable` until their
own independently paginated source contract and implementation exist. This is
not an empty discussion-comment result.

**Still required:** wire `DiscussionSynchronizationService` and
`ProjectV2SynchronizationService` into the account/organization scheduler,
define candidate/repository/project selection and daily/incremental cadence,
and add independently paginated discussion-comment/reply synchronization.

### Deterministic derived intelligence

Key files:

- `Triage/Intelligence/DerivedIntelligenceCoordinator.swift`
- `Triage/Intelligence/Rules/InboxEligibilityRule.swift`
- `Triage/Database/Repositories/DerivedIntelligenceRepository.swift`
- `TriageTests/Intelligence/DerivedIntelligenceCoordinatorTests.swift`
- `TriageTests/Database/DerivedIntelligenceRepositoryTests.swift`

The coordinator derives deterministic rule evidence, ranking, Inbox
disposition, bounded FTS documents, menu counts, and coverage-aware AI
candidates/exclusions from Sendable domain inputs. It validates account and
organization scope and replaces stale derived evidence atomically through the
repository. Unknown/partial coverage excludes AI candidates rather than
turning incomplete work into an empty result.

Waiting wake-up evidence now makes an item effectively Inbox-eligible without
mutating the persisted local workflow state. Active snooze, archive, and
inaccessible precedence still win.

**Still required:** invoke `DerivedIntelligenceCoordinator.recompute(...)`
after each complete normalized synchronization write and before observation/UI
publication. Construct inputs from the repositories, persist the output using
`DerivedIntelligenceRepository`, and add migrations for durable
`rule_evaluations` and `ai_action_candidates` if their persistence is required
instead of the current output-only contract.

### Account/organization coordination

Key files:

- `Triage/GitHub/Sync/AccountOrganizationCoordinator.swift`
- `TriageTests/GitHub/AccountOrganizationCoordinatorTests.swift`

This new actor is intentionally dependency-injected. It supplies cache-first
activation, per-scope task ownership, cancellation, generation tokens to
discard stale completions, priority mapping, durable-state abstraction, and
account/organization scoped freshness/failure state.

**Still required:** provide production implementations of
`AccountOrganizationCachedStateStoring` and
`AccountOrganizationRefreshOperating`; inject the coordinator from the app
model/scene lifecycle; make its refresh operation call the fully integrated
organization refresh pipeline; and expose its state through database
observations to the UI.

### Native shell and onboarding

Key files:

- `Triage/Views/Coordinator/WorkspacePresentationState.swift`
- `Triage/Views/WorkspaceSidebar.swift`
- `Triage/Views/OnboardingFlowView.swift`
- `Triage/Views/RootView.swift`
- `Triage/Views/MenuBarView.swift`
- `Triage/Views/SettingsView.swift`
- `TriageTests/Views/WorkspacePresentationStateTests.swift`
- `TriageTests/Views/OnboardingPresentationStateTests.swift`

The native shell now has account/organization pickers, selectable Inbox/My
Work/Reviews/Waiting/Snoozed/All Work sidebar rows, muted counts, local
cached/fresh/partial/SSO/approval/offline presentation, a no-account state,
and menu-bar routing. The first-run flow is presentation-only and uses typed
closures for OAuth, advanced PAT submission, identity confirmation,
organization choice, SSO/approval recovery, initial sync, workflow
explanation, notification settings, and AI consent/unavailability.

The UI does not authenticate, persist secrets, or claim a non-existent Copilot
runtime. To make it functional, inject actual app-model/coordinator actions
and state observations. The pending `ui-*` work still includes commands,
toolbar/history, detail, inspector, workflow commands, secure Markdown,
notifications, restoration, complete Settings, accessibility/appearance, and
UI automation.

### Copilot XPC hardening

Key files:

- `Triage/CopilotXPC/CopilotHelperClient.swift`
- `Triage/CopilotXPC/CopilotXPCServiceClient.swift`
- `TriageCopilotXPC/CopilotHelperProcess.swift`
- `TriageCopilotXPC/CopilotXPCCallerValidator.swift`
- `TriageCopilotXPC/TriageCopilotXPCListener.swift`
- `TriageCopilotXPC/TriageCopilotXPCService.swift`
- `TriageTests/CopilotXPC/CopilotHelperClientTests.swift`

The existing fail-closed XPC foundation now has cancellation-safe
continuations, single-flight supervision, hard deadlines, transport cleanup,
process reaping, stderr suppression, tighter same-team signature validation,
and deterministic regressions for malformed response, cancellation, explicit
cancel, timeout, and shutdown.

The Copilot runtime remains unavailable by product contract. Do not weaken this
to use an ambient CLI, download a runtime, or accept unsigned artifacts. The
`copilot-runtime` todo is blocked pending an approved redistributable official
artifact and release signing identity.

## Immediate integration order

Do not mark the next large batch complete merely because the isolated source
clients compile. The following integration order preserves data authority:

1. Install/select full Xcode, run the verifier, and run all focused tests.
   Resolve any compile/test failure before additional implementation.
2. Inspect the single handoff commit with `git show --stat` and keep its
   source contracts, tests, and migration together.
3. Extend `OrganizationWorkRefreshService` (or replace it through the new
   `AccountOrganizationCoordinator`) deliberately. Its current flow is:
   repository refresh, role discovery, GraphQL hydration, and REST review
   summary/request refresh. Add streams as individually scoped operations:
   inventory/team, review threads, timelines, discussions, and Projects V2.
   Each must produce its own coverage record; one stream failure cannot
   falsely downgrade discovery or erase another stream’s normalized state.
4. Run derived intelligence only after the relevant normalized transaction is
   fully durable, then publish cache/observations. Do not run it from a view.
5. Implement storage observation streams and production coordinator adapters,
   then inject them into `TriageAppModel` and the existing SwiftUI shell.
6. Finish source-specific gaps: review-thread scheduling/coverage; discussion
   comments/replies; Project cadence and redacted/draft item handling;
   timeline/review/notification integration; and work-graph reconciliation.
7. Resume the remaining todo graph and acceptance plan in dependency order.

## Remaining todo graph

At pause, 60 of 116 tracked todos were done; 15 were active and 40 pending,
with the Copilot runtime blocked. The active rows describe partially completed
or unintegrated tracks and should not be bulk-marked done:

| Active track | Handoff status |
| --- | --- |
| `copilot-xpc` | Hardened in this commit; the approved runtime, SDK integration, entitlement and policy work remain. |
| `storage-repositories` | Many repositories exist; complete coverage, observation, deletion/recovery, and persistence tests remain. |
| `sync-account-org` | Coordinator actor exists; production adapters and app injection remain. |
| `sync-derived-intelligence` | Coordinator/repository exists; source integration and durable evaluation/candidate schema remain. |
| `sync-hydration` / `sync-normalization` | Core hydration exists; connect new streams, relations/tombstones, and complete end-to-end tests. |
| `sync-repositories-teams` | Inventory exists; scheduler/coordinator integration and live validation remain. |
| `sync-reviews` | REST reviews/requests and thread client/repository exist; thread refresh scheduling, newer-commit comparison, coverage, and derived input wiring remain. |
| `sync-search-discovery` / `sync-search-sharding` | Foundation exists; finish all role coverage, durable reconciliation, and integrated test matrix. |
| `ui-app-coordinator`, `ui-onboarding`, `ui-sidebar`, `ui-menu-bar` | Presentation shells exist; bind them to production observation/action services and finish UX validation. |
| `ui-commands` | Still outstanding. |

All currently pending work remains required. In practical dependency order:

1. `sync-freshness`, `storage-observation`, `sync-relations`, and
   `sync-scheduler`.
2. Finish `sync-timelines`, `sync-discussions`, `sync-projects`,
   `sync-notifications`, and `sync-tests` from the newly added isolated
   source layers.
3. Implement functional app coordination, workflow actions, detail/inspector,
   toolbar/commands/search, secure Markdown, notifications, restoration,
   Settings, accessibility, and UI tests.
4. Implement storage deletion/recovery and complete encrypted persistence
   tests.
5. Keep every Copilot task pending/blocked until the approved runtime is
   supplied; then implement consent, authentication, candidate selection,
   strict output validation, cache/corrections, auto-entry validation,
   sandboxing, and security tests.
6. Complete documentation, fixture corpus, controlled live GitHub scenarios,
   performance budgets, security audit, universal release packaging, final
   review, and the final acceptance walkthrough.

## Safety and release reminders

- Do not tag, publish, notarize, finalize a release, rotate credentials, or
  enable release automation without explicit user approval.
- `scripts/release.sh prepare` is a non-publishing rehearsal.
  `scripts/release.sh finalize` contacts Apple and requires the exact clean
  `v<version>` tag.
- Keep generated Xcode/SwiftPM products and DerivedData outside the repository.
- Never add credentials, vault keys, signing identities, certificates,
  notarization credentials, or private GitHub fixture data to the repository.
- Do not turn unavailable, unknown, partial, SSO-restricted, approval-blocked,
  or failed coverage into an empty list, a complete list, or a fresh timestamp.
- Do not change committed migration checksums or edit a migration that might
  already have been applied. Append a migration.
- The current plan still requires full Xcode tests, live controlled GitHub
  validation, UI accessibility exercise, security/release review, and all
  final acceptance steps. None are implied by the successful SwiftPM build.
