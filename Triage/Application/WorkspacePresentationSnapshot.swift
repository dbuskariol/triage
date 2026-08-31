import Foundation

enum AccountSessionSnapshotError: Error, Equatable, Sendable {
    case duplicateAccount
    case duplicateOrganization
    case unknownAccountReference
    case mismatchedAccessAccount
    case mismatchedCapabilityAccount
}

/// A value-only account/session projection. It contains no secrets, vaults,
/// clients, or mutable presentation state.
struct AccountSessionSnapshot: Equatable, Sendable {
    let accounts: [GitHubAccount]
    let organizationsByAccount: [AccountID: [GitHubOrganization]]
    let organizationAccessesByAccount: [AccountID: [OrganizationID: OrganizationAccess]]
    let accountCapabilitiesByAccount: [AccountID: AccountCapabilitySnapshot]
    /// Opaque account identities whose vault cannot be opened. They are kept
    /// separate from usable accounts so the UI can offer local crypto-erasure
    /// without manufacturing GitHub profile data from a missing vault.
    let unavailableAccountIDs: Set<AccountID>
    /// Non-secret remediation notice produced after a successful credential
    /// replacement whose retired Keychain entry could not be erased.
    let credentialActionNotice: String?

    init(
        accounts: [GitHubAccount],
        organizationsByAccount: [AccountID: [GitHubOrganization]],
        organizationAccessesByAccount: [AccountID: [OrganizationID: OrganizationAccess]],
        accountCapabilitiesByAccount: [AccountID: AccountCapabilitySnapshot],
        unavailableAccountIDs: Set<AccountID> = [],
        credentialActionNotice: String? = nil
    ) throws {
        let accountIDs = Set(accounts.map(\.id))
        guard accountIDs.count == accounts.count else {
            throw AccountSessionSnapshotError.duplicateAccount
        }
        guard Set(organizationsByAccount.keys).isSubset(of: accountIDs),
              Set(organizationAccessesByAccount.keys).isSubset(of: accountIDs),
              Set(accountCapabilitiesByAccount.keys).isSubset(of: accountIDs),
              unavailableAccountIDs.isDisjoint(with: accountIDs)
        else {
            throw AccountSessionSnapshotError.unknownAccountReference
        }
        guard organizationsByAccount.values.allSatisfy({ organizations in
            Set(organizations.map(\.id)).count == organizations.count
        }) else {
            throw AccountSessionSnapshotError.duplicateOrganization
        }
        for (accountID, accesses) in organizationAccessesByAccount {
            guard accesses.allSatisfy({ organizationID, access in
                access.accountID == accountID && access.organizationID == organizationID
            }) else {
                throw AccountSessionSnapshotError.mismatchedAccessAccount
            }
        }
        for (accountID, capabilities) in accountCapabilitiesByAccount {
            guard capabilities.accountID == accountID else {
                throw AccountSessionSnapshotError.mismatchedCapabilityAccount
            }
        }
        self.accounts = accounts
        self.organizationsByAccount = organizationsByAccount
        self.organizationAccessesByAccount = organizationAccessesByAccount
        self.accountCapabilitiesByAccount = accountCapabilitiesByAccount
        self.unavailableAccountIDs = unavailableAccountIDs
        self.credentialActionNotice = credentialActionNotice
    }
}

enum WorkspacePresentationSnapshotError: Error, Equatable, Sendable {
    case workItemScopeMismatch
    case coverageScopeMismatch
    case durableStateScopeMismatch
    case invalidDerivedEvaluationDate
}

/// The only workspace value a view, menu bar, notification evaluator, or
/// main-actor presentation adapter should consume. Every enclosed persisted
/// value is bound to the exact credential/capability revisions in `scope`.
struct WorkspacePresentationSnapshot: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        /// The first durable projection restored before a new refresh completes.
        case cached
        /// A projection emitted after a committed database change.
        case observed
    }

    let scope: SynchronizationScope
    let workItems: [WorkItem]
    let durableState: AccountOrganizationDurableState
    let coverageRequirements: [CoverageRequirement]
    let coverageRecords: [CoverageRecord]
    /// Account-scoped organization inventory authority. A workspace can have
    /// complete work coverage while the set of organizations visible to the
    /// credential is incomplete; that is not safe notification authority.
    let organizationVisibilityFreshness: FreshnessState
    let menuCounts: DerivedMenuCounts?
    let derivedEvaluatedAt: Date?
    let origin: Origin

    init(
        scope: SynchronizationScope,
        workItems: [WorkItem],
        durableState: AccountOrganizationDurableState,
        coverageRequirements: [CoverageRequirement],
        coverageRecords: [CoverageRecord],
        organizationVisibilityFreshness: FreshnessState = .init(status: .fresh),
        menuCounts: DerivedMenuCounts?,
        derivedEvaluatedAt: Date?,
        origin: Origin
    ) throws {
        guard workItems.allSatisfy({
            $0.accountID == scope.accountID && $0.organizationID == scope.organizationID
        }) else {
            throw WorkspacePresentationSnapshotError.workItemScopeMismatch
        }
        guard coverageRecords.allSatisfy({
            $0.accountID == scope.accountID
                && $0.organizationID == scope.organizationID
                && $0.credentialRevision == scope.credentialRevision
                && $0.capabilityRevision == scope.capabilityRevision
        }) else {
            throw WorkspacePresentationSnapshotError.coverageScopeMismatch
        }
        if let cachedState = durableState.cachedState {
            guard cachedState.coverage.allSatisfy({
                $0.accountID == scope.accountID
                    && $0.organizationID == scope.organizationID
                    && $0.credentialRevision == scope.credentialRevision
                    && $0.capabilityRevision == scope.capabilityRevision
            }) else {
                throw WorkspacePresentationSnapshotError.durableStateScopeMismatch
            }
        }
        if let derivedEvaluatedAt,
           !derivedEvaluatedAt.timeIntervalSinceReferenceDate.isFinite {
            throw WorkspacePresentationSnapshotError.invalidDerivedEvaluationDate
        }
        self.scope = scope
        self.workItems = workItems
        self.durableState = durableState
        self.coverageRequirements = coverageRequirements
        self.coverageRecords = coverageRecords
        self.organizationVisibilityFreshness = organizationVisibilityFreshness
        self.menuCounts = menuCounts
        self.derivedEvaluatedAt = derivedEvaluatedAt
        self.origin = origin
    }

    var coverageEvaluation: CoverageEvaluation {
        CoverageEvaluator().evaluate(
            requirements: coverageRequirements,
            records: coverageRecords,
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            credentialRevision: scope.credentialRevision,
            capabilityRevision: scope.capabilityRevision
        )
    }
}
