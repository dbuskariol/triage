import CryptoKit
import Foundation
import GRDB

enum PullRequestReviewRepositoryError: Error, Equatable, Sendable {
    case pullRequestNodeScopeMismatch
    case reviewNodeScopeMismatch
    case invalidReviewNodeID
    case duplicateReviewNodeID
    case invalidTraversalReceipt
}

enum PullRequestReviewReplacementProofError: Error, Equatable, Sendable {
    case invalidTraversalReceipt
    case normalizedDigestMismatch
}

/// A transaction-local authorization for replacing the two normalized review
/// collections. The receipt alone proves raw traversal completeness; this
/// proof additionally binds that receipt to the exact normalized responses
/// about to be written.
struct PullRequestReviewReplacementProof: Sendable {
    let completeTraversalReceipt: ReviewCandidateCompleteTraversalReceiptToken
    private let reviewsDigest: Data
    private let requestedReviewersDigest: Data

    nonisolated static func normalizedDigest(
        reviews: [GitHubPullRequestReviewDTO],
        requestedReviewers: GitHubRequestedReviewersDTO
    ) -> Data {
        var material = Data()
        append(reviewsDigest(for: reviews), to: &material)
        append(requestedReviewersDigest(for: requestedReviewers), to: &material)
        return Data(SHA256.hash(data: material))
    }

    nonisolated static func make(
        reviews: [GitHubPullRequestReviewDTO],
        requestedReviewers: GitHubRequestedReviewersDTO,
        completeTraversalReceipt: ReviewCandidateCompleteTraversalReceiptToken,
        in database: Database
    ) throws -> Self {
        try ReviewCandidateCompleteTraversalReceiptRepository.validate(
            completeTraversalReceipt,
            in: database
        )
        guard let receiptDigest = try Data.fetchOne(
            database,
            sql: "SELECT normalized_digest FROM review_candidate_complete_traversal_receipts WHERE id = ?",
            arguments: [completeTraversalReceipt.id.uuidString.lowercased()]
        ), receiptDigest == normalizedDigest(reviews: reviews, requestedReviewers: requestedReviewers)
        else {
            throw PullRequestReviewReplacementProofError.normalizedDigestMismatch
        }
        return Self(
            completeTraversalReceipt: completeTraversalReceipt,
            reviewsDigest: reviewsDigest(for: reviews),
            requestedReviewersDigest: requestedReviewersDigest(for: requestedReviewers)
        )
    }

    nonisolated func validate(
        reviews: [GitHubPullRequestReviewDTO],
        pullRequestNodeID: GitHubNodeID,
        accountID: AccountID,
        in database: Database
    ) throws {
        guard completeTraversalReceipt.feature == .reviews,
              completeTraversalReceipt.candidateNodeID == pullRequestNodeID,
              completeTraversalReceipt.scope.accountID == accountID
        else {
            throw PullRequestReviewReplacementProofError.invalidTraversalReceipt
        }
        try ReviewCandidateCompleteTraversalReceiptRepository.validate(
            completeTraversalReceipt,
            in: database
        )
        guard reviewsDigest == Self.reviewsDigest(for: reviews) else {
            throw PullRequestReviewReplacementProofError.normalizedDigestMismatch
        }
    }

    nonisolated func validate(
        requestedReviewers: GitHubRequestedReviewersDTO,
        pullRequestNodeID: GitHubNodeID,
        accountID: AccountID,
        in database: Database
    ) throws {
        guard completeTraversalReceipt.feature == .reviews,
              completeTraversalReceipt.candidateNodeID == pullRequestNodeID,
              completeTraversalReceipt.scope.accountID == accountID
        else {
            throw PullRequestReviewReplacementProofError.invalidTraversalReceipt
        }
        try ReviewCandidateCompleteTraversalReceiptRepository.validate(
            completeTraversalReceipt,
            in: database
        )
        guard requestedReviewersDigest == Self.requestedReviewersDigest(for: requestedReviewers) else {
            throw PullRequestReviewReplacementProofError.normalizedDigestMismatch
        }
    }

    private nonisolated static func reviewsDigest(for reviews: [GitHubPullRequestReviewDTO]) -> Data {
        let records = reviews.map { review in
            [
                "review", review.nodeID, String(review.id), review.state,
                review.body ?? "", review.submittedAt.map { String($0.timeIntervalSince1970) } ?? ""
            ]
        }.sorted(by: { $0.lexicographicallyPrecedes($1) })
        return digest(records)
    }

    private nonisolated static func requestedReviewersDigest(
        for requestedReviewers: GitHubRequestedReviewersDTO
    ) -> Data {
        let records = requestedReviewers.users.map {
            ["user", $0.nodeID, $0.login ?? "", $0.slug ?? ""]
        } + requestedReviewers.teams.map {
            ["team", $0.nodeID, $0.login ?? "", $0.slug ?? ""]
        }
        return digest(records.sorted(by: { $0.lexicographicallyPrecedes($1) }))
    }

    private nonisolated static func digest(_ records: [[String]]) -> Data {
        var material = Data()
        records.flatMap { $0 }.forEach { append($0, to: &material) }
        return Data(SHA256.hash(data: material))
    }

    private nonisolated static func append(_ value: String, to data: inout Data) {
        let valueData = Data(value.utf8)
        var length = UInt64(valueData.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(valueData)
    }

    private nonisolated static func append(_ value: Data, to data: inout Data) {
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }
}

actor PullRequestReviewRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func save(
        review: GitHubPullRequestReviewDTO,
        pullRequestNodeID: GitHubNodeID,
        observedAt: Date = .now
    ) async throws {
        guard let reviewNodeID = GitHubNodeID(rawValue: review.nodeID) else {
            throw WorkItemRepositoryError.invalidPersistedData
        }
        let observedAtMilliseconds = Int64((observedAt.timeIntervalSince1970 * 1_000).rounded())
        try await vault.write { database in
            try Self.validatePullRequestNodeScope(
                pullRequestNodeID,
                accountID: vault.accountID,
                in: database
            )
            try Self.save(
                review,
                reviewNodeID: reviewNodeID,
                pullRequestNodeID: pullRequestNodeID,
                accountID: vault.accountID,
                observedAtMilliseconds: observedAtMilliseconds,
                in: database
            )
        }
    }

    /// Replaces a fully paginated review history. Callers must not use this for
    /// individual pages, because doing so would incorrectly discard later pages.
    func replace(
        reviews: [GitHubPullRequestReviewDTO],
        pullRequestNodeID: GitHubNodeID,
        replacementProof: PullRequestReviewReplacementProof,
        observedAt: Date = .now
    ) async throws {
        let observedAtMilliseconds = Self.milliseconds(observedAt)
        try await vault.writeTransaction { database in
            try Self.replace(
                reviews,
                pullRequestNodeID: pullRequestNodeID,
                accountID: vault.accountID,
                observedAtMilliseconds: observedAtMilliseconds,
                replacementProof: replacementProof,
                in: database
            )
        }
    }

    nonisolated static func replace(
        _ reviews: [GitHubPullRequestReviewDTO],
        pullRequestNodeID: GitHubNodeID,
        accountID: AccountID,
        observedAtMilliseconds: Int64,
        replacementProof: PullRequestReviewReplacementProof,
        in database: Database
    ) throws {
        do {
            try replacementProof.validate(
                reviews: reviews,
                pullRequestNodeID: pullRequestNodeID,
                accountID: accountID,
                in: database
            )
        } catch {
            throw PullRequestReviewRepositoryError.invalidTraversalReceipt
        }
        let reviewNodeIDs = try reviewNodeIDs(for: reviews)
        try validatePullRequestNodeScope(pullRequestNodeID, accountID: accountID, in: database)
        try validateReviewNodeScopes(
            reviewNodeIDs,
            pullRequestNodeID: pullRequestNodeID,
            accountID: accountID,
            in: database
        )
        let staleReviewNodeIDs = try String.fetchAll(
            database,
            sql: "SELECT github_node_id FROM reviews WHERE pull_request_node_id = ?",
            arguments: [pullRequestNodeID.rawValue]
        )
        try database.execute(
            sql: "DELETE FROM reviews WHERE pull_request_node_id = ?",
            arguments: [pullRequestNodeID.rawValue]
        )
        for (review, reviewNodeID) in zip(reviews, reviewNodeIDs) {
            try save(
                review,
                reviewNodeID: reviewNodeID,
                pullRequestNodeID: pullRequestNodeID,
                accountID: accountID,
                observedAtMilliseconds: observedAtMilliseconds,
                in: database
            )
        }
        let retainedNodeIDs = Set(reviewNodeIDs.map(\.rawValue))
        for staleNodeID in staleReviewNodeIDs where !retainedNodeIDs.contains(staleNodeID) {
            try database.execute(
                sql: "DELETE FROM github_nodes WHERE github_node_id = ? AND kind = ? AND account_id = ?",
                arguments: [
                    staleNodeID,
                    GitHubContentKind.pullRequestReview.rawValue,
                    accountID.rawValue
                ]
            )
        }
    }

    private nonisolated static func validatePullRequestNodeScope(
        _ nodeID: GitHubNodeID,
        accountID: AccountID,
        in database: Database
    ) throws {
        let matchingCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*)
                FROM pull_requests
                JOIN github_nodes ON github_nodes.github_node_id = pull_requests.github_node_id
                WHERE pull_requests.github_node_id = ? AND github_nodes.account_id = ?
                """,
            arguments: [nodeID.rawValue, accountID.rawValue]
        ) ?? 0
        guard matchingCount == 1 else {
            throw PullRequestReviewRepositoryError.pullRequestNodeScopeMismatch
        }
    }

    private nonisolated static func reviewNodeIDs(
        for reviews: [GitHubPullRequestReviewDTO]
    ) throws -> [GitHubNodeID] {
        let reviewNodeIDs = try reviews.map { review in
            guard let reviewNodeID = GitHubNodeID(rawValue: review.nodeID) else {
                throw PullRequestReviewRepositoryError.invalidReviewNodeID
            }
            return reviewNodeID
        }
        guard Set(reviewNodeIDs).count == reviewNodeIDs.count else {
            throw PullRequestReviewRepositoryError.duplicateReviewNodeID
        }
        return reviewNodeIDs
    }

    private nonisolated static func validateReviewNodeScopes(
        _ reviewNodeIDs: [GitHubNodeID],
        pullRequestNodeID: GitHubNodeID,
        accountID: AccountID,
        in database: Database
    ) throws {
        for reviewNodeID in reviewNodeIDs {
            let conflictingReviewCount = try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*)
                    FROM reviews
                    WHERE github_node_id = ? AND pull_request_node_id <> ?
                    """,
                arguments: [reviewNodeID.rawValue, pullRequestNodeID.rawValue]
            ) ?? 0
            let conflictingNodeCount = try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*)
                    FROM github_nodes AS review_node
                    JOIN github_nodes AS pull_request_node
                      ON pull_request_node.github_node_id = ?
                    WHERE review_node.github_node_id = ?
                      AND (
                        review_node.account_id <> ?
                        OR review_node.account_id <> pull_request_node.account_id
                        OR review_node.organization_id <> pull_request_node.organization_id
                        OR review_node.repository_id IS NOT pull_request_node.repository_id
                        OR review_node.kind <> ?
                      )
                    """,
                arguments: [
                    pullRequestNodeID.rawValue,
                    reviewNodeID.rawValue,
                    accountID.rawValue,
                    GitHubContentKind.pullRequestReview.rawValue
                ]
            ) ?? 0
            guard conflictingReviewCount == 0, conflictingNodeCount == 0 else {
                throw PullRequestReviewRepositoryError.reviewNodeScopeMismatch
            }
        }
    }

    private nonisolated static func save(
        _ review: GitHubPullRequestReviewDTO,
        reviewNodeID: GitHubNodeID,
        pullRequestNodeID: GitHubNodeID,
        accountID: AccountID,
        observedAtMilliseconds: Int64,
        in database: Database
    ) throws {
        let submittedAtMilliseconds = review.submittedAt.map(milliseconds)
        let reviewTimestamp = submittedAtMilliseconds ?? observedAtMilliseconds
        try database.execute(
            sql: """
                INSERT INTO github_nodes (
                    github_node_id, account_id, organization_id, repository_id, kind,
                    numeric_id, number, title, state, html_url, body_markdown, author_id,
                    created_at_ms, updated_at_ms, closed_at_ms, merged_at_ms,
                    source_revision, last_observed_at_ms, accessibility_state
                )
                SELECT
                    ?, account_id, organization_id, repository_id, ?,
                    ?, NULL, 'Pull request review', 'unknown', html_url, ?, NULL,
                    ?, ?, NULL, NULL, ?, ?, 'accessible'
                FROM github_nodes
                WHERE github_node_id = ? AND account_id = ? AND kind = ?
                ON CONFLICT(github_node_id) DO UPDATE SET
                    repository_id = excluded.repository_id,
                    kind = excluded.kind,
                    numeric_id = excluded.numeric_id,
                    title = excluded.title,
                    state = excluded.state,
                    html_url = excluded.html_url,
                    body_markdown = excluded.body_markdown,
                    updated_at_ms = excluded.updated_at_ms,
                    source_revision = excluded.source_revision,
                    last_observed_at_ms = excluded.last_observed_at_ms,
                    accessibility_state = excluded.accessibility_state
                """,
            arguments: [
                reviewNodeID.rawValue,
                GitHubContentKind.pullRequestReview.rawValue,
                String(review.id),
                review.body,
                reviewTimestamp,
                reviewTimestamp,
                "\(review.id):\(review.nodeID):\(review.state):\(reviewTimestamp)",
                observedAtMilliseconds,
                pullRequestNodeID.rawValue,
                accountID.rawValue,
                GitHubContentKind.pullRequest.rawValue
            ]
        )
        try database.execute(
            sql: """
                INSERT INTO reviews (
                    github_node_id, pull_request_node_id, author_id, state, body_markdown,
                    submitted_at_ms, html_url, updated_at_ms
                ) VALUES (?, ?, NULL, ?, ?, ?, NULL, ?)
                ON CONFLICT(github_node_id) DO UPDATE SET
                    pull_request_node_id = excluded.pull_request_node_id,
                    state = excluded.state,
                    body_markdown = excluded.body_markdown,
                    submitted_at_ms = excluded.submitted_at_ms,
                    updated_at_ms = excluded.updated_at_ms
                """,
            arguments: [
                reviewNodeID.rawValue,
                pullRequestNodeID.rawValue,
                review.state,
                review.body,
                submittedAtMilliseconds,
                observedAtMilliseconds
            ]
        )
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
