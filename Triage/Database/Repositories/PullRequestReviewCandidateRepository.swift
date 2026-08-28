import Foundation
import GRDB

enum PullRequestReviewCandidateRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case invalidPersistedCandidate
}

struct PullRequestReviewCandidate: Sendable {
    let nodeID: GitHubNodeID
    let repositoryID: RepositoryID
    let repository: GitHubRepositoryPath
    let number: Int
}

actor PullRequestReviewCandidateRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func candidates(
        accountID: AccountID,
        organizationID: OrganizationID,
        limit: Int
    ) async throws -> [PullRequestReviewCandidate] {
        guard accountID == vault.accountID else {
            throw PullRequestReviewCandidateRepositoryError.accountScopeMismatch
        }
        guard limit > 0 else { return [] }
        return try await vault.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT github_nodes.github_node_id, repositories.id AS repository_id,
                           repositories.owner_login, repositories.name, github_nodes.number
                    FROM pull_requests
                    JOIN github_nodes
                      ON github_nodes.github_node_id = pull_requests.github_node_id
                    JOIN repositories ON repositories.id = github_nodes.repository_id
                    WHERE github_nodes.account_id = ?
                      AND github_nodes.organization_id = ?
                      AND github_nodes.accessibility_state = ?
                      AND github_nodes.number > 0
                    ORDER BY github_nodes.last_observed_at_ms ASC, github_nodes.github_node_id ASC
                    LIMIT ?
                    """,
                arguments: [
                    accountID.rawValue,
                    organizationID.rawValue,
                    GitHubNodeAccessibility.accessible.rawValue,
                    limit
                ]
            ).map(Self.candidate)
        }
    }

    func writeTransaction<Value: Sendable>(
        accountID: AccountID,
        _ operation: @Sendable (Database) throws -> Value
    ) async throws -> Value {
        guard accountID == vault.accountID else {
            throw PullRequestReviewCandidateRepositoryError.accountScopeMismatch
        }
        return try await vault.writeTransaction(operation)
    }

    private nonisolated static func candidate(_ row: Row) throws -> PullRequestReviewCandidate {
        guard let nodeID = GitHubNodeID(rawValue: row["github_node_id"]),
              let repositoryID = RepositoryID(rawValue: row["repository_id"]),
              let number: Int = row["number"]
        else {
            throw PullRequestReviewCandidateRepositoryError.invalidPersistedCandidate
        }
        return PullRequestReviewCandidate(
            nodeID: nodeID,
            repositoryID: repositoryID,
            repository: try GitHubRepositoryPath(
                owner: row["owner_login"],
                repository: row["name"]
            ),
            number: number
        )
    }
}
