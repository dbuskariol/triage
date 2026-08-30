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
            accountID: accountID,
            organizationID: organizationID,
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
            accountID: accountID,
            organizationID: OrganizationID(rawValue: "org-1")!,
            repositoryID: { _ in nil }
        )
        XCTAssertEqual(result.outcomes.map(\.status), [.partialGraphQL([.unknown])])
        XCTAssertFalse(result.isComplete)

        let snapshots = try await RawAPISnapshotRepository(vault: vault).snapshots(for: accountID)
        let snapshot = try XCTUnwrap(snapshots.only)
        XCTAssertTrue(snapshot.payload.contains(Data(secret.utf8)))
        let failures = try await NormalizationFailureRepository(vault: vault).failures(for: accountID)
        let failure = try XCTUnwrap(failures.only)
        XCTAssertEqual(failure.rawSnapshotID, snapshot.id)
        XCTAssertEqual(failure.endpoint, "graphql:TriageHydrateNodes")
        XCTAssertFalse(failure.redactedDiagnostic.contains(secret))
        XCTAssertFalse(failure.redactedDiagnostic.contains("ghp_"))
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
                accountID: accountID,
                organizationID: OrganizationID(rawValue: "org-1")!,
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

    private func payload(node: GitHubNodeHydrationPayload.Node) -> GitHubNodeHydrationPayload {
        GitHubNodeHydrationPayload(
            nodes: [node],
            rateLimit: .init(cost: 12, remaining: 488, resetAt: Date())
        )
    }

    private func pullRequest(
        createdAt: Date = Date(timeIntervalSince1970: 1_000),
        updatedAt: Date = Date(timeIntervalSince1970: 2_000)
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
            assignees: .init(nodes: [], pageInfo: .init(hasNextPage: false)),
            labels: .init(nodes: [], pageInfo: .init(hasNextPage: false)),
            reviewRequests: nil,
            closingIssuesReferences: nil
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

    init(
        body: Data,
        cancelBeforeReturn: Bool = false,
        headerFields: [String: String]? = nil
    ) {
        self.body = body
        self.cancelBeforeReturn = cancelBeforeReturn
        self.headerFields = headerFields
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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
