# Triage development handoff

**Handoff state:** `a77fa56` (`Align native Settings sidebar chrome`) is the
current committed local acceptance checkpoint. The production integration graph,
post-account identity replay, GraphQL cardinality closure, native workspace, and
Settings chrome are complete locally. Combined Debug builds, focused selectors,
the deterministic unit/XPC suite, runtime accessibility geometry, and the
unsigned universal Release bundle are validated below. Triage is **not** globally
complete: the macOS UI-test runner still cannot bootstrap on this host, OAuth
deployment values and controlled live GitHub access are not supplied, Copilot
remains intentionally fail-closed without an approved runtime, and signing,
notarization, and release operations remain external or explicitly authorized
work. This document records the local closure chronology and the exact residual
order.

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
- Current committed local acceptance checkpoint: `a77fa56`
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

## Validation through the committed continuation checkpoint

| Check | Result | Notes |
| --- | --- | --- |
| Coordinator/lifecycle acceptance | Passed | 42/42: production lifecycle, completion, account/organization coordinator, and end-to-end acceptance selectors. |
| REST review failure provenance | Passed | 37/37, including bodyless `403`/`404` classification in the deliberately narrow source-bound grammar. |
| Review thread synchronization | Passed | 56/56 focused thread/reconciliation tests. |
| Discussion and comment synchronization | Passed | 48/48 focused discussion/comment tests. |
| Observation and AppModel injection | Passed | 11/11 focused observation/injection tests. |
| Security and accessibility | Passed | 143/143 focused security/accessibility coverage. |
| Current acceptance regression set | Passed | 180/180 from the freshly regenerated canonical bundle, including cache revision fencing, background/wake scheduling, derived batching/cancellation, notifications, native workflow/navigation, accessibility, and encrypted migration fixtures. |
| Review authority/failure regression set | Passed | 36/36: semantic REST raw binding, accumulated and zero-body classified failures, corroboration, and atomic reconciliation. |
| Final convergence selectors | Passed | 192/192 across identity replay, daily identity refresh, inventory, GraphQL/Projects V2, review receipts, derived inputs, workspace state/accessibility, work-list selection, and account persistence. |
| Native Settings layout selector | Passed | 10/10 `AppNavigationModelTests`, including the explicit Settings sidebar width/alignment contract. |
| Full unit and fail-closed XPC suite | Passed | 997/997, zero failures or skips, from `/tmp/triage-residual-full.xcresult`. |
| Canonical verifier deterministic phase | Passed | 998 deterministic tests passed with zero skips in `/Users/nftdannyboy/Library/Developer/Xcode/DerivedData/Triage/CI/Logs/Test/Test-Triage-2026.08.31_12-28-59-+1000.xcresult`; its only reported failure is the pre-test UI-runner bootstrap below. |
| Native Settings runtime geometry | Passed | Live Accessibility inspection on macOS 27 proves one unified full-size titlebar; the system sidebar control occupies y=206--246 beside the traffic lights, and the first sidebar row and detail heading both begin at y=266. PAT presentation was also inspected without an inherited pre-submission OAuth configuration error. |
| Unsigned universal Release build | Passed | Post-Settings-fix `Triage` and `TriageCopilotXPC` both contain `x86_64 arm64`; app, XPC, and privacy plists pass `plutil`; bundle identifier/version/build/minimum OS are `com.triage.mac` / `0.1.0` / `1` / `26.0`. |
| `git diff --check` | Passed | No whitespace errors before the handoff documentation update. |
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

### Current local acceptance validation wave

The final local corrections are committed through `a77fa56`. The canonical
Debug bundle compiled, focused convergence selectors passed 192/192, the
Settings selector passed 10/10, the independent full unit/XPC suite passed
997/997, and the latest canonical verifier passed 998 deterministic tests
before its UI runner failed to bootstrap. The post-fix unsigned universal
Release bundle passed architecture/privacy/bundle inspection. These results do
not imply UI-runner, live GitHub, Copilot, Developer ID signing, notarization,
or release acceptance.

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

The workspace is connected to production observations and actions, native
commands, secure scoped navigation, workflow/detail/inspector surfaces,
toolbar/search, notification presentation, restoration, and Settings. It does
not authenticate, persist secrets, or claim a non-existent Copilot runtime.
Accessibility, keyboard, appearance, encrypted fixture, deletion/recovery,
performance, and security tracks have local implementation and focused test
coverage; controlled live and release acceptance remain separate work.

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

## Residual order after local integration

The production integration graph and every repository-local product slice are
complete through the committed local acceptance checkpoint `a77fa56`; do not
reopen those finished edges merely because the work was originally split across
tracks. The known remaining work is externally dependent or host-environment
acceptance, in this required order:

1. Supply a real GitHub OAuth App client ID and trusted HTTPS authentication
   broker URL as deployment configuration. These values must not be guessed or
   committed. PAT authentication remains independently usable and must not show
   OAuth configuration errors before its own submission.
2. Re-run `scripts/verify-ci.sh` on a host where the macOS XCTest runner can
   bootstrap. The current run passed 998 deterministic tests, then the ad-hoc UI
   runner failed its Team-ID mapping check before any UI test method. A locally
   Apple Development-signed retry passed bundle signing but hung in `libsecinit`
   before XCTest bootstrap. Do not classify either result as a product/UI test
   failure or as UI acceptance.
3. With controlled access to a real GitHub account and explicit authorization,
   run the live GitHub scenario matrix. Validate source authority, redacted
   failures, bodyless REST `403`/`404`, SSO/approval, pagination, conditional
   reuse, identity mismatch revocation, deletion/recovery, and no-write behavior
   without adding live data to the repository.
4. Keep Copilot fail-closed. Resume only after an approved redistributable
   runtime, SDK/entitlement, consent and policy decisions, signing identity,
   and their explicit authorization are supplied; then perform its isolated
   security and end-to-end acceptance.
5. On a UI-runner-capable host and with the authorized live configuration,
   complete the final runtime walkthrough: windows, commands, keyboard,
   VoiceOver, light/dark appearance, resizing, restoration, performance, and
   security. The current host has direct runtime Accessibility evidence for
   launch, Settings structure/alignment, and PAT presentation, but not the full
   automated UI matrix.
6. Release packaging, Developer ID signing, notarization, tag/publish, and
   release automation require their external credentials, a clean exact tag,
   and explicit authorization. They are not implied by this handoff.

### Local track closure

| Track | Local status | Residual boundary |
| --- | --- | --- |
| Identity and organization metadata | Complete locally: encrypted exact-scope post-account `/user/orgs` and `/orgs/{org}` replay, daily `/user` identity revalidation, credential-replacement reconciliation, and mismatch revocation. First-connect `/user` remains correctly unconditional. | OAuth deployment values and controlled live GitHub validation. |
| REST reviews and review threads | Complete: durable scoped failure provenance, narrow bodyless `403`/`404` grammar, fair retry, reconciliation, and derived input. | Controlled live GitHub validation. |
| Discussions, comments, Projects V2, notifications | Complete: independently scoped retrieval, normalization, coverage, organization-work integration, and production notification/Settings wiring. | Controlled live GitHub validation. |
| Account/organization lifecycle and derived intelligence | Complete: production composition, launch/active/wake/background/stop reachability, scope fences, post-normalized derived projection, and explicit outcome handling. | UI-runner and live acceptance. |
| Observations and AppModel injection | Complete: explicit production dependencies and scoped UI publication. | UI-runner and runtime acceptance. |
| Native UI, commands, and secure navigation | Complete locally, including production bindings, stable multi-selection, restoration, PAT error isolation, wider native Settings sidebar, unified titlebar, and accessibility/security coverage. | Full UI-runner and authorized runtime acceptance. |
| Deletion/recovery, encrypted fixtures, performance, accessibility, security | Complete local implementation and focused test coverage, including encrypted `039` through `046` migration/tamper, privacy diagnostics, and deletion disclosure. | Controlled live/final acceptance where applicable. |
| Copilot XPC | Hardened and intentionally fail-closed. | Approved runtime, signing, consent, and authorization. |

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
- Focused tests through the committed `a77fa56` checkpoint are recorded above;
  the independent unit/XPC suite is 997/997 green, the latest canonical verifier
  passed 998 deterministic tests before its sole UI-runner bootstrap failure,
  and the post-fix unsigned universal Release bundle is valid. Full UI/verifier
  acceptance is still pending because no UI test method launched on this host.
  OAuth deployment configuration, controlled live GitHub validation, the
  externally approved Copilot runtime/signing/consent path, Developer ID
  signing/notarization/publish, and final release acceptance remain open and are
  not implied by local coverage.
