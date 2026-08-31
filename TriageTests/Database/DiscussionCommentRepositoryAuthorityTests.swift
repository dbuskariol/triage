import Foundation
import GRDB
import XCTest
@testable import Triage

final class DiscussionCommentRepositoryAuthorityTests: XCTestCase {
    func testMissingRootPageRejectsCompleteReplacementAtomically() async throws {
        let fixture = try await DiscussionCommentAuthorityFixture()
        defer { fixture.remove() }
        let repository = DiscussionCommentRepository(vault: fixture.vault)
        let valid = fixture.inventory(rawPages: fixture.completePages())

        try await fixture.replace(valid, using: repository)
        let before = try await fixture.persistedState()

        await XCTAssertThrowsErrorAsync(
            {
                try await fixture.replace(
                    fixture.inventory(rawPages: []),
                    using: repository,
                    observedAt: fixture.observedAt.addingTimeInterval(60)
                )
            },
            verify: { error in
                XCTAssertEqual(error as? DiscussionCommentRepositoryError, .invalidRawAuthority)
            }
        )

        let after = try await fixture.persistedState()
        XCTAssertEqual(after, before)
    }

    func testMissingReplyTerminalTraversalForReturnedCommentRejectsCompleteReplacement() async throws {
        let fixture = try await DiscussionCommentAuthorityFixture()
        defer { fixture.remove() }
        let repository = DiscussionCommentRepository(vault: fixture.vault)
        let rootOnly = fixture.completePages().filter { $0.source == .comments }

        await XCTAssertThrowsErrorAsync(
            { try await fixture.replace(fixture.inventory(rawPages: rootOnly), using: repository) },
            verify: { error in
                XCTAssertEqual(error as? DiscussionCommentRepositoryError, .invalidRawAuthority)
            }
        )

        let state = try await fixture.persistedState()
        XCTAssertEqual(state, .init(commentBodies: [], rawCount: 0, coverageCount: 0))
    }

    func testEmptyCompleteInventoryRequiresAndAcceptsTerminalRootPage() async throws {
        let fixture = try await DiscussionCommentAuthorityFixture()
        defer { fixture.remove() }
        let repository = DiscussionCommentRepository(vault: fixture.vault)

        await XCTAssertThrowsErrorAsync(
            {
                try await fixture.replace(
                    .init(comments: [], replies: [], rawPages: []),
                    using: repository
                )
            },
            verify: { error in
                XCTAssertEqual(error as? DiscussionCommentRepositoryError, .invalidRawAuthority)
            }
        )

        try await fixture.replace(
            .init(comments: [], replies: [], rawPages: [fixture.rootPage(commentIDs: [])]),
            using: repository
        )
        let state = try await fixture.persistedState()
        XCTAssertEqual(state, .init(commentBodies: [], rawCount: 1, coverageCount: 2))
    }
}

private final class DiscussionCommentAuthorityFixture: @unchecked Sendable {
    struct PersistedState: Equatable {
        let commentBodies: [String]
        let rawCount: Int
        let coverageCount: Int
    }

    let root: URL
    let vault: AccountVault
    let account: GitHubAccount
    let organization: GitHubOrganization
    let repositoryID = RepositoryID(rawValue: "R_1")!
    let discussionNodeID = GitHubNodeID(rawValue: "D_1")!
    let observedAt = Date(timeIntervalSince1970: 1_000)

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".triage-discussion-comment-authority-\(UUID().uuidString)", isDirectory: true)
        let accountID = AccountID.make()
        account = .init(
            id: accountID, githubUserID: 1, nodeID: GitHubNodeID(rawValue: "U_1")!, login: "octocat",
            authenticationKind: .oauth, credentialID: CredentialID.make(), credentialStatus: .active,
            createdAt: observedAt, lastValidatedAt: observedAt
        )
        organization = .init(
            id: OrganizationID(rawValue: "acme")!, githubOrganizationID: 2,
            nodeID: GitHubNodeID(rawValue: "O_2")!, login: "acme"
        )
        vault = try await VaultRegistry(rootDirectory: root).open(
            accountID: accountID,
            vaultKey: VaultKey.generate()
        )
        let accounts = AccountRepository(vault: vault)
        try await accounts.save(account, credentialRevision: CredentialRevision(rawValue: "credential-1")!)
        try await accounts.save(
            organization,
            access: .init(
                accountID: accountID, organizationID: organization.id, state: .available,
                capabilityRevision: CapabilityRevision(rawValue: "capability-1")!, capabilities: [], checkedAt: observedAt
            )
        )
        _ = try await accounts.save(
            repository: .init(
                id: 3, nodeID: repositoryID.rawValue, name: "repo", isPrivate: true, isArchived: false,
                hasDiscussions: true, htmlURL: URL(string: "https://github.com/acme/repo")!, updatedAt: observedAt,
                owner: .init(login: "acme")
            ),
            organizationID: organization.id,
            accountID: accountID
        )
        try await vault.write { database in
            try GitHubNodeRepository.save(
                .init(
                    nodeID: discussionNodeID, accountID: accountID, organizationID: organization.id,
                    repositoryID: repositoryID, kind: .discussion, numericID: nil, number: 1,
                    title: "Discussion", state: .open,
                    url: URL(string: "https://github.com/acme/repo/discussions/1")!, bodyMarkdown: nil,
                    authorID: nil, createdAt: observedAt, updatedAt: observedAt, closedAt: nil, mergedAt: nil,
                    sourceRevision: "seed", observedAt: observedAt, accessibility: .accessible
                ),
                in: database
            )
            try database.execute(
                sql: """
                INSERT INTO discussions (github_node_id, category_name, answer_comment_node_id, comments_count, updated_at_ms)
                VALUES (?, NULL, NULL, 0, ?)
                """,
                arguments: [discussionNodeID.rawValue, Int64(observedAt.timeIntervalSince1970 * 1_000)]
            )
        }
    }

    var scope: SynchronizationScope {
        .init(
            accountID: account.id,
            organizationID: organization.id,
            credentialRevision: CredentialRevision(rawValue: "credential-1")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-1")!
        )
    }

    func inventory(rawPages: [GitHubDiscussionCommentRawPage]) -> GitHubDiscussionCommentInventory {
        let commentID = GitHubNodeID(rawValue: "DC_1")!
        return .init(
            comments: [
                .init(
                    nodeID: commentID, discussionNodeID: discussionNodeID, parentNodeID: discussionNodeID,
                    kind: .discussionComment, author: nil, body: "Retained comment", createdAt: observedAt,
                    updatedAt: observedAt, url: URL(string: "https://github.com/acme/repo/discussions/1#discussioncomment-1")!
                )
            ],
            replies: [],
            rawPages: rawPages
        )
    }

    func completePages() -> [GitHubDiscussionCommentRawPage] {
        [rootPage(commentIDs: ["DC_1"]), replyPage(commentID: "DC_1", replyIDs: [])]
    }

    func rootPage(commentIDs: [String]) -> GitHubDiscussionCommentRawPage {
        .init(
            source: .comments,
            endpoint: "graphql:TriageDiscussionComments/discussion=D_1/page=1",
            requestKey: "graphql:TriageDiscussionComments/discussion=D_1/after=none",
            payload: pagePayload(nodeID: "D_1", connection: "comments", nodeIDs: commentIDs)
        )
    }

    func replyPage(commentID: String, replyIDs: [String]) -> GitHubDiscussionCommentRawPage {
        .init(
            source: .replies,
            endpoint: "graphql:TriageDiscussionCommentReplies/discussion=D_1/comment=\(commentID)/page=1",
            requestKey: "graphql:TriageDiscussionCommentReplies/discussion=D_1/comment=\(commentID)/after=none",
            payload: pagePayload(nodeID: commentID, connection: "replies", nodeIDs: replyIDs)
        )
    }

    func replace(
        _ inventory: GitHubDiscussionCommentInventory,
        using repository: DiscussionCommentRepository,
        observedAt: Date? = nil
    ) async throws {
        let date = observedAt ?? self.observedAt
        try await repository.replace(
            inventory,
            scope: scope,
            accountID: account.id,
            organization: organization,
            repositoryID: repositoryID,
            discussionNodeID: discussionNodeID,
            commentStreamID: SyncStreamID(rawValue: "discussion-comments-acme-R_1-D_1")!,
            replyStreamID: SyncStreamID(rawValue: "discussion-replies-acme-R_1-D_1")!,
            observedAt: date,
            coverageRecords: coverage(at: date)
        )
    }

    func persistedState() async throws -> PersistedState {
        try await vault.read { database in
            .init(
                commentBodies: try String.fetchAll(database, sql: "SELECT body_markdown FROM comments ORDER BY github_node_id"),
                rawCount: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots") ?? 0,
                coverageCount: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM coverage_records") ?? 0
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func coverage(at date: Date) -> [CoverageRecord] {
        [
            coverage(feature: .discussionComments, stream: "discussion-comments-acme-R_1-D_1", at: date),
            coverage(feature: .discussionReplies, stream: "discussion-replies-acme-R_1-D_1", at: date)
        ]
    }

    private func coverage(feature: CoverageFeature, stream: String, at date: Date) -> CoverageRecord {
        .init(
            accountID: account.id, organizationID: organization.id, repositoryID: repositoryID,
            feature: feature, streamID: SyncStreamID(rawValue: stream)!, intervalStart: date,
            intervalEnd: date, credentialRevision: scope.credentialRevision,
            capabilityRevision: scope.capabilityRevision, status: .complete, lastSuccessfulAt: date,
            failureDetail: nil
        )
    }

    private func pagePayload(nodeID: String, connection: String, nodeIDs: [String]) -> Data {
        let nodes = nodeIDs.map { ["id": $0] }
        return try! JSONSerialization.data(
            withJSONObject: [
                "data": [
                    "node": [
                        "id": nodeID,
                        connection: [
                            "nodes": nodes,
                            "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]
                        ]
                    ]
                ],
                "rateLimit": ["cost": 1, "remaining": 4_999, "resetAt": "2026-01-02T00:00:00Z"]
            ],
            options: [.sortedKeys]
        )
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line,
    verify: ((Error) -> Void)? = nil
) async {
    do {
        try await expression()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {
        verify?(error)
    }
}
