import Foundation
import GRDB

enum TeamInventoryRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case organizationScopeMismatch
    case invalidTeam
    case duplicateTeam
    case invalidMembership
    case membershipTeamMismatch
    case unknownMembershipVisibility
    case invalidPersistedData
}

struct TeamInventorySummary: Equatable, Sendable, Identifiable {
    let id: TeamID
    let nodeID: GitHubNodeID
    let slug: String
    let name: String
    let privacy: String?
    let membershipState: String?
}

struct TeamMembershipObservation: Sendable {
    let teamID: TeamID
    let membership: GitHubTeamMembership
}

actor TeamInventoryRepository {
    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func replace(
        teams: [GitHubTeamDTO],
        memberships: [TeamMembershipObservation],
        accountID: AccountID,
        organization: GitHubOrganization,
        observedAt: Date
    ) async throws -> [TeamInventorySummary] {
        try ensureAccountScope(accountID)
        return try await vault.writeTransaction { database in
            try Self.replace(
                teams: teams,
                memberships: memberships,
                accountID: accountID,
                organization: organization,
                observedAt: observedAt,
                in: database
            )
        }
    }

    func replaceMemberships(
        _ memberships: [TeamMembershipObservation],
        accountID: AccountID,
        organization: GitHubOrganization,
        observedAt: Date
    ) async throws -> [TeamInventorySummary] {
        try ensureAccountScope(accountID)
        return try await vault.writeTransaction { database in
            try Self.replaceMemberships(
                memberships: memberships,
                accountID: accountID,
                organization: organization,
                observedAt: observedAt,
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

    func teams(
        accountID: AccountID,
        organization: GitHubOrganization
    ) async throws -> [TeamInventorySummary] {
        try ensureAccountScope(accountID)
        return try await vault.read { database in
            try Self.validateOrganizationScope(accountID: accountID, organization: organization, in: database)
            return try Row.fetchAll(
                database,
                sql: """
                    SELECT teams.id, teams.github_node_id, teams.slug, teams.name, teams.privacy,
                           team_memberships.membership_state
                    FROM teams
                    LEFT JOIN team_memberships
                      ON team_memberships.team_id = teams.id AND team_memberships.account_id = ?
                    WHERE teams.organization_id = ?
                    ORDER BY teams.slug, teams.id
                    """,
                arguments: [accountID.rawValue, organization.id.rawValue]
            ).map { row in
                guard let id = TeamID(rawValue: row["id"]),
                      let nodeID = GitHubNodeID(rawValue: row["github_node_id"]),
                      let slug: String = row["slug"],
                      let name: String = row["name"]
                else {
                    throw TeamInventoryRepositoryError.invalidPersistedData
                }
                return TeamInventorySummary(
                    id: id,
                    nodeID: nodeID,
                    slug: slug,
                    name: name,
                    privacy: row["privacy"],
                    membershipState: row["membership_state"]
                )
            }
        }
    }

    nonisolated static func replace(
        teams: [GitHubTeamDTO],
        memberships: [TeamMembershipObservation],
        accountID: AccountID,
        organization: GitHubOrganization,
        observedAt: Date,
        in database: Database
    ) throws -> [TeamInventorySummary] {
        let normalizedTeams = try replaceTeams(
            teams,
            accountID: accountID,
            organization: organization,
            observedAt: observedAt,
            in: database
        )
        let membershipsByTeamID = try membershipStates(
            memberships,
            expectedTeamIDs: Set(normalizedTeams.map(\.id)),
            observedAt: observedAt
        )
        try replaceMemberships(
            membershipsByTeamID,
            teams: normalizedTeams,
            accountID: accountID,
            organization: organization,
            observedAt: observedAt,
            in: database
        )
        return normalizedTeams.map {
            TeamInventorySummary(
                id: $0.id,
                nodeID: $0.nodeID,
                slug: $0.slug,
                name: $0.name,
                privacy: $0.privacy,
                membershipState: membershipsByTeamID[$0.id]
            )
        }
    }

    nonisolated static func replaceTeams(
        _ teams: [GitHubTeamDTO],
        accountID: AccountID,
        organization: GitHubOrganization,
        observedAt: Date,
        in database: Database
    ) throws -> [InventoryTeam] {
        try validateOrganizationScope(accountID: accountID, organization: organization, in: database)
        let normalizedTeams = try teams.map(normalize)
        guard Set(normalizedTeams.map(\.id)).count == normalizedTeams.count,
              Set(normalizedTeams.map(\.nodeID)).count == normalizedTeams.count,
              Set(normalizedTeams.map(\.slug)).count == normalizedTeams.count
        else {
            throw TeamInventoryRepositoryError.duplicateTeam
        }
        let teamIDs = normalizedTeams.map(\.id.rawValue)
        try deleteAbsentTeams(teamIDs, organizationID: organization.id, in: database)
        for teamID in teamIDs {
            try database.execute(
                sql: """
                    UPDATE teams
                    SET slug = '__triage_inventory_rename__' || id
                    WHERE id = ? AND organization_id = ?
                    """,
                arguments: [teamID, organization.id.rawValue]
            )
        }
        let observedAtMilliseconds = milliseconds(observedAt)
        for team in normalizedTeams {
            try database.execute(
                sql: """
                    INSERT INTO teams (
                        id, organization_id, github_node_id, slug, name, privacy, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        organization_id = excluded.organization_id,
                        github_node_id = excluded.github_node_id,
                        slug = excluded.slug,
                        name = excluded.name,
                        privacy = excluded.privacy,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                arguments: [
                    team.id.rawValue,
                    organization.id.rawValue,
                    team.nodeID.rawValue,
                    team.slug,
                    team.name,
                    team.privacy,
                    observedAtMilliseconds
                ]
            )
        }
        return normalizedTeams
    }

    nonisolated static func replaceMemberships(
        _ membershipStates: [TeamID: String],
        teams: [InventoryTeam],
        accountID: AccountID,
        organization: GitHubOrganization,
        observedAt: Date,
        in database: Database
    ) throws {
        try validateOrganizationScope(accountID: accountID, organization: organization, in: database)
        guard membershipStates.count == teams.count,
              Set(teams.map(\.id)) == Set(membershipStates.keys),
              membershipStates.values.allSatisfy({ $0 == "active" || $0 == "pending" || $0 == "none" })
        else {
            throw TeamInventoryRepositoryError.membershipTeamMismatch
        }
        try database.execute(
            sql: """
                DELETE FROM team_memberships
                WHERE account_id = ?
                  AND team_id IN (SELECT id FROM teams WHERE organization_id = ?)
                """,
            arguments: [accountID.rawValue, organization.id.rawValue]
        )
        let observedAtMilliseconds = milliseconds(observedAt)
        for team in teams {
            try database.execute(
                sql: """
                    INSERT INTO team_memberships (
                        account_id, team_id, membership_state, observed_at_ms, expires_at_ms
                    ) VALUES (?, ?, ?, ?, NULL)
                    """,
                arguments: [
                    accountID.rawValue,
                    team.id.rawValue,
                    membershipStates[team.id]!,
                    observedAtMilliseconds
                ]
            )
        }
    }

    nonisolated static func replaceMemberships(
        memberships: [TeamMembershipObservation],
        accountID: AccountID,
        organization: GitHubOrganization,
        observedAt: Date,
        in database: Database
    ) throws -> [TeamInventorySummary] {
        try validateOrganizationScope(accountID: accountID, organization: organization, in: database)
        let teams = try storedTeams(organizationID: organization.id, in: database)
        let states = try membershipStates(
            memberships,
            expectedTeamIDs: Set(teams.map(\.id)),
            observedAt: observedAt
        )
        try replaceMemberships(
            states,
            teams: teams,
            accountID: accountID,
            organization: organization,
            observedAt: observedAt,
            in: database
        )
        return teams.map {
            TeamInventorySummary(
                id: $0.id,
                nodeID: $0.nodeID,
                slug: $0.slug,
                name: $0.name,
                privacy: $0.privacy,
                membershipState: states[$0.id]
            )
        }
    }

    private func ensureAccountScope(_ accountID: AccountID) throws {
        guard accountID == vault.accountID else {
            throw TeamInventoryRepositoryError.accountScopeMismatch
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
            throw TeamInventoryRepositoryError.organizationScopeMismatch
        }
    }

    private nonisolated static func normalize(_ team: GitHubTeamDTO) throws -> InventoryTeam {
        guard team.id > 0,
              let nodeID = GitHubNodeID(rawValue: team.nodeID),
              let teamID = TeamID(rawValue: team.nodeID),
              isTeamSlug(team.slug),
              !team.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              team.name.count <= 255,
              team.privacy == nil || team.privacy == "closed" || team.privacy == "secret"
        else {
            throw TeamInventoryRepositoryError.invalidTeam
        }
        return InventoryTeam(
            id: teamID,
            nodeID: nodeID,
            slug: team.slug,
            name: team.name,
            privacy: team.privacy
        )
    }

    private nonisolated static func membershipStates(
        _ observations: [TeamMembershipObservation],
        expectedTeamIDs: Set<TeamID>,
        observedAt _: Date
    ) throws -> [TeamID: String] {
        var states = [TeamID: String]()
        for observation in observations {
            guard expectedTeamIDs.contains(observation.teamID),
                  states[observation.teamID] == nil
            else {
                throw TeamInventoryRepositoryError.membershipTeamMismatch
            }
            switch observation.membership {
            case let .member(response):
                guard response.value.state == "active" || response.value.state == "pending",
                      response.value.role.map({ $0 == "member" || $0 == "maintainer" }) ?? true
                else {
                    throw TeamInventoryRepositoryError.invalidMembership
                }
                states[observation.teamID] = response.value.state
            case let .authoritativeNonMembership(response):
                guard response.value.state == "none" else {
                    throw TeamInventoryRepositoryError.invalidMembership
                }
                states[observation.teamID] = "none"
            case .unknown:
                throw TeamInventoryRepositoryError.unknownMembershipVisibility
            }
        }
        return states
    }

    private nonisolated static func storedTeams(
        organizationID: OrganizationID,
        in database: Database
    ) throws -> [InventoryTeam] {
        try Row.fetchAll(
            database,
            sql: """
                SELECT id, github_node_id, slug, name, privacy
                FROM teams
                WHERE organization_id = ?
                ORDER BY slug, id
                """,
            arguments: [organizationID.rawValue]
        ).map { row in
            guard let id = TeamID(rawValue: row["id"]),
                  let nodeID = GitHubNodeID(rawValue: row["github_node_id"]),
                  let slug: String = row["slug"],
                  let name: String = row["name"]
            else {
                throw TeamInventoryRepositoryError.invalidPersistedData
            }
            return InventoryTeam(id: id, nodeID: nodeID, slug: slug, name: name, privacy: row["privacy"])
        }
    }

    private nonisolated static func deleteAbsentTeams(
        _ teamIDs: [String],
        organizationID: OrganizationID,
        in database: Database
    ) throws {
        if teamIDs.isEmpty {
            try database.execute(
                sql: "DELETE FROM teams WHERE organization_id = ?",
                arguments: [organizationID.rawValue]
            )
            return
        }
        let placeholders = Array(repeating: "?", count: teamIDs.count).joined(separator: ", ")
        var arguments: [DatabaseValueConvertible?] = [organizationID.rawValue]
        arguments.append(contentsOf: teamIDs)
        try database.execute(
            sql: "DELETE FROM teams WHERE organization_id = ? AND id NOT IN (\(placeholders))",
            arguments: StatementArguments(arguments)
        )
    }

    private nonisolated static func isTeamSlug(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 255 && value.unicodeScalars.allSatisfy {
            $0.isASCII && ($0.properties.isLowercase || $0.properties.numericType != nil || $0 == "-")
        }
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

struct InventoryTeam: Sendable {
    let id: TeamID
    let nodeID: GitHubNodeID
    let slug: String
    let name: String
    let privacy: String?
}
