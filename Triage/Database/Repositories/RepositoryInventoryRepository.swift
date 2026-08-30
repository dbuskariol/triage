import Foundation
import GRDB

enum RepositoryInventoryRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case organizationScopeMismatch
    case invalidRepository
    case duplicateRepository
    case immutableIdentityConflict
    case invalidPersistedData
}

struct RepositoryInventoryReconciliationResult: Equatable, Sendable {
    let summaries: [RepositorySummary]
    let returnedRepositoryIDs: [RepositoryID]
    let omittedRepositoryIDs: [RepositoryID]
}

actor RepositoryInventoryRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func replace(
        _ repositories: [GitHubRepositoryDTO],
        accountID: AccountID,
        organization: GitHubOrganization,
        observedAt: Date
    ) async throws -> [RepositorySummary] {
        try await reconcile(
            repositories,
            accountID: accountID,
            organization: organization,
            observedAt: observedAt,
            reconciliationIntent: .incremental
        ).summaries
    }

    func reconcile(
        _ repositories: [GitHubRepositoryDTO],
        accountID: AccountID,
        organization: GitHubOrganization,
        observedAt: Date,
        reconciliationIntent: SynchronizationReconciliationIntent
    ) async throws -> RepositoryInventoryReconciliationResult {
        try ensureAccountScope(accountID)
        return try await vault.writeTransaction { database in
            try Self.reconcile(
                repositories,
                accountID: accountID,
                organization: organization,
                observedAt: observedAt,
                reconciliationIntent: reconciliationIntent,
                in: database
            )
        }
    }

    func writeTransaction<Value: Sendable>(
        accountID: AccountID,
        _ operation: @Sendable (Database) throws -> Value
    ) async throws -> Value {
        try ensureAccountScope(accountID)
        return try await vault.writeTransaction(operation)
    }

    func repositories(
        accountID: AccountID,
        organization: GitHubOrganization
    ) async throws -> [RepositorySummary] {
        try ensureAccountScope(accountID)
        return try await vault.read { database in
            try Self.validateOrganizationScope(accountID: accountID, organization: organization, in: database)
            return try Row.fetchAll(
                database,
                sql: """
                    SELECT repositories.id, repositories.github_node_id, repositories.owner_login,
                           repositories.name, repositories.is_private, repositories.is_archived,
                           repositories.has_discussions, repositories.has_discussions_known,
                           repositories.html_url
                    FROM repositories
                    JOIN account_repository_access
                      ON account_repository_access.repository_id = repositories.id
                    WHERE account_repository_access.account_id = ?
                      AND account_repository_access.access_state = 'available'
                      AND repositories.organization_id = ?
                    ORDER BY repositories.owner_login, repositories.name, repositories.id
                    """,
                arguments: [accountID.rawValue, organization.id.rawValue]
            ).map { row in
                guard let id = RepositoryID(rawValue: row["id"]),
                      let nodeID = GitHubNodeID(rawValue: row["github_node_id"]),
                      let ownerLogin: String = row["owner_login"],
                      let name: String = row["name"],
                      let isPrivate: Bool = row["is_private"],
                      let isArchived: Bool = row["is_archived"],
                      let hasDiscussions: Bool = row["has_discussions"],
                      let hasDiscussionsKnown: Bool = row["has_discussions_known"],
                      let urlString: String = row["html_url"],
                      let url = URL(string: urlString)
                else {
                    throw RepositoryInventoryRepositoryError.invalidPersistedData
                }
                return RepositorySummary(
                    id: id,
                    nodeID: nodeID,
                    ownerLogin: ownerLogin,
                    name: name,
                    isPrivate: isPrivate,
                    isArchived: isArchived,
                    hasDiscussions: hasDiscussions,
                    hasDiscussionsKnown: hasDiscussionsKnown,
                    url: url
                )
            }
        }
    }

    nonisolated static func replace(
        _ repositories: [GitHubRepositoryDTO],
        accountID: AccountID,
        organization: GitHubOrganization,
        observedAt: Date,
        in database: Database
    ) throws -> [RepositorySummary] {
        try reconcile(
            repositories,
            accountID: accountID,
            organization: organization,
            observedAt: observedAt,
            reconciliationIntent: .incremental,
            in: database
        ).summaries
    }

    nonisolated static func reconcile(
        _ repositories: [GitHubRepositoryDTO],
        accountID: AccountID,
        organization: GitHubOrganization,
        observedAt: Date,
        reconciliationIntent: SynchronizationReconciliationIntent,
        in database: Database
    ) throws -> RepositoryInventoryReconciliationResult {
        try validateOrganizationScope(accountID: accountID, organization: organization, in: database)
        let persistedRepositories = try persistedRepositories(in: database)
        let persistedByID = Dictionary(
            uniqueKeysWithValues: persistedRepositories.map { ($0.id, $0) }
        )
        let normalized = try repositories.map { repository in
            guard let repositoryID = RepositoryID(rawValue: repository.nodeID) else {
                throw RepositoryInventoryRepositoryError.invalidRepository
            }
            let prior = persistedByID[repositoryID]
            let priorHasDiscussions = prior?.hasDiscussions
            let priorHasDiscussionsKnown = prior?.hasDiscussionsKnown ?? false
            let hasDiscussions = repository.hasDiscussions ?? priorHasDiscussions ?? false
            let hasDiscussionsKnown = repository.hasDiscussions != nil || priorHasDiscussionsKnown
            return try normalize(
                repository,
                organization: organization,
                hasDiscussions: hasDiscussions,
                hasDiscussionsKnown: hasDiscussionsKnown
            )
        }
        guard Set(normalized.map(\.id)).count == normalized.count,
              Set(normalized.map(\.nodeID)).count == normalized.count,
              Set(normalized.map(\.githubRepositoryID)).count == normalized.count,
              Set(normalized.map(\.caseFoldedOwnerAndName)).count == normalized.count
        else {
            throw RepositoryInventoryRepositoryError.duplicateRepository
        }
        try validateImmutableIdentities(
            normalized,
            organizationID: organization.id,
            persistedRepositories: persistedRepositories,
            reconciliationIntent: reconciliationIntent
        )

        let priorRepositoryIDs = try repositoryIDsInOrganization(
            organizationID: organization.id,
            in: database
        )
        let returnedRepositoryIDs = normalized.map(\.id)
        let returnedRepositoryIDSet = Set(returnedRepositoryIDs)
        let omittedRepositoryIDs = priorRepositoryIDs
            .filter { !returnedRepositoryIDSet.contains($0) }
            .sorted { $0.rawValue < $1.rawValue }

        try markRepositoryAccessUnknown(
            accountID: accountID,
            organizationID: organization.id,
            observedAt: observedAt,
            in: database
        )

        let observedAtMilliseconds = milliseconds(observedAt)
        for repository in normalized {
            try database.execute(
                sql: """
                    INSERT INTO repositories (
                        id, organization_id, github_repository_id, github_node_id, owner_login, name,
                        is_private, is_archived, has_discussions, has_discussions_known,
                        html_url, updated_at_ms, archived_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        organization_id = excluded.organization_id,
                        github_repository_id = excluded.github_repository_id,
                        github_node_id = excluded.github_node_id,
                        owner_login = excluded.owner_login,
                        name = excluded.name,
                        is_private = excluded.is_private,
                        is_archived = excluded.is_archived,
                        has_discussions = excluded.has_discussions,
                        has_discussions_known = excluded.has_discussions_known,
                        html_url = excluded.html_url,
                        updated_at_ms = excluded.updated_at_ms,
                        archived_at_ms = excluded.archived_at_ms
                    """,
                arguments: [
                    repository.id.rawValue,
                    organization.id.rawValue,
                    String(repository.githubRepositoryID),
                    repository.nodeID.rawValue,
                    repository.ownerLogin,
                    repository.name,
                    repository.isPrivate,
                    repository.isArchived,
                    repository.hasDiscussions,
                    repository.hasDiscussionsKnown,
                    repository.url.absoluteString,
                    milliseconds(repository.updatedAt),
                    repository.isArchived ? milliseconds(repository.updatedAt) : nil
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO account_repository_access (account_id, repository_id, access_state, observed_at_ms)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(account_id, repository_id) DO UPDATE SET
                        access_state = excluded.access_state,
                        observed_at_ms = excluded.observed_at_ms
                    """,
                arguments: [
                    accountID.rawValue,
                    repository.id.rawValue,
                    RepositoryAccessState.available.rawValue,
                    observedAtMilliseconds
                ]
            )
        }
        return RepositoryInventoryReconciliationResult(
            summaries: normalized.map(\.summary),
            returnedRepositoryIDs: returnedRepositoryIDs,
            omittedRepositoryIDs: omittedRepositoryIDs
        )
    }

    private func ensureAccountScope(_ accountID: AccountID) throws {
        guard accountID == vault.accountID else {
            throw RepositoryInventoryRepositoryError.accountScopeMismatch
        }
    }

    private nonisolated static func validateOrganizationScope(
        accountID: AccountID,
        organization: GitHubOrganization,
        in database: Database
    ) throws {
        let row = try Row.fetchOne(
            database,
            sql: """
                SELECT organizations.github_organization_id, organizations.login
                FROM organizations
                JOIN account_organizations
                  ON account_organizations.organization_id = organizations.id
                WHERE organizations.id = ? AND account_organizations.account_id = ?
                """,
            arguments: [organization.id.rawValue, accountID.rawValue]
        )
        guard let row,
              (row["github_organization_id"] as String?) == String(organization.githubOrganizationID),
              let persistedLogin: String = row["login"],
              persistedLogin.caseInsensitiveCompare(organization.login) == .orderedSame
        else {
            throw RepositoryInventoryRepositoryError.organizationScopeMismatch
        }
    }

    private nonisolated static func normalize(
        _ repository: GitHubRepositoryDTO,
        organization: GitHubOrganization,
        hasDiscussions: Bool,
        hasDiscussionsKnown: Bool
    ) throws -> InventoryRepository {
        guard repository.id > 0,
              let nodeID = GitHubNodeID(rawValue: repository.nodeID),
              let repositoryID = RepositoryID(rawValue: repository.nodeID),
              isRepositoryName(repository.name),
              isGitHubLogin(repository.owner.login),
              repository.owner.login.caseInsensitiveCompare(organization.login) == .orderedSame,
              isGitHubURL(repository.htmlURL, owner: repository.owner.login, repository: repository.name)
        else {
            throw RepositoryInventoryRepositoryError.invalidRepository
        }
        return InventoryRepository(
            id: repositoryID,
            githubRepositoryID: repository.id,
            nodeID: nodeID,
            ownerLogin: repository.owner.login,
            name: repository.name,
            isPrivate: repository.isPrivate,
            isArchived: repository.isArchived,
            hasDiscussions: hasDiscussions,
            hasDiscussionsKnown: hasDiscussionsKnown,
            url: repository.htmlURL,
            updatedAt: repository.updatedAt
        )
    }

    private nonisolated static func markRepositoryAccessUnknown(
        accountID: AccountID,
        organizationID: OrganizationID,
        observedAt: Date,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO account_repository_access (
                    account_id, repository_id, access_state, observed_at_ms
                )
                SELECT ?, repositories.id, ?, ?
                FROM repositories
                WHERE repositories.organization_id = ?
                ON CONFLICT(account_id, repository_id) DO UPDATE SET
                    access_state = excluded.access_state,
                    observed_at_ms = excluded.observed_at_ms
                """,
            arguments: [
                accountID.rawValue,
                RepositoryAccessState.unknown.rawValue,
                milliseconds(observedAt),
                organizationID.rawValue
            ]
        )
    }

    private nonisolated static func persistedRepositories(
        in database: Database
    ) throws -> [PersistedInventoryRepository] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT id, organization_id, github_repository_id, github_node_id,
                       owner_login, name, has_discussions, has_discussions_known
                FROM repositories
                """
        ).map { row in
            guard let id = RepositoryID(rawValue: row["id"]),
                  let organizationID = OrganizationID(rawValue: row["organization_id"]),
                  let githubRepositoryIDValue: String = row["github_repository_id"],
                  let githubRepositoryID = UInt64(githubRepositoryIDValue),
                  githubRepositoryID > 0,
                  let nodeID = GitHubNodeID(rawValue: row["github_node_id"]),
                  id.rawValue == nodeID.rawValue,
                  let ownerLogin: String = row["owner_login"],
                  let name: String = row["name"],
                  let hasDiscussions: Bool = row["has_discussions"],
                  let hasDiscussionsKnown: Bool = row["has_discussions_known"]
            else {
                throw RepositoryInventoryRepositoryError.invalidPersistedData
            }
            return PersistedInventoryRepository(
                id: id,
                organizationID: organizationID,
                githubRepositoryID: githubRepositoryID,
                nodeID: nodeID,
                ownerLogin: ownerLogin,
                name: name,
                hasDiscussions: hasDiscussions,
                hasDiscussionsKnown: hasDiscussionsKnown
            )
        }
    }

    private nonisolated static func repositoryIDsInOrganization(
        organizationID: OrganizationID,
        in database: Database
    ) throws -> [RepositoryID] {
        try String.fetchAll(
            database,
            sql: """
                SELECT id
                FROM repositories
                WHERE organization_id = ?
                ORDER BY id
                """,
            arguments: [organizationID.rawValue]
        ).map { value in
            guard let id = RepositoryID(rawValue: value) else {
                throw RepositoryInventoryRepositoryError.invalidPersistedData
            }
            return id
        }
    }

    private nonisolated static func validateImmutableIdentities(
        _ repositories: [InventoryRepository],
        organizationID: OrganizationID,
        persistedRepositories: [PersistedInventoryRepository],
        reconciliationIntent: SynchronizationReconciliationIntent
    ) throws {
        // Identity replacement is deliberately unsupported for both intents until
        // an independently persisted, authoritative deletion workflow owns it.
        switch reconciliationIntent {
        case .incremental, .fullReconciliation:
            break
        }

        let persistedByNodeID = Dictionary(
            uniqueKeysWithValues: persistedRepositories.map { ($0.nodeID, $0) }
        )
        let persistedByGitHubRepositoryID = Dictionary(
            uniqueKeysWithValues: persistedRepositories.map { ($0.githubRepositoryID, $0) }
        )
        for repository in repositories {
            if let persisted = persistedByNodeID[repository.nodeID],
               persisted.githubRepositoryID != repository.githubRepositoryID
                || persisted.organizationID != organizationID {
                throw RepositoryInventoryRepositoryError.immutableIdentityConflict
            }
            if let persisted = persistedByGitHubRepositoryID[repository.githubRepositoryID],
               persisted.nodeID != repository.nodeID
                || persisted.organizationID != organizationID {
                throw RepositoryInventoryRepositoryError.immutableIdentityConflict
            }
            if persistedRepositories.contains(where: {
                $0.organizationID == organizationID
                    && $0.caseFoldedOwnerAndName == repository.caseFoldedOwnerAndName
                    && $0.id != repository.id
            }) {
                throw RepositoryInventoryRepositoryError.immutableIdentityConflict
            }
        }
    }

    private nonisolated static func isGitHubLogin(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 39 && value.unicodeScalars.allSatisfy {
            $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "-")
        }
    }

    private nonisolated static func isRepositoryName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && !value.contains("/") && !value.contains(where: \.isWhitespace)
    }

    private nonisolated static func isGitHubURL(_ url: URL, owner: String, repository: String) -> Bool {
        guard url.scheme == "https",
              url.host == "github.com",
              url.user == nil,
              url.password == nil
        else {
            return false
        }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
        return components.count == 2
            && components[0].caseInsensitiveCompare(owner) == .orderedSame
            && components[1] == repository
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

private struct InventoryRepository: Sendable {
    let id: RepositoryID
    let githubRepositoryID: UInt64
    let nodeID: GitHubNodeID
    let ownerLogin: String
    let name: String
    let isPrivate: Bool
    let isArchived: Bool
    let hasDiscussions: Bool
    let hasDiscussionsKnown: Bool
    let url: URL
    let updatedAt: Date

    var caseFoldedOwnerAndName: String {
        Self.caseFoldedOwnerAndName(ownerLogin: ownerLogin, name: name)
    }

    static func caseFoldedOwnerAndName(ownerLogin: String, name: String) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        let foldedOwner = ownerLogin.folding(options: .caseInsensitive, locale: locale)
        let foldedName = name.folding(options: .caseInsensitive, locale: locale)
        return "\(foldedOwner)/\(foldedName)"
    }

    var summary: RepositorySummary {
        RepositorySummary(
            id: id,
            nodeID: nodeID,
            ownerLogin: ownerLogin,
            name: name,
            isPrivate: isPrivate,
            isArchived: isArchived,
            hasDiscussions: hasDiscussions,
            hasDiscussionsKnown: hasDiscussionsKnown,
            url: url
        )
    }
}

private struct PersistedInventoryRepository: Sendable {
    let id: RepositoryID
    let organizationID: OrganizationID
    let githubRepositoryID: UInt64
    let nodeID: GitHubNodeID
    let ownerLogin: String
    let name: String
    let hasDiscussions: Bool
    let hasDiscussionsKnown: Bool

    var caseFoldedOwnerAndName: String {
        InventoryRepository.caseFoldedOwnerAndName(ownerLogin: ownerLogin, name: name)
    }
}
