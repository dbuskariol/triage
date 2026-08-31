import GRDB
import XCTest
@testable import Triage

final class RoleDiscoveryPlanTests: XCTestCase {
    func testPlanIncludesExactDocumentedRoleStreams() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let plan = try RoleDiscoveryPlan(
            organizationLogin: "github",
            userLogin: "octocat",
            now: Date(timeIntervalSince1970: 90 * 24 * 60 * 60),
            calendar: calendar
        )

        XCTAssertEqual(plan.streams.map(\.kind), RoleDiscoveryStreamKind.allCases)
        XCTAssertEqual(plan.streams.count, 12)
        XCTAssertEqual(
            plan.streams.first { $0.kind == .openReviewRequested }?.queries.first?.value,
            "org:github is:open review-requested:octocat"
        )
        XCTAssertEqual(
            plan.streams.first { $0.kind == .recentMergedReviewInvolvement }?.queries.first?.value,
            "org:github is:merged reviewed-by:octocat closed:>=1970-01-01"
        )
        XCTAssertTrue(
            plan.streams
                .filter { $0.kind.rawValue.hasPrefix("recent-") }
                .flatMap(\.queries)
                .allSatisfy { $0.value.contains("closed:>=") }
        )
    }

    func testTeamReviewStreamUsesOnlyConfirmedActiveVisibleTeams() throws {
        let activeTeam = TeamInventorySummary(
            id: TeamID(rawValue: "T_active")!,
            nodeID: GitHubNodeID(rawValue: "T_active")!,
            slug: "mac-apps",
            name: "Mac Apps",
            privacy: "closed",
            membershipState: "active"
        )
        let pendingTeam = TeamInventorySummary(
            id: TeamID(rawValue: "T_pending")!,
            nodeID: GitHubNodeID(rawValue: "T_pending")!,
            slug: "pending-team",
            name: "Pending Team",
            privacy: "secret",
            membershipState: "pending"
        )
        let plan = try RoleDiscoveryPlan(
            organizationLogin: "github",
            userLogin: "octocat",
            teams: [pendingTeam, activeTeam],
            now: Date(timeIntervalSince1970: 1_000_000)
        )

        let stream = try XCTUnwrap(
            plan.streams.first { $0.kind == .openTeamReviewRequested }
        )
        XCTAssertEqual(stream.queries.count, 1)
        XCTAssertEqual(
            stream.queries.first?.value,
            "org:github is:open team-review-requested:github/mac-apps"
        )
        XCTAssertEqual(
            stream.streamID(parent: SyncStreamID(rawValue: "role-org")!).rawValue,
            "role-org-open-team-review-requested"
        )

        let mentionStream = try XCTUnwrap(
            plan.streams.first { $0.kind == .openTeamMentions }
        )
        XCTAssertEqual(
            mentionStream.queries.first?.value,
            "org:github is:open team:github/mac-apps"
        )
    }

    func testSourceSpecificFailureDoesNotPreventIndependentRoleStream() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".role-stream-isolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: "org-1")!
        let credentialRevision = CredentialRevision(rawValue: "credential-1")!
        let capabilityRevision = CapabilityRevision(rawValue: "capability-1")!
        let observedAt = Date(timeIntervalSince1970: 2_000)
        let vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        let account = GitHubAccount(
            id: accountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_1")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: observedAt
        )
        let organization = GitHubOrganization(
            id: organizationID,
            githubOrganizationID: 2,
            nodeID: GitHubNodeID(rawValue: "O_1")!,
            login: "github"
        )
        try await AccountRepository(vault: vault).save(
            account,
            credentialRevision: credentialRevision
        )
        try await AccountRepository(vault: vault).save(
            organization,
            access: OrganizationAccess(
                accountID: accountID,
                organizationID: organizationID,
                state: .available,
                capabilityRevision: capabilityRevision,
                capabilities: [],
                checkedAt: observedAt
            ),
            selectedAt: observedAt
        )
        let plan = try RoleDiscoveryPlan(
            organizationLogin: organization.login,
            userLogin: account.login,
            now: observedAt
        )
        let assigned = try XCTUnwrap(plan.streams.first { $0.kind == .openAssigned })
        let authored = try XCTUnwrap(plan.streams.first { $0.kind == .openAuthored })
        let selectedStreams = [assigned, authored]
        let parentStreamID = SyncStreamID(rawValue: "role-org-1")!
        let range = SearchTimeRange(
            start: Date(timeIntervalSince1970: 1_000),
            end: observedAt
        )
        for stream in selectedStreams {
            try await CoverageRepository(vault: vault).save(
                CoverageRecord(
                    accountID: accountID,
                    organizationID: organizationID,
                    repositoryID: nil,
                    feature: .roleDiscovery,
                    streamID: stream.streamID(parent: parentStreamID),
                    intervalStart: range.start,
                    intervalEnd: range.end,
                    credentialRevision: credentialRevision,
                    capabilityRevision: capabilityRevision,
                    status: .partial,
                    lastSuccessfulAt: nil,
                    failureDetail: nil
                ),
                attemptedAt: observedAt
            )
        }
        let client = RoleIsolationSearchClient()
        let recorder = RoleOutcomeRecorder()

        do {
            _ = try await RoleDiscoverySynchronizer(
                searchClient: client,
                workItemRepository: WorkItemRepository(vault: vault),
                shardRepository: SyncShardRepository(vault: vault),
                clock: { observedAt }
            ).synchronize(
                plan: plan,
                scope: SynchronizationScope(
                    accountID: accountID,
                    organizationID: organizationID,
                    credentialRevision: credentialRevision,
                    capabilityRevision: capabilityRevision
                ),
                githubOrganizationID: organization.githubOrganizationID,
                streamID: parentStreamID,
                searchRange: range,
                accessibleRepositoryNames: [],
                repositoryID: { _ in nil },
                streams: selectedStreams,
                recordStreamOutcome: { stream, outcome in
                    await recorder.record(stream: stream.kind, outcome: outcome)
                }
            )
            XCTFail("Expected the first source-specific failure to remain visible.")
        } catch let failure as GitHubFailure {
            XCTAssertEqual(failure.kind, .notFound)
        }

        let requestedRelationships = await client.requestedRelationships()
        XCTAssertEqual(requestedRelationships, [.assigned, .authored])
        let outcomes = await recorder.outcomes()
        XCTAssertEqual(outcomes.map(\.stream), [.openAssigned, .openAuthored])
        XCTAssertEqual(outcomes.map(\.outcome.status), [.unavailable, .complete])
    }

    func testSearchSynchronizationCreatesCandidateWithoutAuthoritativeRelationsOrReasons() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".role-candidate-authority-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: "org-1")!
        let repositoryID = RepositoryID(rawValue: "repo-1")!
        let credentialRevision = CredentialRevision(rawValue: "credential-1")!
        let capabilityRevision = CapabilityRevision(rawValue: "capability-1")!
        let observedAt = Date(timeIntervalSince1970: 2_000)
        let vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        let account = GitHubAccount(
            id: accountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_1")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: observedAt
        )
        let organization = GitHubOrganization(
            id: organizationID,
            githubOrganizationID: 2,
            nodeID: GitHubNodeID(rawValue: "O_1")!,
            login: "github"
        )
        try await AccountRepository(vault: vault).save(
            account,
            credentialRevision: credentialRevision
        )
        try await AccountRepository(vault: vault).save(
            organization,
            access: OrganizationAccess(
                accountID: accountID,
                organizationID: organizationID,
                state: .available,
                capabilityRevision: capabilityRevision,
                capabilities: [],
                checkedAt: observedAt
            ),
            selectedAt: observedAt
        )
        try await insertRoleDiscoveryRepository(
            into: vault,
            organizationID: organizationID,
            repositoryID: repositoryID,
            observedAt: observedAt
        )
        let parentStreamID = SyncStreamID(rawValue: "role-org-1")!
        let plan = try RoleDiscoveryPlan(
            organizationLogin: organization.login,
            userLogin: account.login,
            now: observedAt
        )
        let stream = try XCTUnwrap(plan.streams.first { $0.kind == .openAssigned })
        let range = SearchTimeRange(
            start: Date(timeIntervalSince1970: 1_000),
            end: observedAt
        )
        try await CoverageRepository(vault: vault).save(
            CoverageRecord(
                accountID: accountID,
                organizationID: organizationID,
                repositoryID: nil,
                feature: .roleDiscovery,
                streamID: stream.streamID(parent: parentStreamID),
                intervalStart: range.start,
                intervalEnd: range.end,
                credentialRevision: credentialRevision,
                capabilityRevision: capabilityRevision,
                status: .partial,
                lastSuccessfulAt: nil,
                failureDetail: nil
            ),
            attemptedAt: observedAt
        )
        let body = Data(
            """
            {"total_count":1,"incomplete_results":false,"items":[{"id":1,"node_id":"I_1","number":1,"title":"Candidate only","state":"open","html_url":"https://github.com/github/triage/issues/1","created_at":"1970-01-01T00:16:40Z","updated_at":"1970-01-01T00:33:20Z","closed_at":null,"repository_url":"https://api.github.com/repos/github/triage"}]}
            """.utf8
        )
        let roleSearchETag = "\"role-search-v1\""
        let roleSearchLastModified = "Tue, 01 Sep 2026 00:00:00 GMT"
        let roleSearchSession = RoleSearchSession(
            body: body,
            eTag: roleSearchETag,
            lastModified: roleSearchLastModified,
            returnsNotModifiedForMatchingETag: true
        )
        let searchClient = GitHubIssueSearchClient(
            client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: roleSearchSession),
                credential: SecretValue("token")
            )
        )
        let replayRepository = RoleSearchPageReplayRepository(vault: vault)
        let synchronizationScope = SynchronizationScope(
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision
        )
        let roleStreamID = stream.streamID(parent: parentStreamID)

        let result = try await RoleDiscoverySynchronizer(
            searchClient: searchClient,
            workItemRepository: WorkItemRepository(vault: vault),
            shardRepository: SyncShardRepository(vault: vault),
            replayRepository: replayRepository,
            clock: { observedAt }
        ).synchronize(
            plan: plan,
            scope: synchronizationScope,
            githubOrganizationID: organization.githubOrganizationID,
            streamID: parentStreamID,
            searchRange: range,
            accessibleRepositoryNames: ["github/triage"],
            repositoryID: { _ in repositoryID },
            streams: [stream]
        )

        XCTAssertEqual(result.candidateNodeIDs, [GitHubNodeID(rawValue: "I_1")!])
        let workItems = try await WorkItemRepository(vault: vault).fetch(
            accountID: accountID,
            organizationID: organizationID
        )
        let workItem = try XCTUnwrap(workItems.first)
        XCTAssertTrue(workItem.relations.isEmpty)
        XCTAssertTrue(workItem.attentionReasons.isEmpty)
        XCTAssertFalse(workItem.isVisibleInInbox(at: observedAt))
        let snapshots = try await RawAPISnapshotRepository(vault: vault).snapshots(for: accountID)
        XCTAssertEqual(snapshots.count, 1)
        let initialSnapshot = try XCTUnwrap(snapshots.first)
        let boundedQuery = try XCTUnwrap(stream.queries.first).bounded(to: range)
        let replayIdentity = try GitHubIssueSearchRequestIdentity(
            query: boundedQuery,
            page: 1,
            scope: synchronizationScope,
            streamID: roleStreamID
        )
        let conditionalIdentity = ConditionalRequestIdentity(
            scope: synchronizationScope,
            feature: .roleDiscovery,
            streamID: roleStreamID,
            requestKey: replayIdentity.requestKey
        )
        XCTAssertEqual(initialSnapshot.requestIdentity, conditionalIdentity)
        XCTAssertEqual(initialSnapshot.eTag, roleSearchETag)
        XCTAssertEqual(initialSnapshot.lastModified, roleSearchLastModified)
        let persistedRoleStream = try await SyncStreamRepository(vault: vault).stream(
            withID: roleStreamID,
            accountID: accountID
        )
        XCTAssertEqual(persistedRoleStream?.organizationID, organizationID)
        XCTAssertEqual(persistedRoleStream?.feature, .roleDiscovery)

        let replayedResult = try await RoleDiscoverySynchronizer(
            searchClient: searchClient,
            workItemRepository: WorkItemRepository(vault: vault),
            shardRepository: SyncShardRepository(vault: vault),
            replayRepository: RoleSearchPageReplayRepository(vault: vault),
            clock: { observedAt.addingTimeInterval(1) }
        ).synchronize(
            plan: plan,
            scope: synchronizationScope,
            githubOrganizationID: organization.githubOrganizationID,
            streamID: parentStreamID,
            searchRange: range,
            accessibleRepositoryNames: ["github/triage"],
            repositoryID: { _ in repositoryID },
            streams: [stream]
        )

        XCTAssertEqual(replayedResult.candidateNodeIDs, result.candidateNodeIDs)
        let retainedReplaySnapshots = try await RawAPISnapshotRepository(vault: vault).snapshots(
            for: accountID
        )
        XCTAssertEqual(retainedReplaySnapshots.map(\.id), snapshots.map(\.id))
        let recordedValidators = await roleSearchSession.validators()
        XCTAssertEqual(
            recordedValidators,
            [
                RoleSearchRequestValidators(eTag: nil, lastModified: nil),
                RoleSearchRequestValidators(eTag: roleSearchETag, lastModified: nil)
            ]
        )
        let replayEntry = try await replayRepository.entry(
            requestKey: replayIdentity.requestKey,
            streamID: roleStreamID,
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision
        )
        XCTAssertEqual(replayEntry?.snapshot.id, snapshots.first?.id)
        XCTAssertEqual(replayEntry?.snapshot.requestIdentity, conditionalIdentity)
        XCTAssertEqual(replayEntry?.snapshot.eTag, roleSearchETag)
        XCTAssertEqual(replayEntry?.snapshot.lastModified, roleSearchLastModified)
        XCTAssertEqual(replayEntry?.replay.streamID, roleStreamID)
        XCTAssertEqual(replayEntry?.replay.eTag, roleSearchETag)
        XCTAssertEqual(replayEntry?.replay.lastModified, roleSearchLastModified)
        XCTAssertEqual(replayEntry?.replay.lastValidatedAt, observedAt.addingTimeInterval(1))

        await roleSearchSession.setNotModifiedSSOHeader(
            "partial-results; organizations=\(organization.githubOrganizationID)"
        )
        let ssoRecorder = RoleOutcomeRecorder()
        do {
            _ = try await RoleDiscoverySynchronizer(
                searchClient: searchClient,
                workItemRepository: WorkItemRepository(vault: vault),
                shardRepository: SyncShardRepository(vault: vault),
                replayRepository: replayRepository,
                clock: { observedAt.addingTimeInterval(2) }
            ).synchronize(
                plan: plan,
                scope: synchronizationScope,
                githubOrganizationID: organization.githubOrganizationID,
                streamID: parentStreamID,
                searchRange: range,
                accessibleRepositoryNames: ["github/triage"],
                repositoryID: { _ in repositoryID },
                streams: [stream],
                recordStreamOutcome: { stream, outcome in
                    await ssoRecorder.record(stream: stream.kind, outcome: outcome)
                }
            )
            XCTFail("A scoped SSO-bearing 304 must remain incomplete.")
        } catch let error as OrganizationRefreshError {
            guard case let .ssoRequirement(header) = error else {
                return XCTFail("Expected the scoped SSO requirement, got \(error).")
            }
            XCTAssertEqual(
                header,
                .partialResults(Set([organization.githubOrganizationID]))
            )
        }
        let ssoOutcomes = await ssoRecorder.outcomes()
        XCTAssertEqual(ssoOutcomes.map(\.outcome.status), [.requiresSSO])
        let snapshotsAfterSSO = try await RawAPISnapshotRepository(vault: vault).snapshots(
            for: accountID
        )
        XCTAssertEqual(snapshotsAfterSSO.map(\.id), snapshots.map(\.id))

        let malformedPayload = Data(#"{"token":"ghp_privateMalformedRoleSearch""#.utf8)
        let malformedClient = GitHubIssueSearchClient(
            client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: RoleSearchSession(body: malformedPayload)),
                credential: SecretValue("token")
            )
        )
        do {
            _ = try await RoleDiscoverySynchronizer(
                searchClient: malformedClient,
                workItemRepository: WorkItemRepository(vault: vault),
                shardRepository: SyncShardRepository(vault: vault),
                replayRepository: replayRepository,
                clock: { observedAt.addingTimeInterval(2) }
            ).synchronize(
                plan: plan,
                scope: synchronizationScope,
                githubOrganizationID: organization.githubOrganizationID,
                streamID: parentStreamID,
                searchRange: range,
                accessibleRepositoryNames: ["github/triage"],
                repositoryID: { _ in repositoryID },
                streams: [stream]
            )
            XCTFail("Expected malformed role-search JSON to fail without becoming an empty page.")
        } catch is GitHubIssueSearchUndecodableResponseError {
            // Expected after the raw payload and failed shard are committed together.
        }
        let retainedSnapshots = try await RawAPISnapshotRepository(vault: vault).snapshots(
            for: accountID
        )
        XCTAssertTrue(retainedSnapshots.contains { $0.payload == malformedPayload })
        let failures = try await NormalizationFailureRepository(vault: vault).failures(
            for: accountID
        )
        let malformedFailure = try XCTUnwrap(
            failures.first { failure in
                retainedSnapshots.contains {
                    $0.id == failure.rawSnapshotID && $0.payload == malformedPayload
                }
            }
        )
        XCTAssertFalse(
            malformedFailure.redactedDiagnostic.contains("ghp_privateMalformedRoleSearch")
        )
        let removedReplayEntry = try await replayRepository.entry(
            requestKey: replayIdentity.requestKey,
            streamID: roleStreamID,
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision
        )
        XCTAssertNil(removedReplayEntry)
        let preservedItems = try await WorkItemRepository(vault: vault).fetch(
            accountID: accountID,
            organizationID: organizationID
        )
        XCTAssertEqual(preservedItems.map(\.primaryNodeID), [GitHubNodeID(rawValue: "I_1")!])

        // Re-establish a valid binding, then prove that a single malformed item
        // retains the page's valid discovery evidence but cannot complete or
        // authorize replay for the stream.
        _ = try await RoleDiscoverySynchronizer(
            searchClient: searchClient,
            workItemRepository: WorkItemRepository(vault: vault),
            shardRepository: SyncShardRepository(vault: vault),
            replayRepository: replayRepository,
            clock: { observedAt.addingTimeInterval(3) }
        ).synchronize(
            plan: plan,
            scope: synchronizationScope,
            githubOrganizationID: organization.githubOrganizationID,
            streamID: parentStreamID,
            searchRange: range,
            accessibleRepositoryNames: ["github/triage"],
            repositoryID: { _ in repositoryID },
            streams: [stream]
        )
        let reboundReplay = try await replayRepository.entry(
            requestKey: replayIdentity.requestKey,
            streamID: roleStreamID,
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision
        )
        XCTAssertNotNil(reboundReplay)

        let mixedPayload = Data(
            """
            {"total_count":2,"incomplete_results":false,"items":[{"id":2,"node_id":"I_2","number":2,"title":"Valid candidate","state":"open","html_url":"https://github.com/github/triage/issues/2","created_at":"1970-01-01T00:16:40Z","updated_at":"1970-01-01T00:33:20Z","closed_at":null,"repository_url":"https://api.github.com/repos/github/triage"},{"id":3,"node_id":"I_3","number":3,"title":"Invalid candidate","state":"unsupported","html_url":"https://github.com/github/triage/issues/3","created_at":"1970-01-01T00:16:40Z","updated_at":"1970-01-01T00:33:20Z","closed_at":null,"repository_url":"https://api.github.com/repos/github/triage"}]}
            """.utf8
        )
        let mixedClient = GitHubIssueSearchClient(
            client: GitHubRESTClient(
                transport: try GitHubRESTTransport(
                    session: RoleSearchSession(body: mixedPayload, eTag: "\"mixed-page\"")
                ),
                credential: SecretValue("token")
            )
        )
        let normalizationRecorder = RoleOutcomeRecorder()
        do {
            _ = try await RoleDiscoverySynchronizer(
                searchClient: mixedClient,
                workItemRepository: WorkItemRepository(vault: vault),
                shardRepository: SyncShardRepository(vault: vault),
                replayRepository: replayRepository,
                clock: { observedAt.addingTimeInterval(4) }
            ).synchronize(
                plan: plan,
                scope: synchronizationScope,
                githubOrganizationID: organization.githubOrganizationID,
                streamID: parentStreamID,
                searchRange: range,
                accessibleRepositoryNames: ["github/triage"],
                repositoryID: { _ in repositoryID },
                streams: [stream],
                recordStreamOutcome: { stream, outcome in
                    await normalizationRecorder.record(stream: stream.kind, outcome: outcome)
                }
            )
            XCTFail("A per-item normalization failure must leave the stream incomplete.")
        } catch let error as SearchShardExecutorError {
            XCTAssertEqual(error, .normalizationFailure)
        }

        let normalizationOutcomes = await normalizationRecorder.outcomes()
        XCTAssertEqual(normalizationOutcomes.map(\.outcome.status), [.failed])
        let mixedSnapshots = try await RawAPISnapshotRepository(vault: vault).snapshots(for: accountID)
        let mixedSnapshot = try XCTUnwrap(mixedSnapshots.first { $0.payload == mixedPayload })
        let mixedFailures = try await NormalizationFailureRepository(vault: vault).failures(for: accountID)
        XCTAssertTrue(mixedFailures.contains { $0.rawSnapshotID == mixedSnapshot.id })
        let invalidatedReplay = try await replayRepository.entry(
            requestKey: replayIdentity.requestKey,
            streamID: roleStreamID,
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision
        )
        XCTAssertNil(invalidatedReplay)
        let mixedShards = try await SyncShardRepository(vault: vault).shards(
            for: roleStreamID,
            accountID: accountID
        )
        XCTAssertEqual(mixedShards.map(\.state), [.failed])
        XCTAssertNil(mixedShards.first?.pageCursor)
        let mixedItems = try await WorkItemRepository(vault: vault).fetch(
            accountID: accountID,
            organizationID: organizationID
        )
        XCTAssertEqual(
            Set(mixedItems.map(\.primaryNodeID)),
            Set([GitHubNodeID(rawValue: "I_1")!, GitHubNodeID(rawValue: "I_2")!])
        )
    }
}

private func insertRoleDiscoveryRepository(
    into vault: AccountVault,
    organizationID: OrganizationID,
    repositoryID: RepositoryID,
    observedAt: Date
) async throws {
    let milliseconds = Int64((observedAt.timeIntervalSince1970 * 1_000).rounded())
    try await vault.write { database in
        try database.execute(
            sql: """
                INSERT INTO repositories (
                    id, organization_id, github_repository_id, github_node_id, owner_login, name,
                    is_private, is_archived, has_discussions, html_url, updated_at_ms, archived_at_ms
                ) VALUES (?, ?, '3', 'R_1', 'github', 'triage', 1, 0, 0, ?, ?, NULL)
                """,
            arguments: [
                repositoryID.rawValue,
                organizationID.rawValue,
                "https://github.com/github/triage",
                milliseconds
            ]
        )
    }
}

private struct RoleSearchRequestValidators: Equatable, Sendable {
    let eTag: String?
    let lastModified: String?
}

private actor RoleSearchSession: HTTPSession {
    let body: Data
    let eTag: String?
    let lastModified: String?
    let returnsNotModifiedForMatchingETag: Bool
    private var recordedValidators = [RoleSearchRequestValidators]()
    private var notModifiedSSOHeader: String?

    init(
        body: Data,
        eTag: String? = nil,
        lastModified: String? = nil,
        returnsNotModifiedForMatchingETag: Bool = false
    ) {
        self.body = body
        self.eTag = eTag
        self.lastModified = lastModified
        self.returnsNotModifiedForMatchingETag = returnsNotModifiedForMatchingETag
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let validators = RoleSearchRequestValidators(
            eTag: request.value(forHTTPHeaderField: "If-None-Match"),
            lastModified: request.value(forHTTPHeaderField: "If-Modified-Since")
        )
        recordedValidators.append(validators)
        let isNotModified = returnsNotModifiedForMatchingETag && validators.eTag == eTag
        var headers = eTag.map { ["ETag": $0] } ?? [:]
        if let lastModified {
            headers["Last-Modified"] = lastModified
        }
        if isNotModified, let notModifiedSSOHeader {
            headers["X-GitHub-SSO"] = notModifiedSSOHeader
        }
        return (
            isNotModified ? Data() : body,
            HTTPURLResponse(
                url: request.url!,
                statusCode: isNotModified ? 304 : 200,
                httpVersion: nil,
                headerFields: headers
            )!
        )
    }

    func validators() -> [RoleSearchRequestValidators] {
        recordedValidators
    }

    func setNotModifiedSSOHeader(_ value: String?) {
        notModifiedSSOHeader = value
    }
}

private actor RoleIsolationSearchClient: GitHubIssueSearchExecuting {
    private var relationships = [GitHubIssueSearchRelationship]()

    func searchResult(
        _ query: GitHubIssueSearchQuery,
        page _: Int,
        validators _: GitHubHTTPValidators?
    ) async throws -> GitHubIssueSearchResult {
        relationships.append(query.relationship)
        if case .assigned = query.relationship {
            throw GitHubFailure(kind: .notFound, statusCode: 404)
        }
        return .response(GitHubResponse(
            value: GitHubIssueSearchPage(
                totalCount: 0,
                incompleteResults: false,
                items: []
            ),
            payload: Data(#"{"total_count":0,"incomplete_results":false,"items":[]}"#.utf8),
            etag: nil,
            lastModified: nil,
            ssoHeader: nil
        ))
    }

    func requestedRelationships() -> [GitHubIssueSearchRelationship] {
        relationships
    }
}

private actor RoleOutcomeRecorder {
    struct Entry: Sendable {
        let stream: RoleDiscoveryStreamKind
        let outcome: RoleDiscoveryStreamOutcome
    }

    private var entries = [Entry]()

    func record(stream: RoleDiscoveryStreamKind, outcome: RoleDiscoveryStreamOutcome) {
        entries.append(Entry(stream: stream, outcome: outcome))
    }

    func outcomes() -> [Entry] {
        entries
    }
}
