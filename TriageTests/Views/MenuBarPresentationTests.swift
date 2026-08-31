import XCTest
@testable import Triage

@MainActor
final class MenuBarPresentationTests: XCTestCase {
    private let accountID = AccountID(rawValue: "menu-account")!
    private let organizationID = OrganizationID(rawValue: "menu-organization")!
    private let now = Date(timeIntervalSinceReferenceDate: 10_000)

    func testMenuBarUsesTheSameFreshnessCoverageAndVisibilityInputsAsWorkspace() {
        let workspaceFreshness = FreshnessState(status: .fresh)
        let coverage = CoverageEvaluation(
            freshness: FreshnessState(
                status: .partial,
                detail: "Review coverage is incomplete."
            ),
            missing: []
        )
        let visibilityFreshness = FreshnessState(status: .fresh)

        let menuPresentation = makeMenuPresentation(
            workspaceFreshness: workspaceFreshness,
            workspaceCoverage: coverage,
            organizationVisibilityFreshness: visibilityFreshness,
            restorationError: nil
        )
        let workspacePresentation = WorkspacePresentationState(
            workItems: [],
            selectedAccountID: accountID,
            selectedOrganizationID: organizationID,
            organizationAccess: nil,
            hasSSOAuthorizationHeader: false,
            isRefreshing: false,
            refreshError: nil,
            workspaceFreshness: workspaceFreshness,
            workspaceCoverage: coverage,
            organizationVisibilityFreshness: visibilityFreshness,
            restorationError: nil,
            now: now
        )

        XCTAssertEqual(menuPresentation, workspacePresentation)
        XCTAssertEqual(menuPresentation.synchronizationStatus, .partial)
        XCTAssertEqual(menuPresentation.synchronizationDetail, "Review coverage is incomplete.")
    }

    func testMenuBarUsesTheWorkspaceRestorationUnavailableStateWithoutLeakingDetails() {
        let menuPresentation = makeMenuPresentation(
            workspaceFreshness: FreshnessState(status: .fresh),
            workspaceCoverage: CoverageEvaluation(
                freshness: FreshnessState(status: .fresh),
                missing: []
            ),
            organizationVisibilityFreshness: FreshnessState(status: .fresh),
            restorationError: "/private/path/to/encrypted-vault.sqlite"
        )

        XCTAssertEqual(menuPresentation.synchronizationStatus, .unavailable)
        XCTAssertEqual(
            menuPresentation.synchronizationDetail,
            "Triage could not load local work for this organization."
        )
        XCTAssertFalse(menuPresentation.synchronizationDetail?.contains("/private/path") ?? true)
    }

    private func makeMenuPresentation(
        workspaceFreshness: FreshnessState,
        workspaceCoverage: CoverageEvaluation,
        organizationVisibilityFreshness: FreshnessState,
        restorationError: String?
    ) -> WorkspacePresentationState {
        MenuBarView.workspacePresentation(
            workItems: [],
            selectedAccountID: accountID,
            selectedOrganizationID: organizationID,
            organizationAccess: nil,
            hasSSOAuthorizationHeader: false,
            isRefreshing: false,
            refreshError: nil,
            workspaceFreshness: workspaceFreshness,
            workspaceCoverage: workspaceCoverage,
            organizationVisibilityFreshness: organizationVisibilityFreshness,
            restorationError: restorationError,
            now: now
        )
    }
}
