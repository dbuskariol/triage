# Triage development handoff

**Handoff state:** the original paused synchronization,
deterministic-intelligence, native-shell, and XPC checkpoint has now been
continued on a full-Xcode Mac. The latest verified implementation checkpoint
is `e320532` (`Bind discussions and projects to immutable source authority`)
on `main`; this handoff update is committed immediately after it. Triage
remains intentionally incomplete. This document records both the original
checkpoint and the current continuation state so another session does not
need prior context.

**Authoritative product scope:** `Documentation/IMPLEMENTATION_PLAN.md`.
Do not treat this handoff as a replacement for that plan. The plan remains the
source of truth for supported features, non-goals, source authority, security
boundaries, sequencing, and acceptance criteria.

## Repository and transfer state

- Original repository root: `/Users/dbuskariol/Projects/swift/triage`
- Current continuation root: `/Users/nftdannyboy/Documents/Projects/swift/triage`
- Primary branch: `main`
- Original handoff commit: `4584275` (`Add synchronization and handoff batch`)
- Latest verified implementation checkpoint: `e320532`
- This handoff is committed together with every completed, previously
  uncommitted implementation slice listed below.
- The configured remote is `https://github.com/dbuskariol/triage`. No push,
  tag, publication, notarization, release finalization, or release-automation
  change was performed during this continuation.
- The product is **not complete**. The final acceptance walkthrough and the
  remaining work below are still mandatory.

The application is a Swift 6 native macOS 26 app. It uses SwiftUI, AppKit only
where Mac-specific behavior requires it, GRDB/SQLCipher for per-account
encrypted vaults, and Sparkle 2.9.4 for updates. It is local-first, read-only
toward GitHub, and must never add telemetry, diagnostics upload, hosted
content, local-repository scanning, or GitHub mutations.

## Validation at current continuation checkpoint

| Check | Result | Notes |
| --- | --- | --- |
| Full developer directory | Passed | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; Xcode 27.0, build `27A5228h`. |
| Focused handoff and continuation XCTest | Passed | Coordinator, lifecycle/runtime, source integration, conditional authority, timeline replay, role-search replay, migration, cancellation, rollback, and malformed-payload selectors passed. |
| 2026-08-31 source-authority checkpoint | Passed | Fresh combined full-Xcode run passed 132/132: discussion/project, timeline, relation, migrations, review scheduling/reconciliation, and the inventory crash regression. Result: `/tmp/TriageSafeCheckpoint-r2-20260831.xcresult`. |
| Focused checkpoint slices | Passed | Timeline 32/32 (`/tmp/TriageTimelineCheckpoint-r4-20260831.xcresult`); review/thread 22/22 (`/tmp/TriageThreadCheckpoint-r4-20260831.xcresult`); relation 19/19; discussion failure provenance 3/3 (`/tmp/TriageDiscussionFailure-r7-20260831.xcresult`). |
| Historical coordinator crash regression | Passed | `AccountOrganizationCoordinatorTests/testAccessFailureRemainsScopedToItsAccountOrganization` passed 100/100 repetitions; current bounded/index-checked helper already contained the fix. |
| Consolidated role-search gate | Passed | `AccountVaultTests`, `RoleSearchPageReplayRepositoryTests`, `GitHubIssueSearchTests`, `SearchShardExecutorTests`, and `RoleDiscoveryPlanTests` passed together after the final parser-authority bump. |
| Independent final reviews | Passed | Security/source-authority and transaction/data-integrity re-audits reported no concrete defects after all fixes. |
| `git diff --check` | Passed | No whitespace errors through the `e320532` implementation checkpoint or this handoff edit. |
| `scripts/verify-ci.sh` | Passed | Full XCTest suite and unsigned universal arm64/x86_64 Release build passed after `7aba74f`; only known vendored GRDB Swift 6 `Any`/`Sendable` warnings remained. |

The full verifier has not been repeated after `e320532`; the fresh 132-test
checkpoint above is the current proof. Repeat `scripts/verify-ci.sh` before
starting the next broad integration wave or treating the checkout as a full
CI checkpoint.

The earlier Command Line Tools limitation is resolved on the current machine.
Keep using the locked Sparkle, GRDB, and SQLCipher dependencies; do not change
them to suppress package-manager or vendored Swift 6 warnings.

Before resuming implementation, use a full Xcode developer directory and run:

```sh
xcodebuild -version
scripts/verify-ci.sh
```

Then run focused XCTest selectors for every changed source slice before making
new changes. The baseline full verifier was completed through `7aba74f`, and
focused source-authority coverage was repeated through `e320532`; repeat the
full verifier before the next broad integration wave. The implementation plan
requires it again before any candidate release work.

## Continuation commits after `4584275`

The continuation preserved the original integration order and committed each
verified slice locally. In dependency order, the new commits are:

- organization pipeline, hydration coverage, and source-scoped role
  discovery: `1e6b76d`, `4ebf9fd`, `f5ff363`;
- malformed search provenance and durable conditional role-search replay:
  `e4445b5`, `82cc7f0`, `cdb5c14`;
- durable scheduler, ownership, revision-safe runtime, and atomic projection
  integration: `f4a3f89`, `df65d00`, `c90cd30`, `fc0428d`, `e139b81`,
  `a4c61dd`;
- hardened Discussion/Projects contracts and organization integration:
  `ad4654e`, `da7e1bc`;
- authoritative coverage profiles and access-loss topology preservation:
  `10885fe`, `8c776d1`;
- source-authority conditional validation and raw request identity:
  `e2813da`, `77a5627`, `204b522`;
- timeline raw-page authority and replay receipts: `24e2e68`, `4c6ebc0`;
- stream-scoped role-search replay authorization, encrypted destructive
  migration backups, append-only parser-identity migration `034`, and
  malformed-page failed coverage: `7aba74f`.

Subsequent local continuation commits, also on `main`, are:

- continuation handoff and conservative inventory authority: `4811423`,
  `b48ea7f`, `dc1a53b`, `a7ded33`, `ac7bec2`, `59ea12c`, `26b99ac`,
  `235b147`, `4a11d1c`, `bc23e13`, `ee647a9`, `6885173`, `3546b96`,
  and `5217b01`;
- source-scoped relation evidence and deletion fail-closed behavior:
  `0d42fa7`, `64b15b1`;
- exact fair review scheduling, blocked-known candidate coverage, and
  conservative no-cursor-advance failure behavior: `e7396b2`;
- append-only migration `039`, exact staged/current timeline page membership,
  atomic publication, immutable raw history, and page-bound relation
  replacement: `3ae4072`;
- immutable discussion/Project raw authority, canonical traversal checks,
  partial Project field retention, and exact normalization-failure source
  binding: `e320532`.

The crash reports supplied during this checkpoint both describe the same old
`OrganizationInventoryRefreshService.validateCurrentScope` GRDB row-subscript
trap from `testEmptyThenNonemptyRepositoryRevisionAtSameMillisecondFailsClosed`.
Commit `5217b01` replaced that unchecked decoding path; the exact regression
test is included in the 132/132 green checkpoint.

The role-search batch authorizes `304` reuse only for exact account,
organization, leaf stream, endpoint/query/page, credential revision,
capability revision, parser version, validator pair, and raw request authority.
Parser authority is version 2; migration-033 version-1 bindings are retained as
encrypted evidence but retired before lookup. Control pages do not create
replay bindings. Any item normalization failure commits raw evidence,
diagnostics, valid normalized items, replay invalidation, and a failed shard in
one transaction before propagating failure. Destructive migrations 033 and 034
now require verified encrypted SQLCipher backups; interrupted migration tests
prove the prior vault remains readable.

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

`PullRequestReviewThreadRefreshService` is now invoked from organization work
refresh with durable fair candidate scheduling, scoped blocked/inaccessible
signals, redacted GraphQL SSO/approval classification, and conservative
coverage. **Still required:** persist durable raw/classified failure provenance
for failed candidate traversals. Until that exists, remote/SSO/approval failure
stops the pass without advancing its durable cursor, so retry selects the same
candidate. Newer-commit comparison and final derived-input wiring also remain.

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

`GitHubTimelineRefreshService` is now called from normal organization work
synchronization and its repository and aggregate assessments are translated to
`.timelines` coverage. Migration `039` publishes exact current raw-page
membership atomically from staged traversal state; a 2-page to 1-page shrink
does not retain stale membership, while immutable raw history remains bounded
and protected when authoritative. **Still required:** finish the integrated
cadence/live matrix, remaining source-specific tombstone behavior, and final
coordinator/derived-observation acceptance.

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

`OrganizationContextRefreshService` now invokes
`DiscussionSynchronizationService` and `ProjectV2SynchronizationService`, and
organization work refresh invokes that context service. Raw pages are
immutable and exact-scope bound; traversal is canonical; partial Project field
collections retain prior authoritative values plus explicit provisional
context. **Still required:** finish candidate/project cadence and redacted or
draft item behavior, add independently paginated discussion-comment/reply
synchronization, and complete production coordinator/derived-observation
acceptance.

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

Do not mark the next large batch complete merely because its isolated clients
or repositories compile. Full Xcode restoration, focused handoff coverage,
exact organization scope propagation, fair review scheduling, timeline page
membership, source-scoped relation evidence, and the current discussion/
Project authority hardening are complete through `e320532`. The next
integration order preserves data authority:

1. Add durable raw/classified accumulated failure provenance for REST reviews
   and GraphQL review threads before allowing any failed candidate cursor to
   advance. The current implementation deliberately stops at the first
   unproven remote/SSO/approval failure and retries the same candidate.
2. Finish source-specific normalized inputs without crossing coverage scopes:
   discussion comments/replies; remaining Project cadence and redacted/draft
   item behavior; newer-commit review comparison; notification reconciliation;
   and authoritative source-specific tombstones. Each stream keeps independent
   coverage and failure authority.
3. Wire the now-hardened source streams into the production organization
   coordinator in dependency order. Preserve staged/download state, validate
   scope after every suspension, and publish coverage only with its normalized
   transaction. Do not introduce placeholder or hidden fallback services.
4. Run deterministic derived intelligence only after the relevant normalized
   transaction is fully durable. Persist revision-bound evaluation/candidate
   evidence and carry freshness, coverage, confidence, and provisional state;
   never run derivation from a view.
5. Implement storage observation streams and production coordinator adapters,
   then inject those explicit dependencies into `TriageAppModel`. Do not add
   placeholder or hidden fallback services.
6. Bind the existing native SwiftUI shell to production observations and
   actions, then finish commands, detail/inspector, toolbar/search, secure
   Markdown, notifications, restoration, Settings, accessibility, appearance,
   keyboard, resizing, and UI automation.
7. Complete deletion/recovery, encrypted persistence, fixture, end-to-end,
   performance, controlled live GitHub, and security validation in dependency
   order. Keep Copilot fail-closed until its approved runtime and signing
   prerequisites exist.
8. Re-run focused tests after every slice and `scripts/verify-ci.sh` at each
   integration checkpoint. Commit coherent local slices, but do not push or
   perform release operations without explicit approval.

## Remaining todo graph

At the original pause, 60 of 116 tracked todos were done, 15 were active, and
40 were pending, with the Copilot runtime blocked. The continuation completed
multiple prerequisites without bulk-closing these broader tracks. The rows
below describe their current residual work:

| Active track | Handoff status |
| --- | --- |
| `copilot-xpc` | Transport is hardened and remains fail-closed; the approved runtime, SDK integration, entitlement, consent, signing, and policy work remain blocked on external prerequisites. |
| `storage-repositories` | Exact request authority, coverage profiles, encrypted migration backups, source-scoped relation evidence, immutable raw rows, and exact timeline membership are durable; observations, deletion/recovery, and complete persistence tests remain. |
| `sync-account-org` | Revision-safe single-owner coordination, durable scheduling, scoped operations, projections, and lifecycle integration exist; production presentation adapters/injection and remaining stream actions remain. |
| `sync-derived-intelligence` | Coordinator/repository foundations exist; revision-bound source integration and durable evaluation/candidate evidence remain. |
| `sync-hydration` / `sync-normalization` | Core hydration plus selected timeline, Discussion, Project, inventory, and search streams are integrated; relation evidence is raw-bound and source-scoped; authoritative tombstones, remaining normalization, and end-to-end tests remain. |
| `sync-repositories-teams` | Inventory participates in organization refresh and preserves topology across access loss; authoritative deletion reconciliation and controlled live validation remain. |
| `sync-reviews` | REST reviews/requests and thread refresh use durable fair scheduling with explicit blocked-known candidates. Durable raw failure envelopes, newer-commit comparison, final complete-coverage publication, and derived-input wiring remain. |
| `sync-search-discovery` / `sync-search-sharding` | Search has source-scoped plans, malformed provenance, exact conditional replay, parser authority, cancellation, and migration coverage; finish durable cross-stream reconciliation and the integrated/live matrix. |
| `ui-app-coordinator`, `ui-onboarding`, `ui-sidebar`, `ui-menu-bar` | Presentation shells exist; bind them to production observation/action services and finish functional and UX validation. |
| `ui-commands` | Still outstanding. |

All currently pending work remains required. In practical dependency order:

1. Add review/review-thread accumulated failure provenance, then finish the
   residual `sync-discussions`, `sync-projects`, `sync-reviews`,
   `sync-notifications`, authoritative tombstones, and `sync-tests` gaps
   without merging their coverage authority.
2. Wire the completed source streams into production organization coordination,
   then complete `sync-freshness`, derived intelligence, and
   `storage-observation` on the durable scheduler/coordinator foundation.
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
- Full Xcode tests and the unsigned universal build passed through `7aba74f`;
  a focused 132-test full-Xcode checkpoint passed through `e320532`, but the
  subsequent changes still require a full verifier rerun. Live
  controlled GitHub validation, UI accessibility exercise, security/release
  review, signing/notarization, and all final acceptance steps remain open and
  are not implied by the current green checkpoint.
