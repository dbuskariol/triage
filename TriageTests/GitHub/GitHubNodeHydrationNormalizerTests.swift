import GRDB
import XCTest
@testable import Triage

final class GitHubNodeHydrationNormalizerTests: XCTestCase {
    func testCoverageAssessmentKeepsKindsAndRepositoriesIndependent() {
        let repositoryOne = RepositoryID(rawValue: "repo-1")!
        let repositoryTwo = RepositoryID(rawValue: "repo-2")!
        let result = GitHubNodeHydrationRefreshResult(outcomes: [
            .init(
                candidate: .init(
                    nodeID: GitHubNodeID(rawValue: "I_1")!,
                    repositoryID: repositoryOne,
                    kind: .issue
                ),
                status: .refreshed
            ),
            .init(
                candidate: .init(
                    nodeID: GitHubNodeID(rawValue: "I_2")!,
                    repositoryID: repositoryTwo,
                    kind: .issue
                ),
                status: .refreshed
            ),
            .init(
                candidate: .init(
                    nodeID: GitHubNodeID(rawValue: "PR_1")!,
                    repositoryID: repositoryOne,
                    kind: .pullRequest
                ),
                status: .refreshed
            ),
            .init(
                candidate: .init(
                    nodeID: GitHubNodeID(rawValue: "PR_2")!,
                    repositoryID: repositoryTwo,
                    kind: .pullRequest
                ),
                status: .rateLimited(retryAt: Date(timeIntervalSince1970: 3_000))
            )
        ])

        XCTAssertEqual(result.coverageAssessment(kind: .issue).status, .complete)
        XCTAssertEqual(result.coverageAssessment(kind: .pullRequest).status, .partial)
        XCTAssertEqual(
            result.coverageAssessment(repositoryID: repositoryOne, kind: .pullRequest).status,
            .complete
        )
        XCTAssertEqual(
            result.coverageAssessment(repositoryID: repositoryTwo, kind: .pullRequest).status,
            .partial
        )
        XCTAssertFalse(result.isComplete)

        let empty = GitHubNodeHydrationRefreshResult(outcomes: [])
        XCTAssertTrue(empty.isComplete)
        XCTAssertEqual(empty.coverageAssessment(kind: .issue).status, .complete)
        XCTAssertEqual(empty.coverageAssessment(kind: .pullRequest).status, .complete)
    }

    func testCommittedQueryRejectionIsUnavailableAndCannotProduceCompleteCoverage() {
        let status = GitHubNodeHydrationService.status(
            for: .unregisteredQuery,
            githubOrganizationID: nil,
            observedAt: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(status, .unavailableOrPermission)

        let candidate = GitHubHydrationCandidate(
            nodeID: GitHubNodeID(rawValue: "I_1")!,
            repositoryID: RepositoryID(rawValue: "repo-1")!,
            kind: .issue
        )
        let result = GitHubNodeHydrationRefreshResult(outcomes: [
            .init(candidate: candidate, status: status)
        ])
        XCTAssertEqual(result.coverageAssessment(kind: .issue).status, .unavailable)
        XCTAssertFalse(result.isComplete)
    }

    func testResponseAuthorityRejectionFailsAndCannotProduceCompleteCoverage() {
        let status = GitHubNodeHydrationService.status(
            for: .invalidResponseAuthority,
            githubOrganizationID: nil,
            observedAt: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(status, .failed)

        let candidate = GitHubHydrationCandidate(
            nodeID: GitHubNodeID(rawValue: "I_1")!,
            repositoryID: RepositoryID(rawValue: "repo-1")!,
            kind: .issue
        )
        let result = GitHubNodeHydrationRefreshResult(outcomes: [
            .init(candidate: candidate, status: status)
        ])
        XCTAssertEqual(result.coverageAssessment(kind: .issue).status, .failed)
        XCTAssertFalse(result.isComplete)
    }

    func testUndecodableHydrationPreservesRawAndClassifiesTypedGraphQLError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".hydration-undecodable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: "org-1")!
        let observedAt = Date(timeIntervalSince1970: 2_000)
        let vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        try await AccountRepository(vault: vault).save(
            GitHubAccount(
                id: accountID,
                githubUserID: 1,
                nodeID: GitHubNodeID(rawValue: "U_1")!,
                login: "octocat",
                authenticationKind: .oauth,
                credentialID: CredentialID.make(),
                credentialStatus: .active,
                createdAt: observedAt
            ),
            credentialRevision: CredentialRevision(rawValue: "credential-1")!
        )
        try await insertHydrationCandidate(
            into: vault,
            accountID: accountID,
            organizationID: organizationID,
            observedAt: observedAt
        )
        let secret = "ghp_undecodableHydrationSecret"
        let body = Data(
            """
            {"data":{"nodes":"invalid"},"errors":[{"message":"\(secret)","path":["nodes",0],"extensions":{"code":"RATE_LIMITED"}}]}
            """.utf8
        )
        let service = GitHubNodeHydrationService(
            client: GitHubGraphQLClient(
                session: HydrationGraphQLSession(
                    body: body,
                    headerFields: ["Retry-After": "15"]
                ),
                credential: SecretValue("token")
            ),
            detailsRepository: GitHubNodeDetailsRepository(vault: vault),
            rawSnapshotRepository: RawAPISnapshotRepository(vault: vault),
            normalizationFailureRepository: NormalizationFailureRepository(vault: vault),
            batchMetricRepository: GitHubHydrationBatchMetricRepository(vault: vault),
            clock: { observedAt }
        )

        let result = try await service.hydrate(
            nodeIDs: [GitHubNodeID(rawValue: "I_1")!],
            scope: hydrationScope(accountID: accountID, organizationID: organizationID),
            repositoryID: { _ in nil }
        )

        XCTAssertEqual(
            result.outcomes.map(\.status),
            [.rateLimited(retryAt: observedAt.addingTimeInterval(15))]
        )
        XCTAssertFalse(result.isComplete)
        let snapshots = try await RawAPISnapshotRepository(vault: vault).snapshots(for: accountID)
        let snapshot = try XCTUnwrap(snapshots.only)
        XCTAssertEqual(snapshot.payload, body)
        let failures = try await NormalizationFailureRepository(vault: vault).failures(for: accountID)
        let failure = try XCTUnwrap(failures.only)
        XCTAssertEqual(failure.rawSnapshotID, snapshot.id)
        XCTAssertFalse(failure.redactedDiagnostic.contains(secret))
    }

    func testHydrationPartialResponseRetainsRawProvenanceWithRedactedDiagnostic() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".hydration-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountID = AccountID.make()
        let observedAt = Date(timeIntervalSince1970: 2_000)
        let vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        try await AccountRepository(vault: vault).save(
            GitHubAccount(
                id: accountID,
                githubUserID: 1,
                nodeID: GitHubNodeID(rawValue: "U_1")!,
                login: "octocat",
                authenticationKind: .oauth,
                credentialID: CredentialID.make(),
                credentialStatus: .active,
                createdAt: observedAt
            ),
            credentialRevision: CredentialRevision(rawValue: "credential-1")!
        )
        try await insertHydrationCandidate(
            into: vault,
            accountID: accountID,
            organizationID: OrganizationID(rawValue: "org-1")!,
            observedAt: observedAt
        )
        let secret = "ghp_hydrationPartialSecret"
        let service = GitHubNodeHydrationService(
            client: GitHubGraphQLClient(
                session: HydrationGraphQLSession(
                    body: Data("{\"data\":null,\"errors\":[{\"message\":\"\(secret)\"}]}".utf8)
                ),
                credential: SecretValue("token")
            ),
            detailsRepository: GitHubNodeDetailsRepository(vault: vault),
            rawSnapshotRepository: RawAPISnapshotRepository(vault: vault),
            normalizationFailureRepository: NormalizationFailureRepository(vault: vault),
            batchMetricRepository: GitHubHydrationBatchMetricRepository(vault: vault),
            clock: { observedAt }
        )

        let result = try await service.hydrate(
            nodeIDs: [GitHubNodeID(rawValue: "I_1")!],
            scope: hydrationScope(
                accountID: accountID,
                organizationID: OrganizationID(rawValue: "org-1")!
            ),
            repositoryID: { _ in nil }
        )
        XCTAssertEqual(result.outcomes.map(\.status), [.partialGraphQL([.unknown])])
        XCTAssertFalse(result.isComplete)

        let snapshots = try await RawAPISnapshotRepository(vault: vault).snapshots(for: accountID)
        let snapshot = try XCTUnwrap(snapshots.only)
        XCTAssertTrue(snapshot.payload.contains(Data(secret.utf8)))
        XCTAssertEqual(snapshot.githubNodeID, GitHubNodeID(rawValue: "I_1"))
        XCTAssertEqual(
            snapshot.requestIdentity,
            ConditionalRequestIdentity(
                scope: hydrationScope(
                    accountID: accountID,
                    organizationID: OrganizationID(rawValue: "org-1")!
                ),
                feature: .issues,
                streamID: SyncStreamID(rawValue: "hydration-issues-org-1")!,
                requestKey: "graphql:TriageHydrateNodes/node=I_1"
            )
        )
        let failures = try await NormalizationFailureRepository(vault: vault).failures(for: accountID)
        let failure = try XCTUnwrap(failures.only)
        XCTAssertEqual(failure.rawSnapshotID, snapshot.id)
        XCTAssertEqual(failure.endpoint, "graphql:TriageHydrateNodes")
        XCTAssertFalse(failure.redactedDiagnostic.contains(secret))
        XCTAssertFalse(failure.redactedDiagnostic.contains("ghp_"))
    }

    func testNegativeQueryCostIsIncompleteBeforeMetricsOrPlannerAndPreservesPriorData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".hydration-negative-cost-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: "org-1")!
        let observedAt = Date(timeIntervalSince1970: 2_000)
        let vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        try await AccountRepository(vault: vault).save(
            GitHubAccount(
                id: accountID,
                githubUserID: 1,
                nodeID: GitHubNodeID(rawValue: "U_1")!,
                login: "octocat",
                authenticationKind: .oauth,
                credentialID: CredentialID.make(),
                credentialStatus: .active,
                createdAt: observedAt
            ),
            credentialRevision: CredentialRevision(rawValue: "credential-1")!
        )
        try await insertHydrationCandidate(
            into: vault,
            accountID: accountID,
            organizationID: organizationID,
            observedAt: observedAt
        )
        let service = GitHubNodeHydrationService(
            client: GitHubGraphQLClient(
                session: HydrationGraphQLSession(
                    body: Data(#"{"data":{"nodes":[],"rateLimit":{"cost":-1,"remaining":4999,"resetAt":"2026-01-02T00:00:00Z"}}}"#.utf8)
                ),
                credential: SecretValue("token")
            ),
            detailsRepository: GitHubNodeDetailsRepository(vault: vault),
            rawSnapshotRepository: RawAPISnapshotRepository(vault: vault),
            normalizationFailureRepository: NormalizationFailureRepository(vault: vault),
            batchMetricRepository: GitHubHydrationBatchMetricRepository(vault: vault),
            clock: { observedAt }
        )

        let result = try await service.hydrate(
            nodeIDs: [GitHubNodeID(rawValue: "I_1")!],
            scope: hydrationScope(accountID: accountID, organizationID: organizationID),
            repositoryID: { _ in nil }
        )

        XCTAssertEqual(result.outcomes.map(\.status), [.queryCostExceeded])
        XCTAssertFalse(result.isComplete)
        let durable = try await hydrationDurableState(in: vault)
        XCTAssertEqual(durable.batchMetrics, 0)
        XCTAssertEqual(durable.sourceRevision, "search-revision")
        XCTAssertEqual(durable.rawSnapshots, 1)
    }

    func testHydrationCancellationAfterResponseDoesNotPublishRawOrFailureState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".hydration-cancellation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountID = AccountID.make()
        let observedAt = Date(timeIntervalSince1970: 2_000)
        let vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        try await AccountRepository(vault: vault).save(
            GitHubAccount(
                id: accountID,
                githubUserID: 1,
                nodeID: GitHubNodeID(rawValue: "U_1")!,
                login: "octocat",
                authenticationKind: .oauth,
                credentialID: CredentialID.make(),
                credentialStatus: .active,
                createdAt: observedAt
            ),
            credentialRevision: CredentialRevision(rawValue: "credential-1")!
        )
        try await insertHydrationCandidate(
            into: vault,
            accountID: accountID,
            organizationID: OrganizationID(rawValue: "org-1")!,
            observedAt: observedAt
        )
        let service = GitHubNodeHydrationService(
            client: GitHubGraphQLClient(
                session: HydrationGraphQLSession(
                    body: Data(#"{"data":null,"errors":[{"message":"partial"}]}"#.utf8),
                    cancelBeforeReturn: true
                ),
                credential: SecretValue("token")
            ),
            detailsRepository: GitHubNodeDetailsRepository(vault: vault),
            rawSnapshotRepository: RawAPISnapshotRepository(vault: vault),
            normalizationFailureRepository: NormalizationFailureRepository(vault: vault),
            batchMetricRepository: GitHubHydrationBatchMetricRepository(vault: vault),
            clock: { observedAt }
        )

        do {
            _ = try await service.hydrate(
                nodeIDs: [GitHubNodeID(rawValue: "I_1")!],
                scope: hydrationScope(
                    accountID: accountID,
                    organizationID: OrganizationID(rawValue: "org-1")!
                ),
                repositoryID: { _ in nil }
            )
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
        }

        let snapshots = try await RawAPISnapshotRepository(vault: vault).snapshots(for: accountID)
        let failures = try await NormalizationFailureRepository(vault: vault).failures(for: accountID)
        XCTAssertTrue(snapshots.isEmpty)
        XCTAssertTrue(failures.isEmpty)
    }

    func testCredentialRotationDuringHydrationResponseCancelsWithoutPostGateWrites() async throws {
        try await assertScopeRotationDuringHydration(.credential)
    }

    func testCapabilityRotationDuringHydrationResponseCancelsWithoutPostGateWrites() async throws {
        try await assertScopeRotationDuringHydration(.capability)
    }

    private func assertScopeRotationDuringHydration(_ rotation: HydrationScopeRotation) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".hydration-scope-rotation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: "org-1")!
        let observedAt = Date(timeIntervalSince1970: 2_000)
        let vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        try await AccountRepository(vault: vault).save(
            GitHubAccount(
                id: accountID,
                githubUserID: 1,
                nodeID: GitHubNodeID(rawValue: "U_1")!,
                login: "octocat",
                authenticationKind: .oauth,
                credentialID: CredentialID.make(),
                credentialStatus: .active,
                createdAt: observedAt
            ),
            credentialRevision: CredentialRevision(rawValue: "credential-1")!
        )
        try await insertHydrationCandidate(
            into: vault,
            accountID: accountID,
            organizationID: organizationID,
            observedAt: observedAt
        )
        let gate = HydrationResponseGate()
        let service = GitHubNodeHydrationService(
            client: GitHubGraphQLClient(
                session: HydrationGraphQLSession(
                    body: Data(#"{"data":null,"errors":[{"message":"partial"}]}"#.utf8),
                    gate: gate
                ),
                credential: SecretValue("token")
            ),
            detailsRepository: GitHubNodeDetailsRepository(vault: vault),
            rawSnapshotRepository: RawAPISnapshotRepository(vault: vault),
            normalizationFailureRepository: NormalizationFailureRepository(vault: vault),
            batchMetricRepository: GitHubHydrationBatchMetricRepository(vault: vault),
            clock: { observedAt }
        )
        let task = Task {
            try await service.hydrate(
                nodeIDs: [GitHubNodeID(rawValue: "I_1")!],
                scope: hydrationScope(accountID: accountID, organizationID: organizationID),
                repositoryID: { _ in RepositoryID(rawValue: "repo-1")! }
            )
        }

        await gate.waitUntilEntered()
        let before = try await hydrationDurableState(in: vault)
        try await vault.write { database in
            switch rotation {
            case .credential:
                try database.execute(
                    sql: "UPDATE accounts SET credential_revision = 'credential-2' WHERE id = ?",
                    arguments: [accountID.rawValue]
                )
            case .capability:
                try database.execute(
                    sql: """
                        UPDATE account_organizations
                        SET capability_revision = 'capability-2'
                        WHERE account_id = ? AND organization_id = ?
                    """,
                    arguments: [accountID.rawValue, organizationID.rawValue]
                )
            }
        }
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("Expected scope rotation to cancel hydration.")
        } catch is CancellationError {
            // Expected supersession.
        }
        let after = try await hydrationDurableState(in: vault)
        XCTAssertEqual(after, before)
    }

    func testNormalizesMergedPullRequestWithAuthoritativeFields() throws {
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let updatedAt = Date(timeIntervalSince1970: 2_000)
        let node = try GitHubNodeHydrationNormalizer.normalize(
            payload(node: pullRequest(createdAt: createdAt, updatedAt: updatedAt)),
            requestedNodeIDs: [GitHubNodeID(rawValue: "PR_1")!],
            accountID: AccountID(rawValue: "account")!,
            organizationID: OrganizationID(rawValue: "organization")!,
            repositoryID: { _ in RepositoryID(rawValue: "repository")! },
            observedAt: updatedAt
        ).only!

        XCTAssertEqual(node.kind, .pullRequest)
        XCTAssertEqual(node.state, .merged)
        XCTAssertEqual(node.numericID, "42")
        XCTAssertEqual(node.authorID, ActorID(rawValue: "USER_1"))
        XCTAssertEqual(node.bodyMarkdown, "Authoritative body")
        XCTAssertEqual(node.sourceRevision, updatedAt.ISO8601Format())
    }

    func testRejectsMissingRequestedNode() throws {
        XCTAssertThrowsError(
            try GitHubNodeHydrationNormalizer.normalize(
                payload(node: pullRequest()),
                requestedNodeIDs: [GitHubNodeID(rawValue: "PR_1")!, GitHubNodeID(rawValue: "PR_2")!],
                accountID: AccountID(rawValue: "account")!,
                organizationID: OrganizationID(rawValue: "organization")!,
                repositoryID: { _ in RepositoryID(rawValue: "repository")! },
                observedAt: Date()
            )
        ) { error in
            XCTAssertEqual(error as? GitHubNodeHydrationNormalizationError, .missingRequestedNode("PR_2"))
        }
    }

    func testRejectsIncompletePullRequestReviewRequests() throws {
        var node = pullRequest()
        node = .init(
            typeName: node.typeName,
            id: node.id,
            databaseId: node.databaseId,
            number: node.number,
            title: node.title,
            body: node.body,
            url: node.url,
            state: node.state,
            createdAt: node.createdAt,
            updatedAt: node.updatedAt,
            closedAt: node.closedAt,
            mergedAt: node.mergedAt,
            isDraft: node.isDraft,
            locked: node.locked,
            comments: node.comments,
            mergeable: node.mergeable,
            headRefName: node.headRefName,
            baseRefName: node.baseRefName,
            reviewDecision: node.reviewDecision,
            author: node.author,
            repository: node.repository,
            assignees: node.assignees,
            labels: node.labels,
            reviewRequests: .init(nodes: [], pageInfo: .init(hasNextPage: true)),
            closingIssuesReferences: node.closingIssuesReferences
        )

        XCTAssertThrowsError(
            try GitHubNodeHydrationNormalizer.normalize(
                payload(node: node),
                requestedNodeIDs: [GitHubNodeID(rawValue: "PR_1")!],
                accountID: AccountID(rawValue: "account")!,
                organizationID: OrganizationID(rawValue: "organization")!,
                repositoryID: { _ in RepositoryID(rawValue: "repository")! },
                observedAt: Date()
            )
        ) { error in
            XCTAssertEqual(error as? GitHubNodeHydrationNormalizationError, .incompleteConnection)
        }
    }

    func testRejectsIncompleteClosingIssues() throws {
        let original = pullRequest()
        let node = GitHubNodeHydrationPayload.Node(
            typeName: original.typeName,
            id: original.id,
            databaseId: original.databaseId,
            number: original.number,
            title: original.title,
            body: original.body,
            url: original.url,
            state: original.state,
            createdAt: original.createdAt,
            updatedAt: original.updatedAt,
            closedAt: original.closedAt,
            mergedAt: original.mergedAt,
            isDraft: original.isDraft,
            locked: original.locked,
            comments: original.comments,
            mergeable: original.mergeable,
            headRefName: original.headRefName,
            baseRefName: original.baseRefName,
            reviewDecision: original.reviewDecision,
            author: original.author,
            repository: original.repository,
            assignees: original.assignees,
            labels: original.labels,
            reviewRequests: original.reviewRequests,
            closingIssuesReferences: .init(nodes: [], pageInfo: .init(hasNextPage: true))
        )

        XCTAssertThrowsError(
            try GitHubNodeHydrationNormalizer.normalize(
                payload(node: node),
                requestedNodeIDs: [GitHubNodeID(rawValue: "PR_1")!],
                accountID: AccountID(rawValue: "account")!,
                organizationID: OrganizationID(rawValue: "organization")!,
                repositoryID: { _ in RepositoryID(rawValue: "repository")! },
                observedAt: Date()
            )
        ) { error in
            XCTAssertEqual(error as? GitHubNodeHydrationNormalizationError, .incompleteConnection)
        }
    }

    func testIncompleteLabelsFailNormalizationAndCannotProduceCompleteCoverage() throws {
        XCTAssertThrowsError(
            try GitHubNodeHydrationNormalizer.normalize(
                payload(node: pullRequest(labelsHasNextPage: true)),
                requestedNodeIDs: [GitHubNodeID(rawValue: "PR_1")!],
                accountID: AccountID(rawValue: "account")!,
                organizationID: OrganizationID(rawValue: "organization")!,
                repositoryID: { _ in RepositoryID(rawValue: "repository")! },
                observedAt: Date()
            )
        ) { error in
            XCTAssertEqual(error as? GitHubNodeHydrationNormalizationError, .incompleteConnection)
        }

        let candidate = GitHubHydrationCandidate(
            nodeID: GitHubNodeID(rawValue: "PR_1")!,
            repositoryID: RepositoryID(rawValue: "repository")!,
            kind: .pullRequest
        )
        let result = GitHubNodeHydrationRefreshResult(outcomes: [
            .init(candidate: candidate, status: .normalizationFailed)
        ])
        XCTAssertEqual(result.coverageAssessment(kind: .pullRequest).status, .partial)
        XCTAssertFalse(result.isComplete)
    }

    func testNullLabelNodeFailsNormalizationInsteadOfBeingOmitted() throws {
        XCTAssertThrowsError(
            try GitHubNodeHydrationNormalizer.normalize(
                payload(node: pullRequest(containsNilLabel: true)),
                requestedNodeIDs: [GitHubNodeID(rawValue: "PR_1")!],
                accountID: AccountID(rawValue: "account")!,
                organizationID: OrganizationID(rawValue: "organization")!,
                repositoryID: { _ in RepositoryID(rawValue: "repository")! },
                observedAt: Date()
            )
        ) { error in
            XCTAssertEqual(error as? GitHubNodeHydrationNormalizationError, .incompleteConnection)
        }
    }

    func testNestedConnectionsRejectMoreThanFiftyDecodedObjects() throws {
        let actors = (1 ... 51).map { GitHubNodeHydrationPayload.Actor(id: "U_\($0)", login: "user\($0)", avatarUrl: nil) as GitHubNodeHydrationPayload.Actor? }
        let labels = (1 ... 51).map { GitHubNodeHydrationPayload.Label(id: "L_\($0)", name: "label-\($0)", color: "000000") as GitHubNodeHydrationPayload.Label? }
        let reviewRequests = (1 ... 51).map { GitHubNodeHydrationPayload.ReviewRequest(requestedReviewer: .init(id: "RR_\($0)", login: "reviewer\($0)", slug: nil, avatarUrl: nil)) as GitHubNodeHydrationPayload.ReviewRequest? }
        let closingReferences = (1 ... 51).map { GitHubNodeHydrationPayload.NodeReference(id: "I_CLOSE_\($0)") as GitHubNodeHydrationPayload.NodeReference? }
        let nodes = [
            pullRequest(assigneeNodes: actors),
            pullRequest(labelNodes: labels),
            pullRequest(reviewRequestNodes: reviewRequests),
            pullRequest(closingReferenceNodes: closingReferences)
        ]
        for node in nodes {
            XCTAssertThrowsError(
                try GitHubNodeHydrationNormalizer.normalize(
                    payload(node: node),
                    requestedNodeIDs: [GitHubNodeID(rawValue: "PR_1")!],
                    accountID: AccountID(rawValue: "account")!,
                    organizationID: OrganizationID(rawValue: "organization")!,
                    repositoryID: { _ in RepositoryID(rawValue: "repository")! },
                    observedAt: Date()
                )
            ) { error in
                XCTAssertEqual(error as? GitHubNodeHydrationNormalizationError, .incompleteConnection)
            }
        }
    }

    func testNestedConnectionsRejectDuplicateDecodedObjects() throws {
        let duplicateActor = GitHubNodeHydrationPayload.Actor(id: "U_1", login: "user", avatarUrl: nil) as GitHubNodeHydrationPayload.Actor?
        let duplicateLabel = GitHubNodeHydrationPayload.Label(id: "L_1", name: "label", color: "000000") as GitHubNodeHydrationPayload.Label?
        let duplicateRequest = GitHubNodeHydrationPayload.ReviewRequest(requestedReviewer: .init(id: "RR_1", login: "reviewer", slug: nil, avatarUrl: nil)) as GitHubNodeHydrationPayload.ReviewRequest?
        let duplicateReference = GitHubNodeHydrationPayload.NodeReference(id: "I_CLOSE_1") as GitHubNodeHydrationPayload.NodeReference?
        let nodes = [
            pullRequest(assigneeNodes: [duplicateActor, duplicateActor]),
            pullRequest(labelNodes: [duplicateLabel, duplicateLabel]),
            pullRequest(reviewRequestNodes: [duplicateRequest, duplicateRequest]),
            pullRequest(closingReferenceNodes: [duplicateReference, duplicateReference])
        ]
        for node in nodes {
            XCTAssertThrowsError(
                try GitHubNodeHydrationNormalizer.normalize(
                    payload(node: node),
                    requestedNodeIDs: [GitHubNodeID(rawValue: "PR_1")!],
                    accountID: AccountID(rawValue: "account")!,
                    organizationID: OrganizationID(rawValue: "organization")!,
                    repositoryID: { _ in RepositoryID(rawValue: "repository")! },
                    observedAt: Date()
                )
            ) { error in
                XCTAssertEqual(error as? GitHubNodeHydrationNormalizationError, .duplicateRelatedNodeID)
            }
        }
    }

    private func payload(node: GitHubNodeHydrationPayload.Node) -> GitHubNodeHydrationPayload {
        GitHubNodeHydrationPayload(
            nodes: [node],
            rateLimit: .init(cost: 12, remaining: 488, resetAt: Date())
        )
    }

    private func pullRequest(
        createdAt: Date = Date(timeIntervalSince1970: 1_000),
        updatedAt: Date = Date(timeIntervalSince1970: 2_000),
        labelsHasNextPage: Bool = false,
        containsNilLabel: Bool = false,
        assigneeNodes: [GitHubNodeHydrationPayload.Actor?] = [],
        labelNodes: [GitHubNodeHydrationPayload.Label?]? = nil,
        reviewRequestNodes: [GitHubNodeHydrationPayload.ReviewRequest?]? = nil,
        closingReferenceNodes: [GitHubNodeHydrationPayload.NodeReference?]? = nil
    ) -> GitHubNodeHydrationPayload.Node {
        .init(
            typeName: "PullRequest",
            id: "PR_1",
            databaseId: 42,
            number: 42,
            title: "Add hydration",
            body: "Authoritative body",
            url: URL(string: "https://github.com/octo/triage/pull/42")!,
            state: "MERGED",
            createdAt: createdAt,
            updatedAt: updatedAt,
            closedAt: updatedAt,
            mergedAt: updatedAt,
            isDraft: false,
            locked: nil,
            comments: nil,
            mergeable: "MERGEABLE",
            headRefName: "feature",
            baseRefName: "main",
            reviewDecision: "APPROVED",
            author: .init(id: "USER_1", login: "octocat", avatarUrl: nil),
            repository: .init(
                id: "REPO_1",
                nameWithOwner: "octo/triage",
                isPrivate: true,
                isArchived: false,
                hasDiscussions: true,
                url: URL(string: "https://github.com/octo/triage")!
            ),
            assignees: .init(nodes: assigneeNodes, pageInfo: .init(hasNextPage: false)),
            labels: .init(
                nodes: labelNodes ?? (containsNilLabel ? [nil] : []),
                pageInfo: .init(hasNextPage: labelsHasNextPage)
            ),
            reviewRequests: reviewRequestNodes.map { .init(nodes: $0, pageInfo: .init(hasNextPage: false)) },
            closingIssuesReferences: closingReferenceNodes.map { .init(nodes: $0, pageInfo: .init(hasNextPage: false)) }
        )
    }
}

private func hydrationScope(
    accountID: AccountID,
    organizationID: OrganizationID
) -> SynchronizationScope {
    SynchronizationScope(
        accountID: accountID,
        organizationID: organizationID,
        credentialRevision: CredentialRevision(rawValue: "credential-1")!,
        capabilityRevision: CapabilityRevision(rawValue: "capability-1")!
    )
}

private enum HydrationScopeRotation {
    case credential
    case capability
}

private struct HydrationDurableState: Equatable {
    let rawSnapshots: Int
    let normalizationFailures: Int
    let batchMetrics: Int
    let actors: Int
    let issues: Int
    let pullRequests: Int
    let sourceRevision: String?
}

private func hydrationDurableState(in vault: AccountVault) async throws -> HydrationDurableState {
    try await vault.read { database in
        HydrationDurableState(
            rawSnapshots: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")!,
            normalizationFailures: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM normalization_failures")!,
            batchMetrics: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM github_hydration_batch_metrics")!,
            actors: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM actors")!,
            issues: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM issues")!,
            pullRequests: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM pull_requests")!,
            sourceRevision: try String.fetchOne(
                database,
                sql: "SELECT source_revision FROM github_nodes WHERE github_node_id = 'I_1'"
            )
        )
    }
}

private func insertHydrationCandidate(
    into vault: AccountVault,
    accountID: AccountID,
    organizationID: OrganizationID,
    observedAt: Date
) async throws {
    let observedAtMilliseconds = Int64((observedAt.timeIntervalSince1970 * 1_000).rounded())
    try await vault.write { database in
        try database.execute(
            sql: """
                INSERT INTO organizations (
                    id, github_organization_id, github_node_id, login, display_name, avatar_url, updated_at_ms
                ) VALUES (?, '2', 'O_1', 'org-1', NULL, NULL, ?)
                """,
            arguments: [organizationID.rawValue, observedAtMilliseconds]
        )
        try database.execute(
            sql: """
                INSERT INTO account_organizations (
                    account_id, organization_id, access_state, capability_revision, checked_at_ms, selected_at_ms
                ) VALUES (?, ?, 'available', 'capability-1', ?, ?)
                """,
            arguments: [
                accountID.rawValue, organizationID.rawValue,
                observedAtMilliseconds, observedAtMilliseconds
            ]
        )
        try database.execute(
            sql: """
                INSERT INTO repositories (
                    id, organization_id, github_repository_id, github_node_id, owner_login, name,
                    is_private, is_archived, has_discussions, html_url, updated_at_ms, archived_at_ms
                ) VALUES ('repo-1', ?, '3', 'R_1', 'org-1', 'triage', 1, 0, 0, ?, ?, NULL)
                """,
            arguments: [
                organizationID.rawValue,
                "https://github.com/org-1/triage",
                observedAtMilliseconds
            ]
        )
        try database.execute(
            sql: """
                INSERT INTO github_nodes (
                    github_node_id, account_id, organization_id, repository_id, kind, numeric_id, number,
                    title, state, html_url, body_markdown, author_id, created_at_ms, updated_at_ms,
                    closed_at_ms, merged_at_ms, source_revision, last_observed_at_ms, accessibility_state
                ) VALUES ('I_1', ?, ?, 'repo-1', 'issue', '1', 1, 'Candidate', 'open', ?, NULL, NULL,
                          ?, ?, NULL, NULL, 'search-revision', ?, 'accessible')
                """,
            arguments: [
                accountID.rawValue, organizationID.rawValue,
                "https://github.com/org-1/triage/issues/1",
                observedAtMilliseconds, observedAtMilliseconds, observedAtMilliseconds
            ]
        )
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}

private actor HydrationGraphQLSession: HTTPSession {
    let body: Data
    let cancelBeforeReturn: Bool
    let headerFields: [String: String]?
    let gate: HydrationResponseGate?

    init(
        body: Data,
        cancelBeforeReturn: Bool = false,
        headerFields: [String: String]? = nil,
        gate: HydrationResponseGate? = nil
    ) {
        self.body = body
        self.cancelBeforeReturn = cancelBeforeReturn
        self.headerFields = headerFields
        self.gate = gate
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let gate {
            await gate.enterAndWait()
        }
        if cancelBeforeReturn {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return (
            body,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: headerFields
            )!
        )
    }
}

private actor HydrationResponseGate {
    private var entered = false
    private var released = false
    private var enteredWaiters = [CheckedContinuation<Void, Never>]()
    private var releaseWaiters = [CheckedContinuation<Void, Never>]()

    func enterAndWait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
