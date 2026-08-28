import Foundation
import GRDB

enum AccountRepositoryError: Error, Equatable, Sendable {
    case invalidPersistedIdentifier
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

    func organizations(for accountID: AccountID) async throws -> [GitHubOrganization] {
        try await vault.read { database in
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

    func save(_ account: GitHubAccount, credentialRevision: CredentialRevision) async throws {
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
        selectedAt: Date? = nil
    ) async throws {
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
        }

    }

    func save(
        repository: GitHubRepositoryDTO,
        organizationID: OrganizationID,
        accountID: AccountID
    ) async throws -> RepositorySummary {
        guard let nodeID = GitHubNodeID(rawValue: repository.nodeID),
              let repositoryID = RepositoryID(rawValue: repository.nodeID)
        else {
            throw AccountRepositoryError.invalidPersistedIdentifier
        }
        let summary = RepositorySummary(
            id: repositoryID,
            nodeID: nodeID,
            ownerLogin: repository.owner.login,
            name: repository.name,
            isPrivate: repository.isPrivate,
            isArchived: repository.isArchived,
            hasDiscussions: false,
            url: repository.htmlURL
        )
        let updatedAt = Self.milliseconds(repository.updatedAt)
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO repositories (
                        id, organization_id, github_repository_id, github_node_id, owner_login, name,
                        is_private, is_archived, has_discussions, html_url, updated_at_ms, archived_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        owner_login = excluded.owner_login,
                        name = excluded.name,
                        is_private = excluded.is_private,
                        is_archived = excluded.is_archived,
                        html_url = excluded.html_url,
                        updated_at_ms = excluded.updated_at_ms,
                        archived_at_ms = excluded.archived_at_ms
                    """,
                arguments: [
                    summary.id.rawValue, organizationID.rawValue, String(repository.id), nodeID.rawValue,
                    summary.ownerLogin, summary.name, summary.isPrivate, summary.isArchived,
                    summary.hasDiscussions, summary.url.absoluteString, updatedAt,
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
        }
        return summary
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
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
