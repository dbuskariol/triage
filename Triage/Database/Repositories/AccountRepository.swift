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

    func save(_ account: GitHubAccount, credentialRevision: CredentialRevision) async throws {
        let createdAt = Self.milliseconds(account.createdAt)
        let lastValidatedAt = account.lastValidatedAt.map(Self.milliseconds)
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO accounts (
                        id, github_user_id, github_node_id, login, display_name, avatar_url,
                        authentication_kind, credential_id, credential_status, credential_revision,
                        created_at_ms, last_validated_at_ms, disabled_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
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

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
