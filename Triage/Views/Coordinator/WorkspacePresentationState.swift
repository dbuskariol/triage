import Foundation

struct WorkspacePresentationState: Equatable {
    enum SynchronizationStatus: Equatable {
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

    init(
        workItems: [WorkItem],
        selectedAccountID: AccountID?,
        selectedOrganizationID: OrganizationID?,
        organizationAccess: OrganizationAccess?,
        hasSSOAuthorizationHeader: Bool,
        isRefreshing: Bool,
        refreshError: String?,
        now: Date
    ) {
        self.selectedAccountID = selectedAccountID
        self.selectedOrganizationID = selectedOrganizationID
        sectionCounts = AppSection.allCases.map { section in
            SectionCount(
                section: section,
                count: Self.count(for: section, in: workItems, at: now)
            )
        }

        let status = Self.status(
            workItems: workItems,
            organizationAccess: organizationAccess,
            hasSSOAuthorizationHeader: hasSSOAuthorizationHeader,
            isRefreshing: isRefreshing,
            refreshError: refreshError
        )
        synchronizationStatus = status.status
        synchronizationDetail = status.detail
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
        organizationAccess: OrganizationAccess?,
        hasSSOAuthorizationHeader: Bool,
        isRefreshing: Bool,
        refreshError: String?
    ) -> (status: SynchronizationStatus, detail: String?) {
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

        if let offlineItem = workItems.first(where: { $0.freshness.status == .offline }) {
            return (.offline, offlineItem.freshness.detail ?? "Showing the most recent local work.")
        }

        if workItems.contains(where: {
            $0.freshness.status == .partial
                || $0.freshness.status == .stale
                || $0.freshness.status == .rateLimited
                || $0.freshness.status == .failed
        }) {
            return (.partial, refreshError ?? "Some work could not be refreshed.")
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

        if workItems.contains(where: { $0.freshness.status == .fresh }) {
            return (.upToDate, nil)
        }

        return (.unavailable, refreshError)
    }
}
