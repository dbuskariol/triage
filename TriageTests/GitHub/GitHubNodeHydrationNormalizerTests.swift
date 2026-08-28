import XCTest
@testable import Triage

final class GitHubNodeHydrationNormalizerTests: XCTestCase {
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
