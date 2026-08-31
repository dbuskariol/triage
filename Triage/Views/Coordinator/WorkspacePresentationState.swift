import Foundation

struct WorkspacePresentationState: Equatable {
    enum SynchronizationStatus: Equatable {
        case noAccount
        case noOrganization
        case initialSynchronization
        case upToDate
        case refreshing
        case partial
        case ssoRequired
        case approvalRequired
        case offline
        case signInRequired
        case unavailable

        var title: String {
            switch self {
            case .noAccount: "No GitHub account"
            case .noOrganization: "Choose an organization"
            case .initialSynchronization: "Ready to synchronize"
            case .upToDate: "Up to date"
            case .refreshing: "Refreshing"
            case .partial: "Partial access"
            case .ssoRequired: "SSO authorization required"
            case .approvalRequired: "Organization approval required"
            case .offline: "Offline — showing local work"
            case .signInRequired: "Account sign-in required"
            case .unavailable: "Sync status unavailable"
            }
        }

        var systemImage: String {
            switch self {
            case .noAccount: "person.crop.circle.badge.questionmark"
            case .noOrganization: "building.2.crop.circle"
            case .initialSynchronization: "arrow.triangle.2.circlepath"
            case .upToDate: "checkmark.circle"
            case .refreshing: "arrow.triangle.2.circlepath"
            case .partial: "exclamationmark.circle"
            case .ssoRequired: "lock.shield"
            case .approvalRequired: "person.badge.key"
            case .offline: "wifi.slash"
            case .signInRequired: "person.crop.circle.badge.exclamationmark"
            case .unavailable: "questionmark.circle"
            }
        }
    }

    struct SectionCount: Equatable, Identifiable {
        let section: AppSection
        let count: Int

        var id: AppSection { section }
    }

    let selectedAccountID: AccountID?
    let selectedOrganizationID: OrganizationID?
    let sectionCounts: [SectionCount]
    let synchronizationStatus: SynchronizationStatus
    let synchronizationDetail: String?
    let lastSuccessfulSyncAt: Date?

    init(
        workItems: [WorkItem],
        selectedAccountID: AccountID?,
        selectedOrganizationID: OrganizationID?,
        organizationAccess: OrganizationAccess?,
        hasSSOAuthorizationHeader: Bool,
        isRefreshing: Bool,
        refreshError: String?,
        workspaceFreshness: FreshnessState? = nil,
        now: Date
    ) {
        self.selectedAccountID = selectedAccountID
        self.selectedOrganizationID = selectedOrganizationID
        sectionCounts = AppSection.allCases.map { section in
            SectionCount(
                section: section,
                count: selectedAccountID != nil && selectedOrganizationID != nil
                    ? Self.count(for: section, in: workItems, at: now)
                    : 0
            )
        }

        let status = Self.status(
            workItems: workItems,
            selectedAccountID: selectedAccountID,
            selectedOrganizationID: selectedOrganizationID,
            organizationAccess: organizationAccess,
            hasSSOAuthorizationHeader: hasSSOAuthorizationHeader,
            isRefreshing: isRefreshing,
            refreshError: refreshError,
            workspaceFreshness: workspaceFreshness
        )
        synchronizationStatus = status.status
        synchronizationDetail = status.detail
        lastSuccessfulSyncAt = workspaceFreshness?.lastSuccessfulSyncAt
            ?? workItems.compactMap(\.freshness.lastSuccessfulSyncAt).max()
    }

    func count(for section: AppSection) -> Int {
        sectionCounts.first(where: { $0.section == section })?.count ?? 0
    }

    private static func count(for section: AppSection, in workItems: [WorkItem], at now: Date) -> Int {
        switch section {
        case .inbox:
            workItems.count { InboxEligibilityRule().disposition(for: $0, at: now) == .inbox }
        case .myWork:
            workItems.count { item in
                item.relations.contains { $0.kind == .assigned || $0.kind == .authored }
            }
        case .reviews:
            workItems.count { item in
                item.relations.contains {
                    $0.kind == .reviewRequestedDirectly || $0.kind == .reviewRequestedFromTeam
                }
            }
        case .waiting:
            workItems.count { InboxEligibilityRule().disposition(for: $0, at: now) == .waiting }
        case .snoozed:
            workItems.count { InboxEligibilityRule().disposition(for: $0, at: now) == .snoozed }
        case .allWork:
            workItems.count
        }
    }

    private static func status(
        workItems: [WorkItem],
        selectedAccountID: AccountID?,
        selectedOrganizationID: OrganizationID?,
        organizationAccess: OrganizationAccess?,
        hasSSOAuthorizationHeader: Bool,
        isRefreshing: Bool,
        refreshError: String?,
        workspaceFreshness: FreshnessState?
    ) -> (status: SynchronizationStatus, detail: String?) {
        guard selectedAccountID != nil else {
            return (.noAccount, "Connect a GitHub account to view work.")
        }

        guard selectedOrganizationID != nil else {
            return (.noOrganization, "Choose an organization to view its local work queue.")
        }

        if isRefreshing {
            return (.refreshing, "Updating work for the selected organization.")
        }

        if let organizationAccess {
            switch organizationAccess.state {
            case .ssoAuthorizationRequired:
                return (.ssoRequired, "Authorize this account with your organization to refresh its work.")
            case .partialSSOAuthorization:
                return (.partial, "Some organization resources still require SSO authorization.")
            case .organizationApprovalRequired, .oauthApplicationApprovalRequired:
                return (.approvalRequired, "Your organization must approve this account or application before all work can sync.")
            case .organizationPolicyBlocked, .insufficientPermission, .inaccessible:
                return (.partial, "Your current account cannot access all organization work.")
            case .credentialExpired:
                return (.signInRequired, "Reconnect the selected account to refresh work.")
            case .available, .unknown:
                break
            }
        }

        if hasSSOAuthorizationHeader {
            return (.ssoRequired, "Authorize this account with your organization to refresh its work.")
        }

        if let workspaceFreshness {
            return status(for: workspaceFreshness, refreshError: refreshError)
        }

        if let refreshError {
            return (.partial, refreshError)
        }

        if workItems.isEmpty {
            return (.initialSynchronization, "Synchronize this organization to create its local work queue.")
        }

        if let offlineItem = workItems.first(where: { $0.freshness.status == .offline }) {
            return (.offline, offlineItem.freshness.detail ?? "Showing the most recent local work.")
        }

        if workItems.contains(where: {
            $0.freshness.status == .partial
                || $0.freshness.status == .stale
                || $0.freshness.status == .rateLimited
                || $0.freshness.status == .failed
        }) {
            return (
                .partial,
                refreshError
                    ?? coverageDetail(in: workItems)
                    ?? "Some work could not be refreshed."
            )
        }

        if workItems.contains(where: { $0.freshness.status == .ssoRequired }) {
            return (.ssoRequired, refreshError ?? "Authorize this account with your organization to refresh its work.")
        }

        if workItems.contains(where: { $0.freshness.status == .approvalRequired }) {
            return (.approvalRequired, refreshError ?? "Your organization must approve this account or application before all work can sync.")
        }

        if workItems.contains(where: { $0.freshness.status == .authenticationRequired }) {
            return (.signInRequired, refreshError ?? "Account access is required before work can refresh.")
        }

        return (.unavailable, "No current synchronization coverage is available.")
    }

    /// Freshness details originate with persisted coverage, so preserving one
    /// here lets the sidebar name the incomplete stream instead of replacing
    /// it with a generic partial-state message.
    private static func coverageDetail(in workItems: [WorkItem]) -> String? {
        workItems.lazy.compactMap { item in
            switch item.freshness.status {
            case .partial, .stale, .rateLimited, .failed:
                item.freshness.detail
            default:
                nil
            }
        }.first
    }

    private static func status(
        for freshness: FreshnessState,
        refreshError: String?
    ) -> (status: SynchronizationStatus, detail: String?) {
        switch freshness.status {
        case .fresh:
            return (.upToDate, freshness.detail)
        case .refreshing:
            return (.refreshing, freshness.detail ?? "Updating work for the selected organization.")
        case .stale:
            return (.partial, freshness.detail ?? "Cached work may be out of date.")
        case .partial:
            return (.partial, freshness.detail ?? refreshError ?? "Some work could not be refreshed.")
        case .offline:
            return (.offline, freshness.detail ?? "Showing the most recent local work.")
        case .authenticationRequired:
            return (.signInRequired, freshness.detail ?? "Account access is required before work can refresh.")
        case .ssoRequired:
            return (.ssoRequired, freshness.detail ?? "Authorize this account with your organization to refresh its work.")
        case .approvalRequired:
            return (.approvalRequired, freshness.detail ?? "Your organization must approve this account or application before all work can sync.")
        case .rateLimited:
            return (.partial, freshness.detail ?? "GitHub is temporarily limiting synchronization requests.")
        case .failed:
            return (.partial, freshness.detail ?? refreshError ?? "Some work could not be refreshed.")
        }
    }
}
