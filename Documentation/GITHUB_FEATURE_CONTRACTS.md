# GitHub feature source contracts

This document is the committed source contract for every feature that Triage
normalizes from GitHub. `IMPLEMENTATION_PLAN.md` remains the product contract.
Synchronizers must implement these contracts exactly or leave the affected
coverage incomplete. They must not substitute a broader endpoint, a mutation,
or an undocumented fallback.

## Shared transport rules

All REST sources use an authenticated `GET`, GitHub API version headers, and
the `Link` header for pagination. When GitHub returns an `ETag`, the next exact
incremental request sends `If-None-Match`. If that response has no ETag but
does have `Last-Modified`, the next exact request may instead send
`If-Modified-Since`; ETag always takes precedence and the two validators are
not sent together. A `304` records a successful, unchanged interval only when
the request carried a current credential/capability-revision validator for the
same account, organization, feature, stream, endpoint, query, and first-page
identity and committed normalized state exists. An unsolicited or
cross-authority `304` fails closed. REST cursor overlap is five minutes, except
the discovery searches defined below. REST page and GraphQL connection limits
are 100 and 50 respectively unless a contract states otherwise.

All GraphQL documents must be committed under
`Triage/GitHub/GraphQL/GitHubGraphQLQueries.swift`, use a named `query`
operation, and include `rateLimit { cost remaining resetAt }`. A document is
rejected if it contains `mutation`. Node hydration begins at 25 IDs and may
grow to 50 only after the observed cost and decoded payload remain under the
limits below. Timeline, review-thread, Project-item, and Discussion
connections are independently paginated; they are never deeply nested in node
hydration.

OAuth scopes are minimum grants, not a claim that a resource is visible.
Fine-grained token permissions apply to the selected resource owner and are
still subject to organization approval and SSO. Classic PATs use the same
OAuth-scope column; they cannot authenticate Copilot. A permission, SSO,
approval, rate-limit, malformed-payload, or incomplete-result failure always
records incomplete coverage for the named feature and interval. It never
produces an empty or complete inbox.

| Contract term | Rule |
| --- | --- |
| Cached raw payload | Store only encrypted, bounded snapshots with endpoint/query name, immutable object ID, ETag and Last-Modified evidence, parser version, and fetch timestamp. A raw snapshot authorizes conditional replay only when it also carries the exact current account, organization, feature, stream, request, credential-revision, and capability-revision identity required by that source's replay contract. Legacy or partially scoped raw rows remain evidence only. |
| REST budget | Maximum 100 objects per page and 2 MiB decoded response. |
| GraphQL budget | Maximum 50 hydrated nodes, 500 points, and 4 MiB decoded response per request. Shrink the next batch after exceeding either threshold. |
| Failure fallback | A fallback may provide discovery evidence only unless explicitly marked authoritative. It cannot overwrite authoritative normalized data. |
| Coverage owner | Records account, organization, repository where applicable, feature, stream, interval, credential revision, capability revision, result, and failure. |

## Identity and inventory

| Feature | Authoritative source and normalizer | Minimum access | Pagination and incremental strategy | ETag / budget | Fallback and coverage on failure |
| --- | --- | --- | --- | --- | --- |
| Authenticated identity | `GET /user`; `GitHubIdentityClient.authenticatedUser` | OAuth `repo read:org`; fine-grained token valid for its owner | None; validate at sign-in, replacement, and daily active-account probe | ETag if provided; 256 KiB | None. Invalid identity marks the credential revoked; no account profile is overwritten. |
| Organization visibility | `GET /user/orgs`; `GitHubIdentityClient.organizations` | OAuth/classic `read:org`; fine-grained owner selected manually | `Link`; full list after sign-in, then daily | ETag; 1 MiB | Fine-grained PAT uses `GET /orgs/{org}`. Empty `/user/orgs` is not negative evidence. Failure leaves organization visibility incomplete. |
| Selected organization | `GET /orgs/{org}`; `GitHubIdentityClient.organization` | OAuth/classic `read:org`; fine-grained organization Metadata read | None; probe after selection, token replacement, and SSO return | ETag; 256 KiB | None. SSO or approval failure blocks only this organization. |
| Repository inventory and private visibility | `GET /orgs/{org}/repos?type=all`; `GitHubIdentityClient.allRepositories` | OAuth/classic `repo`; fine-grained Metadata read on included repositories | `Link`; five-minute overlap, daily full reconciliation | ETag; 2 MiB/page | No fallback. An empty result is authoritative only after all pages succeed; otherwise repository and private-repository coverage are incomplete. |
| Team visibility | `GET /orgs/{org}/teams` and member endpoints, committed before use | OAuth/classic `read:org`; fine-grained organization Members read when GitHub permits | `Link`; daily, with five-minute overlap | ETag; 2 MiB/page | None. Hidden membership remains unknown; mention coverage must not claim complete team resolution. |

## Work discovery and current fields

| Feature | Authoritative source and normalizer | Minimum access | Pagination and incremental strategy | ETag / budget | Fallback and coverage on failure |
| --- | --- | --- | --- | --- | --- |
| Issue and pull request discovery | `GET /search/issues`; `GitHubIssueSearchClient`, then `GitHubSearchNormalizer` | OAuth/classic `repo`; fine-grained Issues read and Pull requests read | REST page numbers. Partition each relationship into open plus closed/merged in the preceding 90 days. Snapshot time before search; bisect updated ranges when a shard is incomplete or reaches the result cap. | Search ETag or Last-Modified; 100 results/page, 30 requests/minute search budget | Repository/time-range shards may replace a too-large organization shard. Notifications are discovery evidence only. Any unresolved shard leaves issue/PR search coverage incomplete. |
| Current issue and PR fields | `TriageHydrateNodes` GraphQL query; `GitHubGraphQLQueries.hydrateNodes`, then node normalizer | OAuth/classic `repo`; fine-grained Issues read and Pull requests read | `nodes(ids:)`; 25-50 IDs, five-minute updated-at overlap | No ETag; 500 points / 4 MiB | REST search supplies candidate identity only. Missing node, partial GraphQL error, or query budget exhaustion leaves the field and repository coverage incomplete. |
| Private repository membership | Repository inventory plus hydrated `Repository.isPrivate` | Same as repository inventory | Same inventory/reconciliation cadence | Inventory budget | No fallback. A hidden repository is inaccessible, not absent. |
| Issue timeline | `GET /repos/{owner}/{repo}/issues/{number}/timeline`; `GitHubTimelineClient`, then `GitHubTimelineNormalizer` | OAuth/classic `repo`; fine-grained Issues read or Pull requests read | `Link`; first page on candidate update, then continue from durable page cursor | ETag or Last-Modified; 2 MiB/page | No alternate source. A complete, scoped `cross-referenced` event may produce only a contextual relation from its typed `source.issue.node_id`. This endpoint does not presently provide a typed target-node contract for duplicate or dependency state, so those relations remain unknown until a separately covered authoritative source exists. Timeline failure downgrades only timeline coverage. |
| Linked development pull request and “work underway” state | Unavailable until a committed typed Issue-to-development-item traversal, exact current target-PR hydration evidence, stable Project field/option identity, and an explicit configured underway-option mapping exist | Not yet defined; must be documented before implementation | Not yet defined | Not yet defined | No inference from `closingIssuesReferences`, generic cross-references, project field display text, names, or prose. `.closes`/`.closedBy` are not `.linkedPullRequest`. The linked-PR progress predicates and linked-PR strong grouping remain disabled/unknown until this source contract is added with complete revision-fenced coverage and a defined PR-staleness policy. |
| Pull request review history | `GET /repos/{owner}/{repo}/pulls/{number}/reviews`; `GitHubPullRequestClient.reviews` | OAuth/classic `repo`; fine-grained Pull requests read | `Link`; full first load, then five-minute overlap | ETag; 2 MiB/page | None. Failure leaves review-history coverage incomplete. |
| Requested reviewers | `GET /repos/{owner}/{repo}/pulls/{number}/requested_reviewers`; `GitHubPullRequestClient.requestedReviewers` | OAuth/classic `repo`; fine-grained Pull requests read | None; fetch after candidate or PR update | ETag; 256 KiB | GraphQL `reviewRequests` corroborates but cannot silently disagree. A disagreement records partial review coverage. |
| Review threads and comments | A committed, independently paginated GraphQL query before use | OAuth/classic `repo`; fine-grained Pull requests read | Cursor per PR review-thread connection, five-minute overlap | 500 points / 4 MiB | None. This feature stays unknown until the document exists; it must not be inferred from review summaries. |
| Pull request status checks | `TriagePullRequestStatusChecks`; `GitHubPullRequestStatusCheckClient`, then `StatusCheckRepository`. The named GraphQL query reads the exact pull request's `statusCheckRollup.contexts`, `headRefOid`, and each `CheckRun.isRequired(pullRequestId:)` / `StatusContext.isRequired(pullRequestId:)`; no branch-protection or name-based inference is allowed. | OAuth/classic `repo`; fine-grained Pull requests read and Checks read where separately granted | Cursor per pull request connection. Every page must carry the exact current `headRefOid`; a changed, missing, or malformed OID fails the traversal rather than mixing commits. Raw snapshots are encrypted/bounded and bind the named query, PR node ID, requested cursor, returned `headRefOid`, account/organization/credential/capability revisions, parser version, and observation time. | 50 contexts/page; at most 100 pages; 500 total GraphQL cost and 4 MiB decoded payload per traversal | None. Missing rollup, partial GraphQL error, duplicate context identity, page/cursor/budget failure, stale or changed PR revision, permission/SSO/approval failure, or an inaccessible candidate retains normalized rows and records non-complete status-check coverage. It never claims checks passed or mergeability is actionable. |

Timeline `304` reuse additionally requires one encrypted receipt that binds the
exact current first-page validator to every contiguous raw page, the raw source
revision, parser version, a previously completed timeline shard, and the count
and digest of the normalized timeline state. Every receipt-bound raw page is
protected from compaction. Cancellation or any missing, stale, corrupt, gapped,
or cross-authority evidence leaves the prior normalized state unchanged. When
the server returned `304` but local receipt validation fails, the timeline
client may make one explicit unconditional request to that same endpoint; it
must not use another GitHub source, treat the stale state as current, or mark
coverage complete from the `304` alone.

Search `304` reuse additionally requires one encrypted page binding whose v2
identity covers the exact current account, organization, role-discovery leaf
stream, `GET`, canonical percent-encoded endpoint/query/page, credential and
capability revisions, and parser version. The binding and its raw snapshot
must retain the same safe ETag/Last-Modified pair and exact request authority;
ETag takes precedence when both are present. A raw page referenced by a
normalization failure cannot authorize replay. Legacy, missing, stale,
cross-stream, malformed, or corrupt evidence is invalidated only for that
exact binding and causes one explicit unconditional request to the same search
page. Cancellation prevents that invalidation and retry. No `304` may create
an empty success or complete coverage without its bound normalized page write.

## Context features

| Feature | Authoritative source and normalizer | Minimum access | Pagination and incremental strategy | ETag / budget | Fallback and coverage on failure |
| --- | --- | --- | --- | --- | --- |
| Discussions | `TriageRepositoryDiscussions`; `GitHubDiscussionClient`, then `GitHubDiscussionNormalizer` | OAuth/classic `repo`; fine-grained Discussions read | Cursor per repository; five-minute overlap. | 500 points / 4 MiB | None. Issues and issue comments are never substituted. A partial response preserves the existing repository inventory and downgrades only that repository's discussion coverage. |
| Discussion comments and replies | `TriageDiscussionComments` and `TriageDiscussionCommentReplies`; `GitHubDiscussionCommentClient`, then `GitHubDiscussionCommentNormalizer` | OAuth/classic `repo`; fine-grained Discussions read | Cursor per Discussion comments connection and, independently, per returned DiscussionComment replies connection; 50 nodes/page and at most 100 pages for each connection. Comment and reply leaf streams are separate per discussion and use a five-minute high-water overlap. A complete publication requires a terminal root page and a terminal replies traversal for every returned comment; an empty root is authoritative only with its terminal root page. | The client stops a complete traversal at 500 GraphQL points or 4 MiB decoded payload. Every raw page is retained as an encrypted, bounded snapshot bound to its query name, immutable Discussion or DiscussionComment node, exact cursor request, leaf stream, and current account/organization/credential/capability authority. | None. Partial, malformed, permission, SSO, approval, rate-limit, cursor, and budget failures retain valid raw failure evidence and cached normalized content, and record non-complete coverage for the affected comments or replies leaf; they never publish empty or complete coverage. Normalized records, raw evidence, and both complete coverage records commit atomically. Omission is not deletion evidence. |
| Projects V2 and fields | `TriageOrganizationProjectsV2`, `TriageProjectV2Items`, and `TriageProjectV2ItemFieldValues`; `GitHubProjectV2Client`, then `GitHubProjectV2Normalizer` | OAuth/classic `repo read:org`; fine-grained Projects read for the owner | Cursor per organization project inventory, project item connection, and item field-value connection; five-minute overlap | 500 points / 4 MiB | None. Partial GraphQL responses preserve existing data; malformed unions preserve the affected collection. Unsupported field-value unions are retained as explicit context, while incomplete nested unions downgrade only the affected project-item coverage. |
| Notifications | `GET /notifications`; normalizer records discovery evidence only | OAuth/classic `notifications`; fine-grained notifications access when available | `Link`; ETag-driven polling | ETag; 2 MiB/page | No content fallback. Notification state never authoritatively changes GitHub content or local unread workflow state. |

## Copilot capability contracts

| Feature | Source and authority | Minimum access | Coverage and failure behavior |
| --- | --- | --- | --- |
| Copilot entitlement | Shipping Triage artifacts must contain a universal Developer ID-signed XPC service and Rust helper; the official GitHub Copilot CLI is acquired only by explicit user action from the pinned release and independently vendor-verified in app-owned Application Support | Separate explicit Copilot sign-in matching the selected GitHub identity. OAuth and fine-grained PAT credentials may be passed ephemerally only after consent; classic PATs are never passed. | Absent or unverified runtime, missing entitlement/consent/authenticated account, ambient CLI, arbitrary redirect, re-signed runtime, or unsigned fallback leaves analysis unavailable. Local unsigned/ad-hoc builds do not establish production signing or runtime acceptance. |
| Copilot model list | Same independently verified acquired runtime | Same as entitlement | Model list failure leaves AI unavailable and never affects deterministic inbox coverage or ranking. |

## Contract change rules

1. Add or revise a source contract in the same commit as its client, query
   document, normalizer, coverage handling, and fixture tests.
2. Append a new query document rather than accepting caller-supplied GraphQL.
3. Preserve raw snapshots and normalized data when a new parser fails; record
   parser version and a redacted diagnostic.
4. Treat a GitHub access error as scoped evidence. Do not disable another
   account, organization, repository, or feature because one contract failed.
