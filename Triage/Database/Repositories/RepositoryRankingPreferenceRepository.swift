import Foundation
import GRDB

enum RepositoryRankingPreferenceRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case invalidPreference
    case invalidUpdatedAt
    case repositoryOutsideOrganization
    case staleSynchronizationScope
    case invalidPersistedData
}

/// Stores the user's local ranking adjustment for one repository. The value
/// is encrypted with the account vault and scoped to an account/organization
/// pair; it is not GitHub metadata and is never sent to a remote service.
actor RepositoryRankingPreferenceRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func preferences(for scope: SynchronizationScope) async throws -> [RepositoryID: Int] {
        try validateVaultAccount(scope.accountID)
        return try await vault.read { database in
            try Self.validateCurrentScope(scope, in: database)
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT repository_id, preference
                    FROM repository_ranking_preferences
                    WHERE account_id = ? AND organization_id = ?
                    ORDER BY repository_id
                    """,
                arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
            )
            var result = [RepositoryID: Int]()
            result.reserveCapacity(rows.count)
            for row in rows {
                guard let rawRepositoryID: String = row["repository_id"],
                      let repositoryID = RepositoryID(rawValue: rawRepositoryID),
                      let preference: Int = row["preference"],
                      (-100 ... 100).contains(preference),
                      result[repositoryID] == nil
                else {
                    throw RepositoryRankingPreferenceRepositoryError.invalidPersistedData
                }
                result[repositoryID] = preference
            }
            return result
        }
    }

    func save(
        _ preference: Int,
        for repositoryID: RepositoryID,
        scope: SynchronizationScope,
        at updatedAt: Date = .now
    ) async throws {
        try validateVaultAccount(scope.accountID)
        guard (-100 ... 100).contains(preference) else {
            throw RepositoryRankingPreferenceRepositoryError.invalidPreference
        }
        guard updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RepositoryRankingPreferenceRepositoryError.invalidUpdatedAt
        }
        try await vault.writeTransaction { database in
            try Self.validateCurrentScope(scope, in: database)
            let belongsToOrganization = try Bool.fetchOne(
                database,
                sql: """
                    SELECT EXISTS (
                        SELECT 1
                        FROM repositories
                        WHERE id = ? AND organization_id = ?
                    )
                    """,
                arguments: [repositoryID.rawValue, scope.organizationID.rawValue]
            ) ?? false
            guard belongsToOrganization else {
                throw RepositoryRankingPreferenceRepositoryError.repositoryOutsideOrganization
            }
            try database.execute(
                sql: """
                    INSERT INTO repository_ranking_preferences (
                        account_id, organization_id, repository_id, preference, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, organization_id, repository_id) DO UPDATE SET
                        preference = excluded.preference,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                arguments: [
                    scope.accountID.rawValue,
                    scope.organizationID.rawValue,
                    repositoryID.rawValue,
                    preference,
                    Self.milliseconds(updatedAt)
                ]
            )
        }
    }

    func remove(
        repositoryID: RepositoryID,
        scope: SynchronizationScope
    ) async throws {
        try validateVaultAccount(scope.accountID)
        try await vault.writeTransaction { database in
            try Self.validateCurrentScope(scope, in: database)
            try database.execute(
                sql: """
                    DELETE FROM repository_ranking_preferences
                    WHERE account_id = ? AND organization_id = ? AND repository_id = ?
                    """,
                arguments: [
                    scope.accountID.rawValue,
                    scope.organizationID.rawValue,
                    repositoryID.rawValue
                ]
            )
        }
    }

    /// Revision material for derived intelligence. Preferences are local input
    /// to ranking, so publication fences must change when their effective
    /// values change even though no GitHub source revision has moved.
    nonisolated static func sourceRevisions(
        for scope: SynchronizationScope,
        in database: Database
    ) throws -> [DerivedIntelligenceSupplementalSource] {
        try validateCurrentScope(scope, in: database)
        return try Row.fetchAll(
            database,
            sql: """
                SELECT repository_id, preference
                FROM repository_ranking_preferences
                WHERE account_id = ? AND organization_id = ?
                ORDER BY repository_id
                """,
            arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
        ).map { row in
            guard let repositoryID: String = row["repository_id"],
                  RepositoryID(rawValue: repositoryID) != nil,
                  let preference: Int = row["preference"],
                  (-100 ... 100).contains(preference)
            else {
                throw RepositoryRankingPreferenceRepositoryError.invalidPersistedData
            }
            return DerivedIntelligenceSupplementalSource(
                kind: "repository-ranking-preference",
                identity: repositoryID,
                revision: String(preference)
            )
        }
    }

    private func validateVaultAccount(_ accountID: AccountID) throws {
        guard accountID == vault.accountID else {
            throw RepositoryRankingPreferenceRepositoryError.accountScopeMismatch
        }
    }

    private nonisolated static func validateCurrentScope(
        _ scope: SynchronizationScope,
        in database: Database
    ) throws {
        do {
            try OrganizationSchedulerStateRepository.validateCurrentScope(scope, in: database)
        } catch {
            throw RepositoryRankingPreferenceRepositoryError.staleSynchronizationScope
        }
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
