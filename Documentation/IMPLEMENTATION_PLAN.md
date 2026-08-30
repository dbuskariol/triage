# Triage Complete Product and Implementation Plan

Status: authoritative execution plan

This document replaces every earlier high-level plan. It is the durable source of truth for product scope, architecture, implementation sequencing, security boundaries, acceptance criteria, and test coverage. Work is not complete until every in-scope requirement and acceptance criterion in this document is implemented and verified.

## 1. Product contract

Triage is a public, native macOS application that gives an individual GitHub user one reliable place to manage work scattered across GitHub organizations.

The app answers four questions:

1. What work currently involves me?
2. What specifically requires my action or response?
3. What work have I started but failed to update?
4. What am I waiting on, snoozing, prioritizing, or intentionally ignoring?

Triage is not a replacement GitHub client. GitHub remains the source of truth for issues, pull requests, reviews, discussions, projects, comments, and timeline activity. Triage creates a local work-management layer over that source data.

### 1.1 Agreed requirements

- GitHub.com is the supported GitHub environment.
- The product is publicly distributable to any GitHub user.
- The default sign-in is GitHub OAuth through the system browser using Authorization Code plus PKCE.
- A Personal Access Token is available as an advanced sign-in path.
- Both fine-grained and classic PATs are supported through runtime capability detection.
- Private repository support is mandatory.
- Multiple GitHub accounts are supported with fast switching.
- Exactly one organization is active at a time.
- There is no aggregated all-organizations dashboard.
- Organization workspaces expose the same views and behavior.
- GitHub source content, indexes, workflow state, and AI results are stored locally.
- Local cached content is encrypted at rest.
- The app caches everything required for responsive, reliable operation.
- GitHub content must never appear silently fresh when synchronization is stale, partial, blocked, or rate limited.
- The core app works without AI.
- GitHub Copilot analysis is an optional enhancement.
- Copilot analysis is explicitly enabled per organization.
- Copilot defaults to model Auto and provides an advanced model selector.
- A signed Rust helper and bundled official Copilot CLI runtime provide the Copilot SDK boundary.
- Classic PATs use a separate Copilot sign-in because the SDK does not accept classic PATs.
- The app discovers work through GitHub activity only; local repository scanning is not included.
- The app is read-only toward GitHub in the initial product contract.
- Triage does not post comments, edit content, alter subscriptions, or change notification read state.
- Triage actions affect only local workflow state.
- Native notifications are supported with quiet, configurable defaults.
- Background synchronization runs incrementally every few minutes while appropriate.
- Initial synchronization includes every relevant open item and relevant closed or merged activity from the previous 90 days.
- Relevant relationships include authored, assigned, review-requested, directly mentioned, team mentioned, reviewed, and commented.
- Issues, pull requests, reviews, comments, timeline events, discussions, Projects, draft project items, and every feasible token-visible relationship are supported.
- A unified Work Item groups strongly related GitHub objects.
- A Work Item may contain multiple separately trackable action items.
- High-confidence AI action items enter the Inbox automatically with evidence.
- Users can dismiss or correct AI results.
- Local workflow controls include archive, pin, snooze, priority, waiting, and action completion.
- Owned work becomes stale after three business days without an update by default.

### 1.2 Product non-goals

These are deliberate product boundaries, not deferred placeholders:

- GitHub Enterprise Server support.
- Editing GitHub issues, pull requests, projects, reviews, comments, or discussions.
- Marking GitHub notifications read or unread.
- Installing a GitHub App into an organization.
- Local Git repository or branch scanning.
- Cross-device synchronization.
- A hosted copy of GitHub content.
- A hosted AI analysis service.
- A browser-style reproduction of GitHub pages.
- A metrics-heavy dashboard.

## 2. Completion standard

Triage is complete only when:

- Every supported authentication path works end to end.
- SSO, token approval, scope, revocation, expiry, and organization-policy states are explicit.
- The selected organization can be fully indexed within the available credential capabilities.
- Incremental synchronization is durable, resumable, rate-aware, and idempotent.
- Every Inbox reason is explainable from stored evidence.
- Unified Work Items and action items remain stable across refreshes.
- All local workflow actions persist and are undoable where appropriate.
- Cached content remains usable during network failures.
- Stale or partial data is visibly identified.
- Copilot can be enabled, disabled, cancelled, and safely degraded without affecting the core app.
- The app remains responsive with at least 10,000 Work Items and a large cached timeline corpus.
- The signed universal app passes Hardened Runtime, notarization, Gatekeeper, Sparkle, privacy, accessibility, and release verification.
- No token, database key, GitHub private content, or Copilot prompt is leaked through logs, process arguments, environment inheritance, crash metadata, or unencrypted files.

## 3. System architecture

```text
Triage SwiftUI application
├── Application coordinator
├── Account and organization session
├── Native presentation models
├── Authentication subsystem
│   ├── OAuth PKCE client
│   ├── stateless OAuth exchange broker client
│   ├── PAT validator
│   ├── Keychain credential store
│   └── capability and SSO evaluator
├── GitHub data subsystem
│   ├── read-only REST client
│   ├── read-only GraphQL client
│   ├── rate-limit controller
│   ├── discovery planner
│   ├── hydration planner
│   ├── timeline normalizer
│   └── synchronization coordinator
├── Encrypted local data subsystem
│   ├── account vault registry
│   ├── SQLCipher database pool
│   ├── migrations
│   ├── repositories
│   ├── FTS index
│   ├── work graph
│   └── observation streams
├── Triage intelligence subsystem
│   ├── deterministic actionability engine
│   ├── ranking engine
│   ├── work grouping engine
│   ├── freshness evaluator
│   └── AI candidate policy
├── Copilot boundary
│   ├── Swift XPC service client
│   ├── signed XPC bridge
│   ├── signed Rust helper
│   └── bundled Copilot CLI runtime
└── macOS integrations
    ├── Settings scene
    ├── MenuBarExtra
    ├── UserNotifications
    ├── launch at login
    ├── state restoration
    └── Sparkle
```

### 3.1 Process boundaries

The main app owns all GitHub data, credentials, workflow state, rules, synchronization, and presentation.

The OAuth exchange broker is a minimal external security boundary required because GitHub still requires an OAuth client secret during code exchange even when PKCE is used. The broker:

- accepts a short-lived authorization code, PKCE verifier, redirect URI, and signed app request;
- exchanges or refreshes OAuth tokens with GitHub;
- returns the response directly;
- stores no token, account, organization, GitHub content, analytics, or session history;
- emits only non-sensitive operational metrics;
- applies strict origin, version, nonce, replay, and rate controls.

The Copilot helper receives only bounded normalized candidate inputs. It cannot read the database, Keychain, arbitrary files, shell environment, or GitHub directly.

## 4. Repository structure

```text
Triage/
  App/
  Authentication/
  Database/
    Migrations/
    Records/
    Repositories/
  Domain/
    Accounts/
    GitHub/
    Work/
    Workflow/
    Intelligence/
  GitHub/
    REST/
    GraphQL/
    Sync/
    Normalization/
  Intelligence/
    Rules/
    Ranking/
    Grouping/
    Copilot/
  Notifications/
  Views/
    Onboarding/
    Sidebar/
    WorkList/
    Detail/
    Inspector/
    Search/
    Settings/
    Components/
  Resources/
TriageCopilotXPC/
TriageCopilotHelper/
AuthBroker/
TriageTests/
TriageIntegrationTests/
TriageUITests/
Fixtures/
Scripts/
Documentation/
```

Files remain small and focused. Views do not access SQL, Keychain, URLSession, or Copilot directly.

## 5. Dependency policy

### 5.1 Swift dependencies

- Sparkle: application updates.
- GRDB: typed SQLite access, migrations, observation, and transaction management.
- SQLCipher-backed SQLite integration: encrypted database pages, WAL, and FTS.

No generic GraphQL client is added initially. The GitHub schema surface is narrow enough to use typed `Codable` request and response structures. This avoids generated-code weight and gives precise control over partial GraphQL errors.

### 5.2 Rust dependencies

- Official `github-copilot-sdk`.
- Tokio for bounded async process work.
- Serde and `serde_json` for strict IPC schemas.
- UUID and SHA-256 support.
- Zeroization support for secret-bearing buffers.

Every dependency is version-locked in committed lockfiles and included in release inventory checks.

## 6. Core domain model

### 6.1 Stable identifiers

Use immutable GitHub numeric IDs and GraphQL node IDs. Logins, organization names, repository names, and URLs are mutable display fields.

Every stored object has:

- a local typed ID;
- source account ID;
- selected organization ID;
- GitHub node ID when available;
- GitHub numeric ID when available;
- source revision or update timestamp;
- last observed timestamp;
- hydration completeness;
- accessibility state.

### 6.2 Account

```swift
struct AccountID: Hashable, Codable, Sendable

struct GitHubAccount: Sendable, Equatable {
    let id: AccountID
    let githubUserID: UInt64
    let nodeID: String
    let login: String
    let displayName: String?
    let avatarURL: URL?
    let authentication: AuthenticationKind
    let credentialStatus: CredentialStatus
    let createdAt: Date
    let lastValidatedAt: Date?
}
```

Authentication kinds:

- OAuth.
- Fine-grained PAT.
- Classic PAT.

Credential states:

- Active.
- Expiring.
- Expired.
- Revoked.
- Missing.
- Capability limited.
- Organization SSO required.
- Organization approval pending.
- Organization policy blocked.

### 6.3 Organization workspace

An organization workspace contains:

- stable organization identity;
- account-specific access state;
- accessible repository inventory;
- visible team inventory and membership;
- capability matrix;
- synchronization state;
- AI consent and model preference;
- notification preference;
- cached Work Items and workflow state.

### 6.4 GitHub content kinds

- Issue.
- Pull request.
- Pull request review.
- Pull request review thread.
- Pull request review comment.
- Issue comment.
- Discussion.
- Discussion comment.
- Discussion reply.
- Project V2.
- Project V2 item.
- Project V2 draft issue.
- Repository.
- Milestone.
- Label.
- Team.
- Actor.
- Commit reference.
- Status check summary.
- Timeline event.
- GitHub notification thread.

### 6.5 Work Item

A Work Item is Triage's durable grouping unit.

```swift
struct WorkItem: Sendable, Identifiable {
    let id: WorkItemID
    let accountID: AccountID
    let organizationID: OrganizationID
    let primaryNodeID: GitHubNodeID
    let title: String
    let state: WorkItemState
    let sourceKind: GitHubContentKind
    let repository: RepositorySummary?
    let memberNodeIDs: [GitHubNodeID]
    let relationEdges: [WorkRelation]
    let attentionReasons: [AttentionReason]
    let actionItems: [ActionItem]
    let workflow: WorkflowState
    let freshness: FreshnessState
    let lastRelevantActivityAt: Date
    let score: AttentionScore
}
```

Grouping is deterministic. Strong relations merge nodes; weak relations remain contextual links.

Strong merge relations:

- Pull request explicitly closes an issue.
- GitHub linked pull request or development item.
- User-confirmed relation.
- Project item directly wraps the content node.
- Review thread belongs to its pull request.
- Comment or timeline event belongs to its parent.

Context-only relations:

- Generic cross-reference.
- Shared label.
- Shared milestone.
- Same project without a direct content link.
- Same author or assignee.
- Mention in unrelated prose.

### 6.6 Action Item

Action item sources:

- Deterministic GitHub relationship.
- Deterministic conversation rule.
- Copilot extraction.
- Manual user entry.

Action item fields:

- stable ID;
- parent Work Item;
- title;
- optional detail;
- source kind;
- state;
- confidence;
- priority;
- explicit due date;
- evidence references;
- source fingerprint;
- created, updated, completed, dismissed timestamps;
- user correction metadata.

States:

- Open.
- Completed.
- Dismissed.
- Superseded.
- Invalidated by source change.

## 7. Encrypted persistence

### 7.1 Vault topology

Use one independent SQLCipher vault per GitHub account:

```text
Application Support/Triage/Vaults/<opaque-account-id>/triage.sqlite
Application Support/Triage/Vaults/<opaque-account-id>/triage.sqlite-wal
Application Support/Triage/Vaults/<opaque-account-id>/triage.sqlite-shm
```

Benefits:

- account deletion is complete and bounded;
- account credentials and private organization data cannot be accidentally joined;
- corruption and migration failure are isolated;
- fast account switching loads an already-open or recently used pool.

### 7.2 Key management

- Generate a 256-bit random vault key through Security.framework.
- Store it as a Keychain generic password keyed by opaque AccountID.
- Use device-only accessibility.
- Store OAuth access token, refresh token, PAT, and Copilot-specific credential references in separate Keychain records.
- Never place secrets in UserDefaults, SQLite, command-line arguments, process environment, logs, crash annotations, or notification payloads.
- If the vault key is missing, fail closed and offer local vault deletion plus resynchronization.

### 7.3 Database configuration

- Apply the SQLCipher key before any schema read on every connection.
- Enable foreign keys.
- Use WAL.
- Set a bounded busy timeout.
- Run cipher integrity checks during open and after risky recovery.
- Use secure deletion settings appropriate to SQLCipher.
- Disable SQL statement and bound-value tracing in production.
- Keep database work off the main actor.
- Use GRDB `DatabasePool` and transactional observation.

### 7.4 Schema groups

Identity:

- `accounts`
- `organizations`
- `account_organizations`
- `actors`
- `teams`
- `team_memberships`
- `repositories`
- `account_repository_access`
- `capabilities`

GitHub content:

- `github_nodes`
- `issues`
- `pull_requests`
- `reviews`
- `review_threads`
- `comments`
- `discussions`
- `discussion_comments`
- `projects`
- `project_fields`
- `project_items`
- `project_field_values`
- `labels`
- `milestones`
- `status_checks`
- `timeline_events`
- `notification_threads`

Graph:

- `relations`
- `relation_evidence`
- `work_items`
- `work_item_members`
- `work_item_context_links`

Workflow:

- `workflow_states`
- `action_items`
- `action_item_evidence`
- `workflow_history`
- `undo_transactions`

Synchronization:

- `sync_streams`
- `sync_shards`
- `sync_attempts`
- `conditional_request_cache`
- `rate_limit_buckets`
- `raw_api_snapshots`
- `normalization_failures`

Intelligence:

- `attention_reasons`
- `attention_scores`
- `rule_evaluations`
- `ai_consents`
- `ai_analyses`
- `ai_action_candidates`
- `ai_model_cache`
- `user_corrections`

Search:

- `search_documents`
- encrypted FTS5 tables for title, body, comments, repository, labels, people, and action text.

### 7.5 Migration policy

- Append-only numbered migrations.
- Each migration has a stable checksum.
- Migrations run transactionally.
- Schema downgrade is unsupported and produces a clear error.
- Destructive migrations create and verify an encrypted backup first.
- Every released schema has an upgrade fixture.
- Interrupted migration tests prove the prior database remains readable.

### 7.6 Private-data artifact inventory and crypto-erasure

Every location capable of containing GitHub content, credentials, derived text,
or Copilot input is registered in one typed artifact inventory:

- primary SQLCipher database;
- encrypted WAL and shared-memory files;
- encrypted pre-migration backups;
- encrypted recovery copies;
- bounded encrypted raw API snapshots;
- encrypted FTS pages;
- app-owned URL cache;
- downloaded avatars and rendered previews;
- notification routing metadata;
- XPC request buffers;
- Rust helper scratch directories;
- Copilot runtime session and configuration directories;
- crash recovery files;
- exported diagnostic packages explicitly created by the user.

Account deletion performs crypto-erasure in this order:

1. cancel sync and AI work;
2. close database pools and helper processes;
3. delete the vault key and account credentials from Keychain;
4. remove every app-owned artifact registered to the account;
5. verify no registered path remains;
6. remove the non-sensitive account registry record.

The app accurately discloses that Time Machine, user-created copies, filesystem
snapshots, and other external backups are outside Triage's ability to erase.

## 8. Authentication

### 8.1 OAuth default

Use `ASWebAuthenticationSession` with:

- system browser authentication;
- custom callback URL owned by Triage;
- 256-bit random state;
- 256-bit random PKCE verifier;
- S256 challenge;
- `prompt=select_account`;
- scopes `repo read:org offline_access`;
- strict callback state validation;
- ten-minute authorization-code timeout;
- cancellation support.

GitHub requires the OAuth client secret during token exchange even with PKCE. Triage must not embed that secret.

### 8.2 Stateless OAuth exchange broker

The repository contains a separately deployable minimal broker.

Broker endpoints:

- `POST /oauth/exchange`
- `POST /oauth/refresh`
- `GET /health`

Broker request security:

- application version header;
- one-use nonce;
- issue timestamp and strict expiry;
- PKCE verifier;
- exact redirect URI allowlist;
- request and IP rate limiting;
- maximum body size;
- TLS only;
- no cookies;
- no browser sessions;
- no response caching.

The broker does not pretend to authenticate a public macOS client: no embedded
secret, signing key, or device assertion can provide that guarantee. PKCE binds
the authorization code to the initiating client. The broker's controls protect
its own availability and strict protocol handling, not an invalid claim of
public-client attestation.

Broker storage:

- no database;
- no durable queue;
- no token logging;
- no request-body logging;
- no analytics identifiers.

Broker responses preserve GitHub's token response and explicit error fields.

### 8.3 PAT onboarding

The PAT entry surface:

- uses `SecureField`;
- disables pasteboard history retention where possible;
- never displays the token after submission;
- validates through `GET /user`;
- identifies token family from prefix and observed behavior;
- stores only in Keychain;
- immediately clears transient input memory as practical.

Fine-grained PAT behavior:

- asks for the resource-owner organization because `/user/orgs` may be empty;
- validates selected organization directly;
- discovers only repositories included in the token;
- records pending organization approval distinctly;
- records per-feature permission gaps.

Classic PAT behavior:

- recommends `repo` and `read:org`;
- supports multiple organizations;
- processes SSO headers;
- cannot authenticate Copilot SDK directly.

### 8.4 Multiple accounts

- The same GitHub user may connect more than one credential profile.
- Profiles never share credential records or vaults.
- Switching accounts immediately swaps cached presentation state.
- In-flight foreground work for the previous account is cancelled.
- Background work returns to a low-priority queue.
- A token resolving to a different immutable GitHub user ID cannot overwrite an existing profile.

## 9. Organization access and capability detection

### 9.1 Organization discovery

OAuth and classic PAT:

- paginate `/user/orgs`;
- preserve private membership visibility based on scopes;
- validate each selected organization by immutable ID.

Fine-grained PAT:

- accept manual organization selection;
- validate `/orgs/{org}`;
- probe accessible repositories;
- do not interpret empty `/user/orgs` as no membership.

### 9.2 SSO states

Process `X-GitHub-SSO` on every REST response.

States:

- Available.
- SSO authorization required with GitHub-provided URL.
- Partial results with affected organization IDs.
- Fine-grained token approval pending.
- OAuth application approval required.
- Organization policy blocked.
- Permission insufficient.
- Resource hidden or inaccessible.
- Credential expired or revoked.

For `required; url=...`:

- associate the state only with the affected account and organization;
- stop that organization's sync queue;
- do not persist the expiring authorization URL;
- show Authorize in Browser;
- open GitHub normally;
- retry the narrow capability probe when the app becomes active;
- declare success only after the API succeeds.

For `partial-results`:

- map immutable organization IDs;
- mark coverage partial;
- probe the selected organization directly;
- never silently omit its data.

### 9.3 Capability matrix

Capabilities are independently represented as Available, Unavailable, Unknown, RequiresSSO, RequiresApproval, or NotApplicable.

Probe:

- identity;
- token validity;
- token scopes;
- organization visibility;
- private repository visibility;
- team visibility;
- issue search;
- pull request details;
- review requests;
- review history;
- issue timeline;
- review comments;
- discussions;
- Projects V2 inventory;
- Project fields and items;
- notifications endpoint;
- Copilot entitlement;
- Copilot model list.

Capability probes run:

- after sign-in;
- after token replacement;
- after organization selection;
- after SSO return;
- after permission failures;
- daily for active accounts.

## 10. GitHub transport

### 10.1 Read-only enforcement

The transport API exposes:

- REST GET and HEAD.
- GraphQL query.

It does not expose mutation, POST-to-resource, PATCH, PUT, or DELETE operations.

GraphQL requests are parsed or constructed only from committed query documents and cannot contain `mutation`.

Tests reject accidental mutation verbs and query documents.

### 10.2 HTTP behavior

- Use a dedicated `URLSession`.
- Set the current GitHub API version header.
- Set explicit GitHub media types.
- Send a stable product User-Agent.
- Bound request and response sizes.
- Redact authorization and SSO URLs from logs.
- Validate GitHub hosts.
- Decode GitHub request IDs for diagnostics without user content.
- Respect cancellation.
- Treat partial GraphQL data and errors explicitly.

### 10.3 Rate limits

Persist and observe:

- REST core limit.
- REST search limit.
- GraphQL point limit and query cost.
- Retry-After.
- X-RateLimit-Remaining.
- X-RateLimit-Reset.
- secondary limit indicators.

Request scheduling priority:

1. selected Work Item detail;
2. selected organization foreground refresh;
3. direct Inbox candidate hydration;
4. selected organization incremental discovery;
5. discussions and project context;
6. inactive account refresh;
7. full reconciliation.

Default concurrency remains deliberately low and adapts downward after secondary-limit responses.

### 10.4 Feature-to-source contract

Every normalized feature has a committed source contract recording:

- authoritative REST endpoint or GraphQL query document;
- minimum OAuth scope or fine-grained permission;
- token families known to support it;
- pagination type;
- incremental cursor or overlap strategy;
- ETag support;
- expected GraphQL cost and response-size budget;
- fallback source;
- normalization owner;
- coverage effect on failure.

The concrete contracts for currently supported and intentionally unavailable
features are maintained in
[`GITHUB_FEATURE_CONTRACTS.md`](GITHUB_FEATURE_CONTRACTS.md).

GraphQL batch size is adaptive. The planner begins with a conservative batch,
records actual query cost and decoded payload size, and shrinks or grows within
hard bounds. Timeline, review-thread, Project-item, and discussion connections
are paginated independently rather than nested deeply into a large node batch.

Source precedence is explicit:

- REST issue timeline is authoritative for normalized timeline history;
- GraphQL current fields are authoritative for present issue and PR state;
- REST requested-reviewer state and GraphQL review requests must agree or mark
  review coverage partial;
- GraphQL is authoritative for Discussions and Project field unions;
- REST notifications are discovery evidence only and never authoritative for
  content or local unread state.

## 11. Discovery

### 11.1 Issues and pull requests

For the selected organization and current user, partition REST Search queries for:

- open involvement;
- open authored;
- open assigned;
- open direct mentions;
- open commenter involvement;
- open review requested;
- open review involvement;
- open team review requested;
- closed involvement within 90 days;
- merged review involvement within 90 days;
- closed authored within 90 days.

Store the discovery query as provisional evidence.

### 11.2 Search partitioning

GitHub search caps a query at 1,000 results and can return incomplete results.

Algorithm:

1. Record server-observed snapshot time.
2. Query a bounded updated-time range.
3. If count exceeds 1,000 or results are incomplete, bisect the time range.
4. If a timestamp remains unpartitionable, shard by accessible repository.
5. Persist shard boundaries and completion.
6. Follow server-provided pagination.
7. Deduplicate by immutable node ID.
8. Advance the stream watermark only after every shard succeeds.

### 11.3 Notifications

Use notifications only when the token supports them.

Notifications provide high-signal discovery reasons including:

- assign;
- author;
- comment;
- mention;
- team mention;
- review requested;
- state change;
- subscribed.

Triage stores notification metadata but never changes GitHub read state.

Notifications are not the sole durable index because token support and retention vary.

### 11.4 Discussions

GitHub does not provide equivalent organization-wide role-qualified discussion search.

For each accessible repository with discussions:

- query discussions ordered by updated time;
- scan the relevant 90-day window;
- inspect authors, comments, replies, accepted answers, direct mentions, and user participation;
- refresh active relevant discussions incrementally;
- persist coverage per repository;
- show partial coverage when permissions or rate budgets prevent completeness.

### 11.5 Projects

Discover organization Projects V2 inventory.

Prioritize:

- items wrapping already relevant issues and PRs;
- items assigned to the user through project fields;
- draft issues naming or assigning the user;
- project status, iteration, date, and assignee fields that affect actionability.

Do not merge unrelated content merely because it shares a project.

## 12. Hydration and normalization

### 12.1 GraphQL batching

Use `nodes(ids:)` with 25-50 nodes per request.

Hydrate common fields:

- repository and organization;
- author;
- title and body;
- state and timestamps;
- labels;
- assignees;
- milestone;
- participants;
- reactions needed for context;
- URL;
- project membership;
- sub-issue and dependency relations where available.

Pull request fields:

- draft;
- merge state;
- merged timestamp;
- base and head;
- review requests;
- reviews;
- review threads;
- status checks;
- linked closing issues.

### 12.2 Timeline

Use the REST issue timeline as the canonical event stream.

Normalize:

- assignment and unassignment;
- label changes;
- mentions and cross references;
- review requests and removals;
- reviews and dismissals;
- commits and references;
- state changes;
- project movement;
- milestones;
- linked and disconnected items;
- comments;
- renames;
- transfers;
- reopened and closed events.

Incremental timeline refresh stops after crossing a known event boundary plus overlap.

### 12.3 Raw payload policy

Keep encrypted raw payload snapshots when they are required for:

- parser replay;
- migration;
- unsupported future fields;
- diagnostics with user consent.

Raw payloads are bounded and tagged with endpoint, entity ID, ETag and
Last-Modified evidence, parser version, and fetch date. Conditional replay
additionally requires an exact source-specific request-authority binding;
legacy or partially scoped raw rows remain evidence only. Old superseded
payloads are compacted only after normalized state and testable replay are
preserved.

Timeline conditional replay binds the exact first-page validator to a durable
receipt covering every contiguous raw page, the prior completed source
revision, parser version, and the count and digest of normalized timeline
state. All receipt-bound pages remain compaction-protected. A `304` may advance
the current timeline source revision only after that receipt and normalized
state revalidate atomically; otherwise the synchronizer makes at most one
unconditional request to the same timeline endpoint and leaves coverage
incomplete if that authoritative request cannot complete.

## 13. Synchronization engine

### 13.1 Streams

Each account and organization maintains independent streams:

- identity;
- organization;
- repositories;
- teams;
- notifications;
- open issue and PR discovery;
- recent closed and merged discovery;
- hydration;
- timelines;
- reviews;
- discussions;
- projects;
- relation reconciliation;
- full reconciliation.

### 13.2 Atomic cursor rule

Cursor advancement and normalized data writes occur in one database transaction.

A failed or cancelled page:

- does not advance the cursor;
- does not publish a successful freshness timestamp;
- may retain individually valid idempotent upserts;
- records the incomplete attempt.

### 13.3 Refresh cadence

- foreground selected organization: immediate;
- active application: every 3-5 minutes with jitter;
- app activation: incremental refresh;
- manual refresh: high-priority incremental refresh;
- inactive accounts: lower cadence;
- repository, team, capability, discussion, and Project inventory: slower adaptive cadence;
- daily: complete open-item reconciliation plus 90-day closed/merged reconciliation.

Use a ten-minute overlap on updated-time watermarks.

### 13.4 Application lifecycle

Synchronization and notification evaluation run while the Triage application
process is running. Closing the last window does not quit Triage when its menu
bar item is enabled. Launch at login is offered as the reliable way to keep the
local inbox current after sign-in.

Triage does not claim to synchronize after the user explicitly quits, logs out,
the Mac sleeps, or macOS terminates the process. On the next launch or wake:

- the cached UI appears immediately;
- freshness identifies the last successful sync;
- the app performs a high-priority overlapping incremental refresh;
- missed snooze, Waiting, and deadline wake-ups are coalesced;
- notifications describe only changes confirmed after refresh.

`NSBackgroundActivityScheduler` is used for opportunistic work while the
process is alive; it is never described as a guaranteed daemon.

### 13.5 Coverage contract

Coverage is persisted at the smallest scope needed to prevent false completeness:

```swift
struct CoverageRecord: Sendable {
    let accountID: AccountID
    let organizationID: OrganizationID
    let repositoryID: RepositoryID?
    let feature: CoverageFeature
    let stream: SyncStreamID
    let interval: DateInterval?
    let credentialRevision: String
    let capabilityRevision: String
    let status: CoverageStatus
    let lastSuccessfulAt: Date?
    let failure: CoverageFailure?
}
```

Coverage features include repositories, teams, issues, pull requests, reviews,
review threads, timelines, notifications, discussions, Projects, project items,
and each discovery role query.

Aggregation rules:

- an organization is complete for a view only when every required repository,
  feature, stream, and time interval is complete for the current credential and
  capability revision;
- unsupported features are shown as unavailable and do not masquerade as empty;
- unknown team membership prevents claims of complete team-mention coverage;
- GraphQL partial errors downgrade only the affected fields and repositories;
- SSO or permission failures from REST or GraphQL invalidate affected coverage;
- empty-state UI is allowed only when required coverage is complete;
- otherwise the UI names the missing repositories, features, or time range.

### 13.6 Freshness

Every workspace and Work Item exposes:

- Fresh.
- Refreshing.
- Stale.
- Partial.
- Offline.
- Authentication required.
- SSO required.
- Approval required.
- Rate limited until a specific time.
- Failed with cached data retained.

The UI always exposes the last successful synchronization time and missing coverage.

## 14. Work graph

### 14.1 Relation types

Person relations:

- Authored.
- Assigned.
- Mentioned.
- Team mentioned.
- Commented.
- Review requested directly.
- Review requested through team.
- Reviewed.
- Changes requested from.
- Awaiting response from.

Content relations:

- Parent of.
- Child of.
- Closes.
- Closed by.
- Linked pull request.
- Cross references.
- Blocks.
- Blocked by.
- Duplicate of.
- Contains review.
- Contains thread.
- Contains comment.
- Project wraps content.
- Project contextual membership.

### 14.2 Evidence

Every relation stores:

- source endpoint or query;
- source node or event;
- source revision;
- observation time;
- confidence;
- whether it is provisional or confirmed.

Rules cannot claim a relationship as certain when underlying access is partial.

### 14.3 Grouping stability

- Work Item IDs remain stable when member nodes are hydrated later.
- Strong relation changes produce a deterministic merge plan.
- Merges preserve all local workflow history.
- Splits preserve action ownership and prompt the user only when assignment is ambiguous.
- User-confirmed grouping overrides automatic weak inference.

## 15. Deterministic actionability

AI never decides whether Triage can operate. Deterministic rules create the baseline Inbox and select AI candidates.

### 15.1 Rule output

```swift
struct AttentionReason {
    let ruleID: RuleID
    let ruleVersion: Int
    let category: AttentionCategory
    let strength: Int
    let title: String
    let explanation: String
    let evidence: [EvidenceReference]
    let evaluatedAt: Date
}
```

### 15.2 Rules

Direct responsibility:

- open item assigned to current user;
- open PR directly requesting current user's review;
- open PR requesting review from a visible team containing current user;
- project item with current user assignment;
- draft project item explicitly assigning or naming current user.

Conversation:

- direct mention in a source event newer than the user's latest qualifying
  progress event;
- team mention in a source event newer than the user's latest qualifying
  progress event;
- new reply in a thread the user participates in;
- new activity after a locally tracked Waiting request.

Semantic interpretations are Copilot candidates, not deterministic facts:

- whether prose is a directed question or imperative;
- whether a reply truly requires a response;
- whether clarification remains unanswered;
- whether the user promised or accepted an action;
- whether a natural-language commitment has been fulfilled.

Pull request:

- changes requested and no newer responsive commit or reply;
- requested review remains incomplete;
- authored PR has new review feedback;
- authored PR has unresolved review threads requiring author response;
- authored PR is blocked by failing required checks after new activity;
- authored PR is mergeable but waiting on a user-owned action.

Progress:

- current user owns the work and has no qualifying progress event for three
  business days;
- linked PR indicates work started but source issue lacks a subsequent update;
- source issue says work is underway but linked PR is stale or closed without resolution;
- a committed deadline is approaching or exceeded.

Waiting:

- current user asked another actor for information or action and no response exists;
- item marked Waiting receives new relevant activity;
- follow-up date for Waiting arrives.

State suppression:

- archived items leave Inbox;
- snoozed items leave Inbox until due;
- completed action items do not trigger;
- dismissed evidence does not retrigger unless source content materially changes;
- closed or merged items remain only when an unresolved local action exists.

### 15.3 Business-day calculation

- Default working days are Monday-Friday.
- Use the user's current calendar and time zone.
- Count elapsed business days from the latest meaningful user update.
- Settings allow changing working days and stale threshold.
- Time-zone changes recompute future thresholds without rewriting historical source timestamps.

Qualifying progress events are exact and testable:

- comment authored by the current user;
- pull request review submitted by the current user;
- commit pushed to an authored or assigned pull request;
- issue or pull request opened, reopened, closed, or merged by the current user;
- project status or iteration change performed by the current user when actor
  data is available;
- explicit local action completion.

Read-only viewing, reactions, labels changed by another actor, automated bot
activity, and background synchronization are not qualifying progress.

Public-holiday exclusion is not inferred. The business-day policy uses the
configured working weekdays and user calendar only.

### 15.4 Local workflow transition contract

Precedence from strongest to weakest:

1. deleted account or inaccessible encrypted vault;
2. active snooze exclusion;
3. archived exclusion;
4. Waiting state;
5. manual pin and priority;
6. deterministic or AI actionability;
7. informational involvement.

Transitions:

| Current state | Event | Result |
|---|---|---|
| Snoozed | snooze time arrives | restore prior archive or Waiting state, then re-evaluate |
| Snoozed | direct assignment or review request | remain snoozed unless user enabled urgent wake-up |
| Archived | ordinary new activity | remain archived and record unseen activity |
| Archived | user unarchives | re-evaluate all current evidence |
| Waiting | relevant response from awaited actor | leave Waiting and return to Inbox |
| Waiting | unrelated activity | remain Waiting |
| Waiting | follow-up date arrives | return to Inbox with follow-up reason |
| Action completed | unchanged evidence refreshes | remain completed |
| Action completed | materially new evidence | create a new action instead of reopening history |
| AI action dismissed | same fingerprint | remain dismissed |
| AI action dismissed | changed fingerprint | eligible for new analysis |
| Work Items merge | local states differ | preserve history; strongest explicit state wins and is explainable |
| Work Item splits | action evidence identifies one member | action follows that member |
| Work Item splits | evidence is ambiguous | keep action on primary item and flag grouping review |

Batch operations create one undo transaction containing every affected prior
state. Undo is retained across navigation and app relaunch for a bounded,
documented history window.

## 16. Ranking

Ranking is deterministic, persisted, explainable, and stable.

Inputs:

- manual pin;
- manual priority;
- direct responsibility tier;
- review urgency;
- explicit due date;
- overdue state;
- new relevant activity;
- stale progress;
- waiting wake-up;
- repository preference;
- item recency;
- draft or blocked state;
- snooze exclusion.

Every score stores a component breakdown.

Stable sort:

1. pinned;
2. manual priority;
3. attention score;
4. explicit due date;
5. latest relevant activity;
6. immutable Work Item ID.

UI displays human reasons, not an opaque numeric score.

## 17. Copilot intelligence

### 17.1 Consent

AI is disabled by default for every organization.

Consent explains:

- selected GitHub account;
- organization;
- that normalized conversation content is sent to GitHub Copilot;
- authentication method;
- model selection;
- categories of content included;
- local caching and deletion;
- that the dashboard works without AI.

Disabling AI:

- cancels active analyses;
- prevents helper launch;
- removes local AI caches for that organization;
- preserves deterministic rules and user-created action items.

### 17.2 Candidate policy

Analyze only when:

- deterministic rules identify a plausible follow-up;
- content coverage is sufficient;
- organization consent is active;
- authentication and entitlement are valid;
- the candidate fingerprint has changed;
- no valid cache entry exists;
- rate and concurrency budgets permit.

### 17.3 Input contract

Candidate input contains:

- stable candidate ID;
- normalized Work Item title and state;
- deterministic trigger reasons;
- bounded relevant body text;
- bounded relevant conversation window;
- timestamps;
- participant role aliases;
- labels and project fields relevant to actionability;
- evidence table with stable evidence IDs.

Do not include:

- tokens;
- local paths;
- unrelated comments;
- repository source code;
- hidden organizations;
- system logs;
- other accounts;
- arbitrary files.

All GitHub content is explicitly marked untrusted.

### 17.4 Output contract

The Rust helper accepts only strict JSON matching a versioned schema:

- summary;
- state;
- confidence;
- evidence IDs;
- action items;
- next action;
- explicit deadline only when present in evidence;
- model and prompt provenance.

Unknown fields, unknown evidence, duplicate IDs, invalid confidence, oversized strings, malformed dates, Markdown fences, or extraneous bytes reject the entire result.

### 17.5 Auto-entry policy

An AI action item automatically enters Inbox only when:

- schema validation succeeds;
- overall and item confidence meet a non-configurable product safety floor of
  at least 0.92; users may raise but never lower this floor;
- every action has evidence;
- evidence is current;
- contradiction checks pass;
- it is not a duplicate;
- it is not previously dismissed for the same fingerprint.

The Inbox row displays AI origin and evidence. Users can correct or dismiss it.

Auto-entry eligibility is restricted to actions corroborated by at least one
deterministic trigger such as current assignment, current review request,
explicit mention, unresolved requested change, Waiting response, or an explicit
deadline present verbatim in evidence. Semantic suggestions without a
corroborating trigger remain review-only.

The independent validator verifies actor, state, quoted span, timestamp,
deadline, and relevance against normalized source data. Genuine but irrelevant
evidence, unsupported actor attribution, or prompt-injected instructions reject
automatic entry.

### 17.6 Copilot process boundary

```text
Swift app
  -> NSXPCConnection
  -> signed TriageCopilotXPC service
  -> length-framed anonymous pipes
  -> signed universal Rust helper
  -> official Rust Copilot SDK in Empty mode
  -> explicitly bundled official Copilot CLI
```

The helper:

- uses no TCP listener;
- uses no shell;
- has no file, edit, web, MCP, skill, or agent tools;
- installs explicit deny-all permissions;
- sanitizes environment inheritance;
- uses a private empty working directory;
- receives credentials only ephemerally;
- does not persist sessions;
- supports health, models, analyze, cancel, and shutdown only;
- enforces request and response size limits;
- serializes or strictly bounds concurrency;
- supports cancellation and deadlines.

### 17.7 Copilot authentication

- OAuth token: explicit SDK token, no ambient fallback.
- Fine-grained PAT: explicit SDK token after entitlement validation.
- Classic PAT: never sent to Copilot; separate bundled CLI sign-in.
- Copilot login identity is visibly associated with the Triage account.
- Identity mismatch blocks analysis.

Separate Copilot sign-in uses the bundled official CLI's device flow inside an
app-owned isolated `COPILOT_HOME`. Before implementation, the pinned runtime's
credential storage is verified on macOS. Authentication may proceed only when:

- the token is stored in macOS Keychain rather than a plaintext config file;
- runtime logs and caches contain no token;
- the app can enumerate and delete every Triage-owned Copilot credential and
  session artifact;
- ambient `gh`, Copilot CLI, and environment credentials are disabled;
- the authenticated GitHub user ID matches the selected Triage account.

If the pinned runtime cannot meet these conditions, classic-PAT accounts retain
the complete deterministic product and Copilot remains explicitly unavailable;
the app must not weaken credential storage to force support.

### 17.8 Models

- Auto is default.
- Model list comes from the SDK.
- Cache model capabilities for 24 hours.
- Invalidate on credential, entitlement, policy, SDK, or runtime changes.
- If a selected model disappears, fall back visibly to Auto for future requests.

### 17.9 Lifecycle

- one ephemeral session per candidate;
- no session resume;
- startup timeout;
- total analysis timeout;
- user cancellation calls abort;
- helper termination follows bounded graceful shutdown;
- partial streamed content is never displayed or cached;
- only final validated output is accepted.

## 18. Native macOS UX

### 18.1 Main window

Use a native three-column work surface:

1. Sidebar.
2. Work Item list.
3. Detail.

An optional native inspector presents local workflow state.

Collapse order:

1. inspector;
2. sidebar according to system NavigationSplitView behavior.

### 18.2 Sidebar

Top:

- account switcher;
- organization switcher;
- access, sync, SSO, or rate-limit status when attention is required.

Views:

- Inbox.
- My Work.
- Reviews.
- Waiting.
- Snoozed.
- All Work.

Settings remains a standard Settings scene and menu command.

### 18.3 Work list

Use native `List` or `Table`, not cards.

Row content:

- source symbol;
- title;
- repository;
- author or responsibility context;
- strongest attention reason;
- action count;
- local pin, priority, snooze, and waiting indicators;
- latest relevant activity;
- freshness warning when needed.

Rows support:

- single and multiple selection;
- context menu;
- keyboard navigation;
- disclosure of child action items;
- drag only where standard list reordering is meaningful.

### 18.4 Detail

Header:

- type and state;
- title;
- repository and number;
- actors and labels;
- Open on GitHub.

Content:

- concise source body;
- grouped related nodes;
- action items;
- chronological normalized timeline;
- review state;
- project context;
- sync and coverage state.

Timeline pagination is incremental and cancellable.

GitHub Markdown is treated as untrusted content:

- render through a constrained native Markdown pipeline;
- strip executable HTML and unsupported tags;
- never execute script or embedded content;
- do not automatically load remote images or tracking pixels;
- proxy nothing through Triage infrastructure;
- allow GitHub-hosted images only after explicit policy validation;
- validate and visibly present external-link hosts before opening;
- preserve code, lists, quotes, links, and task-list semantics accessibly.

### 18.5 Inspector

Local workflow controls:

- Archive in Triage.
- Pin.
- Priority.
- Snooze.
- Waiting.
- Follow-up date.
- Action item editing and completion.
- Evidence and Why this is here.
- Freshness and last sync.

Controls explicitly state that they do not modify GitHub.

### 18.6 Toolbar

- standard sidebar toggle;
- back and forward selection history;
- organization title when sidebar hidden;
- search;
- refresh;
- inspector toggle.

Do not fill the toolbar with workflow actions available through menus and context menus.

### 18.7 Search

Search:

- title;
- body;
- comments;
- repository;
- labels;
- people;
- action items;
- local notes;
- project values.

Scopes:

- current view;
- all work in selected organization.

Search is local and returns initial results within 150 ms on the target dataset.

### 18.8 Commands

- Command-1 through Command-6 select sidebar views.
- Command-F focuses search.
- Command-R refreshes.
- Command-O opens the selected source on GitHub.
- Command-Delete archives locally.
- Control-Command-P toggles pin.
- Control-Command-1/2/3 sets priority.
- Control-Command-S snoozes.
- Control-Command-W toggles Waiting.
- Option-Command-I toggles inspector.
- Command-Comma opens Settings.

Menus and contextual actions share one command implementation.

### 18.9 Empty and failure states

Implement explicit native states for:

- no account;
- no organization;
- first sync;
- empty Inbox;
- empty filtered view;
- empty search;
- offline cache;
- expired credential;
- SSO required;
- token approval pending;
- insufficient capability;
- rate limit;
- partial coverage;
- normalization failure;
- Copilot unavailable;
- database recovery required.

Use `ContentUnavailableView`, `ProgressView`, standard alerts, sheets, and banners.

### 18.10 Onboarding

Onboarding occurs in the normal main window:

1. Connect account.
2. Choose OAuth or advanced PAT.
3. Validate identity.
4. Select organization.
5. Resolve SSO or approval if required.
6. Start initial sync.
7. Explain local workflow controls.
8. Offer notifications only after useful Inbox content exists.
9. Offer per-organization Copilot consent separately.

## 19. Settings

Accounts:

- connected accounts;
- auth kind;
- credential state;
- reconnect;
- replace token;
- separate Copilot identity;
- remove account and encrypted data.

Organizations:

- selected organization;
- capability matrix;
- SSO state;
- repository coverage;
- synchronization status;
- AI consent;
- notification preference.

Inbox:

- stale threshold;
- working days;
- default sort;
- default snooze durations;
- automatic high-confidence AI threshold.

Notifications:

- global enablement;
- per-organization enablement;
- direct assignment;
- review request;
- high priority;
- snooze due;
- Waiting response;
- quiet schedule.

AI:

- organization consent;
- Copilot identity;
- entitlement;
- Auto or selected model;
- cache deletion;
- analysis history and evidence policy.

General:

- menu bar;
- launch at login;
- appearance density using native list sizing;
- refresh behavior.

Updates and About retain the existing Sparkle and privacy surfaces.

## 20. Menu bar

The menu bar extra shows:

- selected account and organization;
- sync/access warning when present;
- Inbox and high-priority counts;
- up to five highest-priority items;
- Open Triage;
- Refresh;
- Settings;
- Quit.

It never duplicates the full application.

## 21. Notifications

Notifications are opt-in and quiet by default.

Lock-screen content defaults to generic text such as “New Triage item” and the
organization name. Showing repository names, private issue titles, actors, or
action text requires an explicit notification privacy setting.

Eligible events:

- new high-priority Inbox item;
- direct assignment;
- direct or team review request;
- new response on Waiting item;
- snooze expires;
- explicit deadline approaches.

Behavior:

- coalesce duplicate events;
- avoid repeated notifications for unchanged evidence;
- respect Focus and system notification settings;
- route to the correct account, organization, view, and Work Item;
- offer local Snooze and Archive actions;
- do not include sensitive body text by default;
- do not mark GitHub notifications read.

## 22. State restoration

Restore:

- window geometry;
- split widths;
- sidebar visibility;
- inspector visibility;
- selected account;
- selected organization;
- sidebar view;
- sort and filter;
- search scope;
- valid selected Work Item;
- timeline expansion state where practical.

Do not restore:

- expired authorization sheets;
- transient errors;
- notification prompts;
- stale Copilot operations.

## 23. Security and privacy

- Hardened Runtime for every executable.
- App, XPC service, Rust helper, Copilot CLI, Sparkle helpers, and broker artifacts are independently verified.
- No embedded OAuth secret.
- No arbitrary helper path.
- No writable runtime replacement.
- No unverified runtime download.
- No token in process arguments or general environment.
- OSLog uses private interpolation for identifiers and never logs content.
- Database and WAL are encrypted.
- Search index is encrypted inside the same vault.
- Sign-out deletes Keychain credentials and the complete account vault.
- AI deletion removes organization AI data and helper scratch state.
- Privacy manifest declares required-reason APIs accurately.
- The app ships no analytics or tracking.
- app-owned URL cache, avatars, previews, migration backups, recovery files,
  notification routing metadata, and helper artifacts follow the private-data
  inventory and account crypto-erasure policy.

## 24. Performance budgets

- cached application interactive within one second;
- account and organization switch shows cached content within 150 ms;
- Inbox query first page within 100 ms;
- local search first page within 150 ms;
- selection-to-detail initial render within 100 ms;
- smooth native scrolling with 10,000 Work Items;
- database, network, normalization, rules, indexing, and AI off main actor;
- no unbounded task, queue, result set, timeline, raw payload, or AI context;
- cancellation on account, organization, selection, search, or window lifecycle changes;
- bounded memory during full reconciliation.

Performance verification uses committed generated fixtures representing:

- 10,000 Work Items;
- 100,000 normalized timeline events;
- 250 accessible repositories;
- 50 Projects with 10,000 relevant items;
- 5,000 discussion threads and replies;
- 25,000 searchable comments;
- 500 simultaneous actionable items.

Baseline hardware is the oldest supported Intel Mac and an entry Apple silicon
Mac supported by macOS 26. CI fails when median or 95th-percentile budgets
regress beyond the documented tolerance without an approved updated baseline.

## 25. Error and recovery policy

- Never turn an error into an empty successful result.
- Never delete content because an incremental query omitted it.
- Treat private-resource 404 as inaccessible until authoritative reconciliation proves deletion.
- Keep cached content during network, rate, auth, and GitHub failures.
- Preserve local workflow state during reauthentication and resync.
- Surface normalization failures with endpoint and object identity but without private content.
- Database corruption preserves the encrypted original and offers verified backup restoration or resync.
- Copilot failure never blocks deterministic Inbox functionality.

## 26. Testing

### 26.1 Unit tests

- typed identifiers and Codable stability;
- OAuth state and PKCE generation;
- token-family detection;
- SSO header parsing;
- capability state transitions;
- rate-limit parsing;
- pagination;
- search sharding;
- GraphQL partial-error decoding;
- normalization for every content and timeline kind;
- relation evidence;
- grouping merge and split;
- every actionability rule;
- business-day calculations;
- ranking breakdown and stable ordering;
- snooze and Waiting wake-up;
- AI schema validation;
- AI cache fingerprints;
- notification deduplication;
- freshness transitions.

### 26.2 Encrypted database tests

- correct key opens;
- wrong or missing key fails;
- WAL remains encrypted;
- migration fixtures;
- interrupted migration;
- corruption;
- account deletion;
- FTS;
- observation streams;
- cursor atomicity;
- local workflow preservation during GitHub upserts.

### 26.3 GitHub integration fixtures

- OAuth and PAT response fixtures;
- SSO required and partial headers;
- approval pending;
- revocation and expiry;
- REST pagination and ETags;
- search incomplete and >1,000 sharding;
- GraphQL partial data;
- issue and PR timelines;
- reviews and review requests;
- discussions;
- Project fields and redacted items;
- transferred and deleted content;
- rate and secondary limits.

Live pre-release validation uses controlled GitHub.com accounts and
organizations covering:

- OAuth with expiring tokens;
- OAuth application approval restrictions;
- fine-grained PAT approved and pending;
- classic PAT with and without SAML authorization;
- private repositories;
- visible and hidden team membership;
- Discussions and Projects enabled and disabled;
- Copilot entitled and non-entitled accounts.

### 26.4 Copilot tests

- consent disabled prevents helper launch;
- code-sign identity validation;
- XPC caller validation;
- environment sanitization;
- zero tools;
- permission denial;
- malformed IPC;
- oversized request;
- prompt injection;
- invalid JSON;
- invented evidence;
- timeout and cancellation;
- helper crash;
- entitlement failure;
- OAuth, fine-grained PAT, and separate Copilot sign-in;
- model disappearance;
- cache invalidation;
- high-confidence auto-entry;
- user dismissal and correction.

### 26.5 UI tests

- onboarding paths;
- account switching;
- organization switching;
- SSO recovery;
- initial sync;
- every sidebar view;
- work list selection and multi-selection;
- search;
- inspector actions;
- undo;
- menu commands;
- menu bar;
- notifications;
- empty, offline, partial, and rate-limited states;
- Settings;
- state restoration;
- reduced motion;
- increased contrast;
- keyboard-only operation;
- VoiceOver labels.

Accessibility acceptance explicitly verifies:

- deterministic focus order across sidebar, list, detail, and inspector;
- VoiceOver announcements for selection, sync errors, workflow changes, and
  newly inserted action items;
- keyboard-only completion of onboarding and every workflow action;
- increased text size without clipping or lost controls;
- Increase Contrast and Differentiate Without Color;
- Reduce Motion;
- window widths from the minimum supported size through full screen.

### 26.6 Release tests

- Apple silicon and Intel builds;
- universal executable checks;
- dependency lock checks;
- helper and CLI architecture checks;
- nested code-sign checks;
- entitlements;
- Hardened Runtime;
- privacy manifest;
- notarization and stapling;
- Gatekeeper;
- Sparkle signing and extraction verification;
- artifact checksums and manifest;
- no secret files;
- no writable bundled runtime.

## 27. Implementation sequence and commit boundaries

Each boundary is independently reviewed and committed only after its targeted tests pass.

1. Commit authoritative plan, dependency graph, and architecture documentation.
2. Add domain identifiers, enums, Work Item, action, evidence, workflow, freshness, and capability models.
3. Add deterministic rules, business-day policy, ranking, and grouping with exhaustive fixtures.
4. Add GRDB/SQLCipher dependency, vault registry, Keychain keys, migrations, and encrypted database tests.
5. Add typed repositories, FTS, observation streams, workflow history, and undo transactions.
6. Add read-only HTTP transport, REST and GraphQL primitives, redacted diagnostics, and rate-limit controller.
7. Add OAuth PKCE client and stateless auth broker with protocol and security tests.
8. Add PAT onboarding, multi-account session management, Keychain credential lifecycle, and account deletion.
9. Add organization discovery, capability probes, SSO handling, approval states, and organization switching.
10. Add repository/team inventory, issue/PR discovery, search partitioning, and durable cursors.
11. Add batch hydration, reviews, timelines, relations, and Work Item graph reconciliation.
12. Add Discussions and Projects ingestion with explicit coverage reporting.
13. Add incremental scheduler, daily reconciliation, freshness, offline, and retry behavior.
14. Replace placeholder UI with onboarding, native sidebar, list, detail, inspector, toolbar, search, and Settings.
15. Add workflow actions, keyboard commands, undo, menu bar, notifications, and restoration.
16. Add XPC bridge, Rust helper, official Copilot SDK, bundled runtime, schemas, and signing.
17. Add consent, models, candidate policy, analysis, caching, evidence, and AI action integration.
18. Add full integration fixtures, performance tests, accessibility audit, release validation, and final documentation.

## 28. Final acceptance walkthrough

The final signed app must demonstrate:

1. Connect two GitHub accounts through different supported auth methods.
2. Switch between accounts without leaking cached data.
3. Select an SSO-protected organization.
4. Detect missing classic PAT SSO authorization.
5. Open GitHub's supplied authorization URL and recover after successful SSO.
6. Detect fine-grained token approval or permission limitations.
7. Complete initial organization synchronization.
8. Display cached Inbox instantly after relaunch.
9. Show authored, assigned, mentioned, commented, review-requested, reviewed, discussion, and project-backed work.
10. Group an issue with its closing pull request and reviews.
11. Preserve weak cross-references without incorrect grouping.
12. Explain every Inbox reason with source evidence.
13. Show multiple action items within one Work Item.
14. Apply archive, pin, snooze, priority, Waiting, completion, and Undo.
15. Wake snoozed and Waiting items correctly.
16. Detect three-business-day stale progress.
17. Keep GitHub notification read state unchanged.
18. Continue using cached content offline with visible freshness.
19. Recover from rate limits and partial GraphQL data.
20. Search all encrypted cached content quickly.
21. Enable Copilot for one organization only.
22. Analyze deterministic candidates and validate evidence.
23. Auto-add only high-confidence actions.
24. Dismiss and correct AI results without retriggering unchanged content.
25. Disable Copilot and remove organization AI data.
26. Route native notifications into the correct account, organization, and Work Item.
27. Operate the complete app using keyboard and VoiceOver.
28. Install a verified Sparkle update.
29. Pass universal signed, notarized, stapled, Gatekeeper, privacy, and release-artifact verification.
