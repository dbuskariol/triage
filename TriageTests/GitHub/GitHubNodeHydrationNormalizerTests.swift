import XCTest
@testable import Triage

final class GitHubNodeHydrationNormalizerTests: XCTestCase {
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

        do {
            try await service.hydrate(
                nodeIDs: [GitHubNodeID(rawValue: "I_1")!],
                accountID: accountID,
                organizationID: OrganizationID(rawValue: "org-1")!,
                repositoryID: { _ in nil }
            )
            XCTFail("Expected the partial GraphQL response to remain non-authoritative.")
        } catch {
            XCTAssertEqual(error as? GitHubGraphQLError, .partialResponse)
        }

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
            try await service.hydrate(
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

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}

private actor HydrationGraphQLSession: HTTPSession {
    let body: Data
    let cancelBeforeReturn: Bool

    init(body: Data, cancelBeforeReturn: Bool = false) {
        self.body = body
        self.cancelBeforeReturn = cancelBeforeReturn
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
                headerFields: nil
            )!
        )
    }
}
