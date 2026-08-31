import Foundation
import GRDB

enum AccountRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case staleCredentialRevision
    case invalidPersistedIdentifier
    case invalidCapabilityScope
    case organizationIdentityMismatch
    case synchronizationScopeUnavailable
}

actor AccountRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func accounts() async throws -> [GitHubAccount] {
        try await vault.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT id, github_user_id, github_node_id, login, display_name, avatar_url,
                           authentication_kind, credential_id, credential_status, access_token_expires_at_ms,
                           refresh_token_expires_at_ms, created_at_ms, last_validated_at_ms
                    FROM accounts
                    WHERE disabled_at_ms IS NULL
                    ORDER BY created_at_ms
                    """
            ).map { try Self.account(from: $0) }
        }
    }

    /// Returns the exact durable credential authority for this vault account.
    /// Callers use it only after resolving the account from this same vault, so
    /// an in-flight credential replacement is detected before any identity
    /// result can be published.
    func credentialRevision(for accountID: AccountID) async throws -> CredentialRevision {
        try ensureAccountScope(accountID)
        return try await vault.read { database in
            guard let rawValue = try String.fetchOne(
                database,
                sql: "SELECT credential_revision FROM accounts WHERE id = ? AND disabled_at_ms IS NULL",
                arguments: [accountID.rawValue]
            ), let revision = CredentialRevision(rawValue: rawValue) else {
                throw AccountRepositoryError.synchronizationScopeUnavailable
            }
            return revision
        }
    }

    func organizations(for accountID: AccountID) async throws -> [GitHubOrganization] {
        try ensureAccountScope(accountID)
        return try await vault.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT organizations.id, organizations.github_organization_id, organizations.github_node_id,
                           organizations.login, organizations.display_name, organizations.avatar_url
                    FROM organizations
                    JOIN account_organizations ON account_organizations.organization_id = organizations.id
                    WHERE account_organizations.account_id = ?
                    ORDER BY organizations.login
                    """,
                arguments: [accountID.rawValue]
            ).map { try Self.organization(from: $0) }
        }
    }

    func organizationAccesses(for accountID: AccountID) async throws -> [OrganizationID: OrganizationAccess] {
        try ensureAccountScope(accountID)
        return try await vault.read { database in
            let accessRows = try Row.fetchAll(
                database,
                sql: """
                    SELECT organization_id, access_state, capability_revision, checked_at_ms
                    FROM account_organizations
                    WHERE account_id = ?
                    """,
                arguments: [accountID.rawValue]
            )
            let capabilityRows = try Row.fetchAll(
                database,
                sql: """
                    SELECT organization_id, capability, status, checked_at_ms, detail_fingerprint
                    FROM capabilities
                    WHERE account_id = ? AND repository_id IS NULL
                    """,
                arguments: [accountID.rawValue]
            )
            let capabilitiesByOrganizationID = try Dictionary(grouping: capabilityRows) { row in
                guard let organizationID = OrganizationID(rawValue: row["organization_id"] as String) else {
                    throw AccountRepositoryError.invalidPersistedIdentifier
                }
                return organizationID
            }

            return try Dictionary(uniqueKeysWithValues: accessRows.map { row in
                guard let organizationID = OrganizationID(rawValue: row["organization_id"] as String),
                      let state = OrganizationAccessState(rawValue: row["access_state"] as String),
                      let capabilityRevision = CapabilityRevision(rawValue: row["capability_revision"] as String),
                      let checkedAt = Self.date(milliseconds: row["checked_at_ms"])
                else {
                    throw AccountRepositoryError.invalidPersistedIdentifier
                }
                let capabilities = try (capabilitiesByOrganizationID[organizationID] ?? []).map { capabilityRow in
                    guard let capability = GitHubCapability(rawValue: capabilityRow["capability"]),
                          let status = CapabilityStatus(rawValue: capabilityRow["status"]),
                          let capabilityCheckedAt = Self.date(milliseconds: capabilityRow["checked_at_ms"])
                    else {
                        throw AccountRepositoryError.invalidPersistedIdentifier
                    }
                    return CapabilityAvailability(
                        capability: capability,
                        status: status,
                        checkedAt: capabilityCheckedAt,
                        detail: capabilityRow["detail_fingerprint"]
                    )
                }
                return (
                    organizationID,
                    OrganizationAccess(
                        accountID: accountID,
                        organizationID: organizationID,
                        state: state,
                        capabilityRevision: capabilityRevision,
                        capabilities: capabilities,
                        checkedAt: checkedAt
                    )
                )
            })
        }
    }

    func synchronizationScope(
        for accountID: AccountID,
        organizationID: OrganizationID
    ) async throws -> SynchronizationScope {
        try ensureAccountScope(accountID)
        return try await vault.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT accounts.credential_revision, account_organizations.capability_revision
                    FROM accounts
                    JOIN account_organizations ON account_organizations.account_id = accounts.id
                    WHERE accounts.id = ? AND account_organizations.organization_id = ?
                    """,
                arguments: [accountID.rawValue, organizationID.rawValue]
            ),
            let credentialRevision = CredentialRevision(rawValue: row["credential_revision"]),
            let capabilityRevision = CapabilityRevision(rawValue: row["capability_revision"])
            else {
                throw AccountRepositoryError.synchronizationScopeUnavailable
            }
            return SynchronizationScope(
                accountID: accountID,
                organizationID: organizationID,
                credentialRevision: credentialRevision,
                capabilityRevision: capabilityRevision
            )
        }
    }

    func accountCapabilities(for accountID: AccountID) async throws -> AccountCapabilitySnapshot? {
        try ensureAccountScope(accountID)
        return try await vault.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT capability, status, checked_at_ms, detail_fingerprint
                    FROM account_capabilities
                    WHERE account_id = ?
                    ORDER BY capability
                    """,
                arguments: [accountID.rawValue]
            )
            guard !rows.isEmpty else {
                return nil
            }
            let capabilities = try rows.map { row in
                guard let capability = GitHubCapability(rawValue: row["capability"]),
                      capability.scope == .account,
                      let status = CapabilityStatus(rawValue: row["status"]),
                      let checkedAt = Self.date(milliseconds: row["checked_at_ms"])
                else {
                    throw AccountRepositoryError.invalidPersistedIdentifier
                }
                return CapabilityAvailability(
                    capability: capability,
                    status: status,
                    checkedAt: checkedAt,
                    detail: row["detail_fingerprint"]
                )
            }
            guard let checkedAt = capabilities.map(\.checkedAt).max() else {
                throw AccountRepositoryError.invalidPersistedIdentifier
            }
            return AccountCapabilitySnapshot(
                accountID: accountID,
                capabilities: capabilities,
                checkedAt: checkedAt
            )
        }
    }

    func save(_ account: GitHubAccount, credentialRevision: CredentialRevision) async throws {
        try ensureAccountScope(account.id)
        let createdAt = Self.milliseconds(account.createdAt)
        let lastValidatedAt = account.lastValidatedAt.map(Self.milliseconds)
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO accounts (
                        id, github_user_id, github_node_id, login, display_name, avatar_url,
                        authentication_kind, credential_id, credential_status, credential_revision,
                        access_token_expires_at_ms, refresh_token_expires_at_ms, created_at_ms, last_validated_at_ms, disabled_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    ON CONFLICT(id) DO UPDATE SET
                        github_user_id = excluded.github_user_id,
                        github_node_id = excluded.github_node_id,
                        login = excluded.login,
                        display_name = excluded.display_name,
                        avatar_url = excluded.avatar_url,
                        authentication_kind = excluded.authentication_kind,
                        credential_id = excluded.credential_id,
                        credential_status = excluded.credential_status,
                        credential_revision = excluded.credential_revision,
                        access_token_expires_at_ms = excluded.access_token_expires_at_ms,
                        refresh_token_expires_at_ms = excluded.refresh_token_expires_at_ms,
                        last_validated_at_ms = excluded.last_validated_at_ms,
                        disabled_at_ms = NULL
                    """,
                arguments: [
                    account.id.rawValue,
                    String(account.githubUserID),
                    account.nodeID.rawValue,
                    account.login,
                    account.displayName,
                    account.avatarURL?.absoluteString,
                    account.authenticationKind.rawValue,
                    account.credentialID.rawValue,
                    account.credentialStatus.rawValue,
                    credentialRevision.rawValue,
                    account.accessTokenExpiresAt.map(Self.milliseconds),
                    account.refreshTokenExpiresAt.map(Self.milliseconds),
                    createdAt,
                    lastValidatedAt
                ]
            )
        }
    }

    func save(
        _ organization: GitHubOrganization,
        access: OrganizationAccess,
        selectedAt: Date? = nil,
        accountCapabilities: AccountCapabilitySnapshot? = nil
    ) async throws {
        try ensureAccountScope(access.accountID)
        guard organization.id == access.organizationID else {
            throw AccountRepositoryError.organizationIdentityMismatch
        }
        guard !access.capabilities.contains(where: { $0.capability.scope != .organization }) else {
            throw AccountRepositoryError.invalidCapabilityScope
        }
        if let accountCapabilities,
           accountCapabilities.accountID != access.accountID ||
            accountCapabilities.capabilities.contains(where: { $0.capability.scope != .account }) {
            throw AccountRepositoryError.invalidCapabilityScope
        }
        let checkedAt = Self.milliseconds(access.checkedAt)
        let selectedAtMilliseconds = selectedAt.map(Self.milliseconds)
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO organizations (
                        id, github_organization_id, github_node_id, login, display_name, avatar_url, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        github_organization_id = excluded.github_organization_id,
                        github_node_id = excluded.github_node_id,
                        login = excluded.login,
                        display_name = excluded.display_name,
                        avatar_url = excluded.avatar_url,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                arguments: [
                    organization.id.rawValue,
                    String(organization.githubOrganizationID),
                    organization.nodeID.rawValue,
                    organization.login,
                    organization.displayName,
                    organization.avatarURL?.absoluteString,
                    checkedAt
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO account_organizations (
                        account_id, organization_id, access_state, capability_revision, selected_at_ms, checked_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET
                        access_state = excluded.access_state,
                        capability_revision = excluded.capability_revision,
                        selected_at_ms = excluded.selected_at_ms,
                        checked_at_ms = excluded.checked_at_ms
                    """,
                arguments: [
                    access.accountID.rawValue,
                    organization.id.rawValue,
                    access.state.rawValue,
                    access.capabilityRevision.rawValue,
                    selectedAtMilliseconds,
                    checkedAt
                ]
            )
            try database.execute(
                sql: "DELETE FROM capabilities WHERE account_id = ? AND organization_id = ? AND repository_id IS NULL",
                arguments: [access.accountID.rawValue, organization.id.rawValue]
            )
            for capability in access.capabilities {
                try database.execute(
                    sql: """
                        INSERT INTO capabilities (
                            id, account_id, organization_id, repository_id, capability, status, checked_at_ms, detail_fingerprint
                        ) VALUES (?, ?, ?, NULL, ?, ?, ?, ?)
                        """,
                    arguments: [
                        "\(access.accountID.rawValue):\(organization.id.rawValue):-:\(capability.capability.rawValue)",
                        access.accountID.rawValue,
                        organization.id.rawValue,
                        capability.capability.rawValue,
                        capability.status.rawValue,
                        Self.milliseconds(capability.checkedAt),
                        capability.detail
                    ]
                )
            }
            if let accountCapabilities {
                try Self.saveAccountCapabilities(accountCapabilities, in: database)
            }
        }

    }

    /// Adds identities proven by the account-scoped organization inventory
    /// without letting a superseded credential replay overwrite access state.
    /// The revision predicate and all inserts share one transaction so account
    /// removal or another credential rotation wins cleanly at the boundary.
    func reconcilePostCredentialOrganizationInventory(
        _ organizations: [GitHubOrganization],
        accountID: AccountID,
        expectedCredentialRevision: CredentialRevision,
        observedAt: Date
    ) async throws {
        try Task.checkCancellation()
        try ensureAccountScope(accountID)
        let observedAtMilliseconds = Self.milliseconds(observedAt)
        try await vault.writeTransaction { database in
            try Task.checkCancellation()
            let storedRevision: String? = try String.fetchOne(
                database,
                sql: "SELECT credential_revision FROM accounts WHERE id = ? AND disabled_at_ms IS NULL",
                arguments: [accountID.rawValue]
            )
            guard storedRevision == expectedCredentialRevision.rawValue else {
                throw AccountRepositoryError.staleCredentialRevision
            }

            var organizationIDs = Set<OrganizationID>()
            for (offset, organization) in organizations.enumerated() {
                if offset.isMultiple(of: 32) {
                    try Task.checkCancellation()
                }
                guard organizationIDs.insert(organization.id).inserted else {
                    throw AccountRepositoryError.organizationIdentityMismatch
                }
                try database.execute(
                    sql: """
                        INSERT INTO organizations (
                            id, github_organization_id, github_node_id, login, display_name, avatar_url, updated_at_ms
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            github_organization_id = excluded.github_organization_id,
                            github_node_id = excluded.github_node_id,
                            login = excluded.login,
                            display_name = excluded.display_name,
                            avatar_url = excluded.avatar_url,
                            updated_at_ms = excluded.updated_at_ms
                        """,
                    arguments: [
                        organization.id.rawValue,
                        String(organization.githubOrganizationID),
                        organization.nodeID.rawValue,
                        organization.login,
                        organization.displayName,
                        organization.avatarURL?.absoluteString,
                        observedAtMilliseconds
                    ]
                )
                let capabilityRevision = CapabilityRevision(rawValue: UUID().uuidString.lowercased())!
                try Task.checkCancellation()
                try database.execute(
                    sql: """
                        INSERT INTO account_organizations (
                            account_id, organization_id, access_state, capability_revision, selected_at_ms, checked_at_ms
                        ) VALUES (?, ?, 'available', ?, NULL, ?)
                        ON CONFLICT(account_id, organization_id) DO NOTHING
                        """,
                    arguments: [
                        accountID.rawValue,
                        organization.id.rawValue,
                        capabilityRevision.rawValue,
                        observedAtMilliseconds
                    ]
                )
                guard database.changesCount == 1 else { continue }
                for capability in GitHubCapability.allCases where capability.scope == .organization {
                    try database.execute(
                        sql: """
                            INSERT INTO capabilities (
                                id, account_id, organization_id, repository_id, capability, status, checked_at_ms, detail_fingerprint
                            ) VALUES (?, ?, ?, NULL, ?, 'unknown', ?, NULL)
                            """,
                        arguments: [
                            "\(accountID.rawValue):\(organization.id.rawValue):-:\(capability.rawValue)",
                            accountID.rawValue,
                            organization.id.rawValue,
                            capability.rawValue,
                            observedAtMilliseconds
                        ]
                    )
                }
            }
            try Task.checkCancellation()
        }
    }

    func save(_ snapshot: AccountCapabilitySnapshot) async throws {
        try ensureAccountScope(snapshot.accountID)
        guard snapshot.capabilities.allSatisfy({ $0.capability.scope == .account }) else {
            throw AccountRepositoryError.invalidCapabilityScope
        }
        try await vault.write { database in
            try Self.saveAccountCapabilities(snapshot, in: database)
        }
    }

    func save(
        repository: GitHubRepositoryDTO,
        organizationID: OrganizationID,
        accountID: AccountID
    ) async throws -> RepositorySummary {
        try ensureAccountScope(accountID)
        guard let nodeID = GitHubNodeID(rawValue: repository.nodeID),
              let repositoryID = RepositoryID(rawValue: repository.nodeID)
        else {
            throw AccountRepositoryError.invalidPersistedIdentifier
        }
        let updatedAt = Self.milliseconds(repository.updatedAt)
        return try await vault.write { database in
            let prior = try Row.fetchOne(
                database,
                sql: "SELECT has_discussions, has_discussions_known FROM repositories WHERE id = ?",
                arguments: [repositoryID.rawValue]
            )
            let priorHasDiscussions: Bool? = prior?["has_discussions"]
            let priorHasDiscussionsKnown: Bool = prior?["has_discussions_known"] ?? false
            let summary = RepositorySummary(
                id: repositoryID,
                nodeID: nodeID,
                ownerLogin: repository.owner.login,
                name: repository.name,
                isPrivate: repository.isPrivate,
                isArchived: repository.isArchived,
                hasDiscussions: repository.hasDiscussions ?? priorHasDiscussions ?? false,
                hasDiscussionsKnown: repository.hasDiscussions != nil || priorHasDiscussionsKnown,
                url: repository.htmlURL
            )
            try database.execute(
                sql: """
                    INSERT INTO repositories (
                        id, organization_id, github_repository_id, github_node_id, owner_login, name,
                        is_private, is_archived, has_discussions, has_discussions_known,
                        html_url, updated_at_ms, archived_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
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
                    summary.id.rawValue, organizationID.rawValue, String(repository.id), nodeID.rawValue,
                    summary.ownerLogin, summary.name, summary.isPrivate, summary.isArchived,
                    summary.hasDiscussions, summary.hasDiscussionsKnown,
                    summary.url.absoluteString, updatedAt,
                    summary.isArchived ? updatedAt : nil
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
                arguments: [accountID.rawValue, summary.id.rawValue, "available", updatedAt]
            )
            return summary
        }
    }

    private func ensureAccountScope(_ accountID: AccountID) throws {
        guard accountID == vault.accountID else {
            throw AccountRepositoryError.accountScopeMismatch
        }
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private nonisolated static func saveAccountCapabilities(
        _ snapshot: AccountCapabilitySnapshot,
        in database: Database
    ) throws {
        try database.execute(
            sql: "DELETE FROM account_capabilities WHERE account_id = ?",
            arguments: [snapshot.accountID.rawValue]
        )
        for capability in snapshot.capabilities {
            try database.execute(
                sql: """
                    INSERT INTO account_capabilities (
                        account_id, capability, status, checked_at_ms, detail_fingerprint
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    snapshot.accountID.rawValue,
                    capability.capability.rawValue,
                    capability.status.rawValue,
                    milliseconds(capability.checkedAt),
                    capability.detail
                ]
            )
        }
    }

    private nonisolated static func account(from row: Row) throws -> GitHubAccount {
        guard let id = AccountID(rawValue: row["id"]),
              let githubUserID = UInt64(row["github_user_id"] as String),
              let nodeID = GitHubNodeID(rawValue: row["github_node_id"]),
              let authenticationKind = AuthenticationKind(rawValue: row["authentication_kind"]),
              let credentialID = CredentialID(rawValue: row["credential_id"]),
              let credentialStatus = CredentialStatus(rawValue: row["credential_status"]),
              let createdAt = date(milliseconds: row["created_at_ms"])
        else {
            throw AccountRepositoryError.invalidPersistedIdentifier
        }
        return GitHubAccount(
            id: id,
            githubUserID: githubUserID,
            nodeID: nodeID,
            login: row["login"],
            displayName: row["display_name"],
            avatarURL: (row["avatar_url"] as String?).flatMap(URL.init(string:)),
            authenticationKind: authenticationKind,
            credentialID: credentialID,
            credentialStatus: credentialStatus,
            accessTokenExpiresAt: date(milliseconds: row["access_token_expires_at_ms"]),
            refreshTokenExpiresAt: date(milliseconds: row["refresh_token_expires_at_ms"]),
            createdAt: createdAt,
            lastValidatedAt: date(milliseconds: row["last_validated_at_ms"])
        )
    }

    private nonisolated static func organization(from row: Row) throws -> GitHubOrganization {
        guard let id = OrganizationID(rawValue: row["id"]),
              let githubOrganizationID = UInt64(row["github_organization_id"] as String),
              let nodeID = GitHubNodeID(rawValue: row["github_node_id"])
        else {
            throw AccountRepositoryError.invalidPersistedIdentifier
        }
        return GitHubOrganization(
            id: id,
            githubOrganizationID: githubOrganizationID,
            nodeID: nodeID,
            login: row["login"],
            displayName: row["display_name"],
            avatarURL: (row["avatar_url"] as String?).flatMap(URL.init(string:))
        )
    }

    private nonisolated static func date(milliseconds: Int64?) -> Date? {
        milliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
    }
}
