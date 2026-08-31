# Triage development handoff

**Handoff state:** the current committed source checkpoint preceding this
documentation update is `134f51a` (`Separate host plugin deployment settings`)
on `main`. It includes the production acceptance slice committed as `cc46e7e`,
the final full-suite fixture repairs through `3105e3f`, and the macOS 27
universal Rust-helper build corrections through `134f51a`. Only this
documentation update remains in the active worktree.

`0f80baf` remains the historical local-integration checkpoint, with focused
evidence through the later committed Settings work noted below. Historical
results are retained for traceability only; they do not validate the current
tree. Triage is **not** globally complete: the linked-development/“work
underway” source contract is still undefined, UI XCTest still cannot enter
automation mode on this host, OAuth deployment values and controlled live GitHub access are
absent, acquired-runtime Copilot acceptance has not been run, and notarization
and release operations remain external or explicitly authorized work. A local
universal Developer ID-signed Release build has been installed for inspection;
it is not a notarized or published release. This document records the exact
remaining gates.

**Authoritative product scope:** `Documentation/IMPLEMENTATION_PLAN.md`.
Do not treat this handoff as a replacement for that plan. The plan remains the
source of truth for supported features, non-goals, source authority, security
boundaries, sequencing, and acceptance criteria.

## Repository and transfer state

- Original repository root: `/Users/dbuskariol/Projects/swift/triage`
- Current continuation root: `/Users/nftdannyboy/Documents/Projects/swift/triage`
- Primary branch: `main`
- Original handoff commit: `4584275` (`Add synchronization and handoff batch`)
- Production integration commit: `9d9a566`
- Source checkpoint preceding this documentation update: `main` at `134f51a`
- Historical local-acceptance checkpoint: `0f80baf`; later historical Settings
  evidence is recorded through `a77fa56`, not as evidence for the active tree.
- The configured remote is `https://github.com/dbuskariol/triage`. No push,
  tag, publication, notarization, release finalization, or release-automation
  change was performed during this continuation.
- The product is **not globally complete**. The externally dependent acceptance
  and release work below remains mandatory.

The application is a Swift 6 native macOS 26 app. It uses SwiftUI, AppKit only
where Mac-specific behavior requires it, GRDB/SQLCipher for per-account
encrypted vaults, and Sparkle 2.9.4 for updates. It is local-first, read-only
toward GitHub, and must never add telemetry, diagnostics upload, hosted
content, local-repository scanning, or GitHub mutations.

## Historical validation evidence (not current-worktree validation)

| Check | Result | Notes |
| --- | --- | --- |
| Coordinator/lifecycle acceptance | Passed | 42/42: production lifecycle, completion, account/organization coordinator, and end-to-end acceptance selectors. |
| REST review failure provenance | Passed | 37/37, including bodyless `403`/`404` classification in the deliberately narrow source-bound grammar. |
| Review thread synchronization | Passed | 56/56 focused thread/reconciliation tests. |
| Discussion and comment synchronization | Passed | 48/48 focused discussion/comment tests. |
| Observation and AppModel injection | Passed | 11/11 focused observation/injection tests. |
| Security and accessibility | Passed | 143/143 focused security/accessibility coverage. |
| Historical acceptance regression set | Passed | 180/180 from the freshly regenerated canonical bundle, including cache revision fencing, background/wake scheduling, derived batching/cancellation, notifications, native workflow/navigation, accessibility, and encrypted migration fixtures. |
| Review authority/failure regression set | Passed | 36/36: semantic REST raw binding, accumulated and zero-body classified failures, corroboration, and atomic reconciliation. |
| Final convergence selectors | Passed | 192/192 across identity replay, daily identity refresh, inventory, GraphQL/Projects V2, review receipts, derived inputs, workspace state/accessibility, work-list selection, and account persistence. |
| Native Settings layout selector | Passed | 10/10 `AppNavigationModelTests`, including the explicit Settings sidebar width/alignment contract. |
| Full unit and fail-closed XPC suite | Passed | 997/997, zero failures or skips, from `/tmp/triage-residual-full.xcresult`. |
| Canonical verifier deterministic phase | Passed | 998 deterministic tests passed with zero skips in `/tmp/triage-verify-final.xcresult`; its only reported failure is the pre-test UI-runner bootstrap below. |
| Native Settings runtime geometry | Passed | Live Accessibility and Computer Use inspection on macOS 27 proves one unified full-size titlebar; the system sidebar control sits beside the traffic lights, the first sidebar label is optically aligned with the detail heading, and the sidebar defaults wide enough for every section label. PAT presentation was also inspected without an inherited pre-submission OAuth configuration error. |
| Unsigned universal Release build | Passed | Post-Settings-fix `Triage` and `TriageCopilotXPC` both contain `x86_64 arm64`; app, XPC, and privacy plists pass `plutil`; bundle identifier/version/build/minimum OS are `com.triage.mac` / `0.1.0` / `1` / `26.0`. |
| Historical `git diff --check` | Passed | No whitespace errors at that historical documentation update. |
| Final `scripts/verify-ci.sh` | Environment-blocked | The ad-hoc canonical runner could not load `TriageUITests.xctest` because the sandboxed runner and mapped bundle were treated as different Team IDs. An isolated Apple Development-signed retry cleared that error but hung before XCTest bootstrap in `libsecinit` waiting on its sandbox XPC reply. No UI test method ran and no overall verifier-green claim is made. |

Focused evidence proves the committed local slices only. It does not replace
the blocked UI runner, controlled live GitHub, Copilot, signing, notarization,
or release acceptance.

The earlier Command Line Tools limitation is resolved on the current machine.
Keep using the locked Sparkle, GRDB, and SQLCipher dependencies; do not change
them to suppress package-manager or vendored Swift 6 warnings.

Before resuming implementation, use a full Xcode developer directory and run:

```sh
xcodebuild -version
scripts/verify-ci.sh
```

Then run focused XCTest selectors for every changed source slice before making
new changes. The implementation plan requires a passed full verifier again
before any candidate release work.

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
- production refresh intelligence, observations/AppModel injection, native
  workspace actions and secure navigation: `9d9a566`;
- deterministic account-scope lifecycle dispatch ordering: `8010305`;
- final local acceptance closure, production notification/Settings wiring,
  revision fencing, read-side authority hardening, migration `045` evidence,
  encrypted fixture/tamper coverage, privacy disclosure, and inspector/timeline
  authority: `6c8fd42`.
- exact-scope cache rotation, process-alive background and forced wake refresh,
  semantic REST review authority/failure provenance, requested-reviewer
  corroboration, derived provisional/batching/cancellation hardening,
  notification-vault lifecycle, accessibility injection, follow-up dates,
  scope-safe navigation history, and native workspace completion: `d61c378`.
- production selected-organization metadata replay, credential-replacement and
  daily active-account identity refresh, migration `046` identity receipts,
  exact `/user/orgs` and `/orgs/{org}` conditional authority, GraphQL
  connection-cardinality closure, REST team `304` retry, review traversal
  bounds, stable work-list multi-selection, PAT/OAuth error isolation, and
  adversarial fixtures: `40a835a`.
- native Settings `NavigationSplitView`, wider non-truncating sidebar, unified
  full-size titlebar, system sidebar-toggle placement, exact sidebar/detail
  vertical alignment, and focused layout coverage: `a77fa56`.

### Historical local acceptance validation wave

The historical local corrections were committed through `a77fa56`. The canonical
Debug bundle compiled, focused convergence selectors passed 192/192, the
Settings selector passed 10/10, the independent full unit/XPC suite passed
997/997, and the latest canonical verifier passed 998 deterministic tests
before its UI runner failed to bootstrap. The post-fix unsigned universal
Release bundle passed architecture/privacy/bundle inspection. These results do
not validate later commits, the active worktree, UI-runner, live GitHub,
Copilot, Developer ID signing, notarization, or release acceptance.

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

`PullRequestReviewThreadRefreshService` is invoked from organization work
refresh with durable fair candidate scheduling, scoped blocked/inaccessible
signals, redacted GraphQL SSO/approval classification, durable raw/classified
failure provenance, and conservative coverage. A failed traversal cannot
advance its candidate cursor. REST review failure provenance uses the same
source-bound authority: bodyless `403` and `404` are classified only by the
narrow endpoint/status grammar, never broadened into unrelated absence or
access conclusions. Review and thread failure isolation is preserved through
normalization, persistence, and publication.

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
and protected when authoritative. Integrated cadence, source-specific
tombstone behavior, coordinator reachability, derived projection, and
observation publication are complete locally; controlled live validation
remains in the residual order below.

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

Discussion comments and replies now use their independently paginated source
contract; unavailable/partial/error states remain explicit and never become an
empty comment result. `OrganizationContextRefreshService` invokes discussion,
comment, Projects V2 inventory/item, and notification synchronization through
the organization work path. Raw pages are immutable and exact-scope bound;
traversal is canonical; partial Project field collections retain prior
authoritative values plus explicit provisional context. Each source keeps its
own cadence, coverage, cancellation, and failure authority.

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

`OrganizationDerivedIntelligenceProjectionService` now runs after the complete
normalized source transaction is durable and before the corresponding
observation publication. It revalidates account/organization revision before
and after every suspension, snapshots adapters, recomputes through
`DerivedIntelligenceCoordinator`, and replaces the derived repository output.
Cancellation, stale scope/revision, and failures fail closed; callers receive
explicit published, partial, or failed outcomes rather than a hidden fallback.

### Account/organization coordination

Key files:

- `Triage/GitHub/Sync/AccountOrganizationCoordinator.swift`
- `TriageTests/GitHub/AccountOrganizationCoordinatorTests.swift`

This new actor is intentionally dependency-injected. It supplies cache-first
activation, per-scope task ownership, cancellation, generation tokens to
discard stale completions, priority mapping, durable-state abstraction, and
account/organization scoped freshness/failure state.

Production composition now supplies the durable cache/refresh adapters and
retains `OrganizationRefreshLifecycleService`. Launch, scene activation,
system wake, opportunistic background opportunity, and shutdown route through
the explicit lifecycle dependency into `AccountOrganizationRefreshRuntime` and
the coordinator. Scope enumeration is deterministic and fail-closed; runtime
generation, single-flight ownership, cancellation, and post-await scope checks
prevent stale work from publishing. AppModel receives explicit observation and
lifecycle dependencies rather than constructing a hidden fallback.

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

At the historical checkpoint, the workspace was connected to production
observations and actions, native commands, secure scoped navigation,
workflow/detail/inspector surfaces, toolbar/search, notification presentation,
restoration, and Settings. It did not authenticate, persist secrets, or claim a
non-existent Copilot runtime. That historical checkpoint predates the current
explicit-acquisition boundary. Current accessibility, encrypted-fixture,
deletion/recovery, and performance additions are recorded in the current graph
below together with their exact local evidence and remaining external gates.

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

The earlier statement that the Copilot runtime was unavailable pending an
artifact/signing decision is superseded by the current explicit-acquisition
contract. The runtime is absent by default and may only be downloaded after
explicit user action from the pinned GitHub release through the bounded
GitHub-to-release-assets redirect. It must retain its GitHub Developer ID
signature and pass archive, executable, architecture, and signature validation
before descriptor-safe installation in app-owned Application Support. Do not
weaken this to use an ambient CLI, re-sign a vendor runtime, accept unsigned
artifacts, or bypass entitlement, consent, and authenticated account binding.

## Current implementation and acceptance graph

This section is authoritative for the current checkout. Implemented source is
not a claim that external or release acceptance has occurred.

| Graph node | Current state | Remaining closure |
| --- | --- | --- |
| Product integration | Organization refresh/coordinator flow, revision-fenced GitHub streams, encrypted observations, derived intelligence, ranking, workflow actions, notification delivery, recovery/deletion, and native workspace/Settings injection are committed through `134f51a`. | Controlled live GitHub authority testing remains external; local tests cannot prove SSO, approval, or production rate-limit behavior. |
| Authentication | OAuth/PAT isolation, refresh/replacement fencing, identity replay, broker anti-replay controls, PAT-specific presentation, and account-local key/vault recovery are implemented. | Supply the real OAuth client ID and broker URL as deployment configuration, then run controlled OAuth/PAT acceptance. |
| Copilot | Explicit pinned CLI acquisition, vendor signature/architecture/hash verification, XPC/Rust session boundary, authenticated model inventory, consent, candidate budgets, caching, cancellation, and fail-closed action claims are implemented. XPC and Rust suites pass locally. A universal helper/XPC/app Developer ID signing pass succeeded at `134f51a`. | Acquire the pinned runtime and exercise entitled/non-entitled authentication with controlled accounts; repeat signing verification on the exact release candidate and complete notarization/Gatekeeper acceptance. |
| Linked-PR progress rules | The plan still requires linked-PR grouping and two progress predicates, but no production source emits `.linkedPullRequest`; `closingIssuesReferences` is intentionally distinct. Stable Project option identity/underway mapping and a PR-staleness policy are also absent. | Add the typed, revision-fenced source contract recorded in `GITHUB_FEATURE_CONTRACTS.md`; until then these relations/rules remain disabled and unknown. |
| Native UI and performance | Native windows, sidebar/detail/inspector, Settings navigation, commands, accessibility semantics, restoration, bounded inbox paging, and opt-in deterministic benchmark machinery are implemented. | Fixture-backed UI XCTest must run on a host where the runner bootstraps. Hardware benchmarks must run on a declared supported Mac; this Mac is not a supported baseline. |
| Encrypted migrations | Current fresh/idempotent paths cover migrations through `060`; the frozen fixture remains immutable. The schema-039 upgrade through current migration `060` passed during the full verifier on 2026-08-31 (35.585 s). | Never regenerate the frozen artifact from acceptance code; repeat on release candidates. |
| Local verification | Canonical arm64 build-for-testing, the complete 1,415-test non-UI production/XPC suite, the 298-test production plus 25-test fail-closed XPC matrix, focused vault selectors, Rust, broker, performance-runner, helper-build, release-helper, and package-mirror contracts pass. The full verifier's static phases and frozen migration test passed. Its Debug test action reached the app/UI runner but ended on one host automation timeout plus three stale fixture failures; all three fixture selectors and the complete non-UI suite pass after `3105e3f`. The universal Release app, XPC, Rust helper, Sparkle executables, and SQLCipher framework built for arm64/x86_64 and passed deep strict Developer ID signature verification at `134f51a`. | Re-run the full verifier on an XCTest UI host that can enter automation mode, then complete notarized release-candidate validation; do not convert host-only UI or release blocks into a pass. |

### Known historical results and current blockers

The temporary `.xcresult` bundles named below were inspected and summarized
before generated build data was removed to reclaim disk space. Their paths
identify the recorded runs; the bundles are not retained in the checkout or in
`/private/tmp`.

| Evidence | Status | Scope |
| --- | --- | --- |
| Full unit and fail-closed XPC suite | Historical pass: 997/997, zero failures/skips. | Recorded pre-current-worktree result only. |
| Canonical deterministic verifier phase | Historical pass: 998 deterministic tests, zero skips. | Recorded pre-current-worktree result only. |
| UI XCTest runner | Blocked: the latest full-verifier run launched the runner but timed out while enabling automation mode before a UI test method ran. Earlier ad-hoc and Apple Development-signed attempts failed Team-ID mapping or hung in `libsecinit`. | Host/toolchain blocker, not a product/UI acceptance result. |
| Current focused vault/XPC | Passed. | Existing-root open/reopen, absent trusted root under `/var`, relation hydration, and all fail-closed XPC tests pass in current result bundles. |
| Frozen schema-039 upgrade | Passed through current migration `060`. | The full `scripts/verify-ci.sh` Debug test action completed the immutable schema-039 upgrade selector in 35.585 seconds before the action later failed. |
| Current focused production/XPC matrix | Passed at `65ea09f`. | `/private/tmp/triage-broad-green-20260831-194203.xcresult`: 298 selected production tests and 25 fail-closed XPC tests, zero failures or skips. This is focused evidence, not a substitute for `scripts/verify-ci.sh`. |
| Full-suite regression repair | Passed at `3105e3f`. | `/private/tmp/triage-full-regressions-green-20260831.xcresult`: working-day invariant, relation grouping authority, and timeline input source/coverage identity selectors all pass together after their fixture repairs. |
| Complete non-UI production/XPC suite | Passed at `3105e3f`. | `/private/tmp/triage-full-nonui-green-20260831.xcresult`: 1,415 tests passed with zero failures, skips, or expected failures in 156.563 seconds. UI tests were explicitly excluded because this host cannot enter XCTest automation mode. |
| Universal signed Release build | Passed at `134f51a`. | Xcode 27.0 with pinned Rust 1.94 built version 0.1.0 (1) for arm64/x86_64. The app, XPC service, Rust helper, Sparkle executables, and SQLCipher framework are universal; app/XPC/helper carry Developer ID team `BJCVJ5G7MJ` with Hardened Runtime and pass `codesign --verify --deep --strict`. The 66 MiB bundle is installed at `/Applications/Triage.app` and launches locally. It is intentionally unnotarized and is not release acceptance. |

### External and host-only gates

1. Supply a real GitHub OAuth App client ID and trusted HTTPS authentication
   broker URL only as approved deployment configuration. Repository defaults
   remain blank and fail closed; these values must not be guessed or committed.
   PAT authentication remains independently usable and must not show OAuth
   configuration errors before its own submission.
2. Use a host where the macOS XCTest UI runner can bootstrap; then execute the
   complete fixture-backed UI and accessibility matrix.
3. With controlled GitHub accounts and explicit authorization, run the live
   source-authority matrix: SSO/approval, bodyless REST `403`/`404`, pagination,
   conditional reuse, identity mismatch, deletion/recovery, and no-write
   behavior. Do not add live data to the repository.
4. Keep Copilot fail-closed except for its bounded explicit-acquisition path: an
   authenticated, consented user may request only the pinned GitHub release
   through the exact GitHub-to-release-assets redirect, followed by archive,
   executable, architecture, and GitHub signature verification. No ambient CLI,
   arbitrary download or redirect, re-signed runtime, or unsigned artifact is an
   acceptable substitute.
5. Perform Developer ID signing, notarization/stapling, Gatekeeper, Sparkle,
   release tagging/publishing, and release-automation work only with the
   required credentials, clean exact tag, and explicit authorization.

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
- The recorded 997/997 unit/XPC and 998 deterministic results are historical
  only. They do not validate `134f51a` or the documentation worktree. Full UI/verifier
  acceptance remains pending because no UI test method launched on this host.
  OAuth deployment configuration, controlled live GitHub validation, production
  acceptance of the acquired-runtime authentication/consent path, exact
  release-candidate signing, notarization/publish, and final release acceptance
  remain open and are not implied by local coverage.
