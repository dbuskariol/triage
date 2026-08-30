import XCTest
@testable import Triage

final class OnboardingPresentationStateTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 10_000)
    private let accountID = AccountID(rawValue: "account")!
    private let organizationID = OrganizationID(rawValue: "github")!

    func testRouteFollowsTheRequiredFirstRunOrder() {
        XCTAssertEqual(
            makeState(accounts: []).route(completedSteps: []),
            .connection
        )

        let connected = makeState()
        XCTAssertEqual(connected.route(completedSteps: []), .identityConfirmation)
        XCTAssertEqual(
            connected.route(completedSteps: [.identity]),
            .organizationSelection
        )
        XCTAssertEqual(
            connected.route(completedSteps: [.identity, .organization]),
            .workflowExplanation
        )
        XCTAssertEqual(
            connected.route(completedSteps: [.identity, .organization, .workflow]),
            .notificationOffer
        )
        XCTAssertEqual(
            connected.route(completedSteps: [.identity, .organization, .workflow, .notifications]),
            .aiConsent
        )
    }

    func testAccessRecoveryTakesPrecedenceOverWorkflowAndHasAccessibleStatus() {
        let state = makeState(access: makeAccess(state: .ssoAuthorizationRequired))
        let route = state.route(completedSteps: [.identity, .organization])

        XCTAssertEqual(route, .accessRecovery(.ssoRequired(isPartial: false)))
        XCTAssertEqual(
            route.accessibilityLabel,
            "Step 4 of 7: recover organization access"
        )
        XCTAssertEqual(
            OnboardingAccessRecovery.ssoRequired(isPartial: false).accessibilityLabel,
            "Authorize organization access. Authorize this account with your organization before Triage can refresh its work."
        )
    }

    func testSynchronizationRoutePrecedesWorkflowExplanation() {
        let state = makeState(isSynchronizing: true)

        XCTAssertEqual(
            state.route(completedSteps: [.identity, .organization]),
            .synchronization
        )
    }

    func testSynchronizationFailureRemainsOnTheRecoveryStep() {
        let state = makeState(refreshError: "Triage could not refresh this organization.")

        XCTAssertEqual(
            state.route(completedSteps: [.identity, .organization]),
            .synchronization
        )
    }

    func testPersonalAccessTokenSubmissionRequiresValidKindAndFineGrainedOwner() {
        XCTAssertFalse(
            OnboardingPersonalAccessTokenForm(
                token: "",
                tokenKind: nil,
                resourceOwnerOrganization: ""
            ).canSubmit
        )
        XCTAssertFalse(
            OnboardingPersonalAccessTokenForm(
                token: "github_pat_example",
                tokenKind: .fineGrained,
                resourceOwnerOrganization: ""
            ).canSubmit
        )
        XCTAssertTrue(
            OnboardingPersonalAccessTokenForm(
                token: "github_pat_example",
                tokenKind: .fineGrained,
                resourceOwnerOrganization: "github"
            ).canSubmit
        )
        XCTAssertTrue(
            OnboardingPersonalAccessTokenForm(
                token: "ghp_example",
                tokenKind: .classic,
                resourceOwnerOrganization: ""
            ).canSubmit
        )
    }

    private func makeState(
        accounts: [GitHubAccount]? = nil,
        access: OrganizationAccess? = nil,
        isSynchronizing: Bool = false,
        refreshError: String? = nil
    ) -> OnboardingPresentationState {
        let accounts = accounts ?? [makeAccount()]
        return OnboardingPresentationState(
            accounts: accounts,
            selectedAccountID: accounts.first?.id,
            organizations: accounts.isEmpty ? [] : [makeOrganization()],
            selectedOrganizationID: accounts.isEmpty ? nil : organizationID,
            organizationAccess: access,
            isConnecting: false,
            isSynchronizing: isSynchronizing,
            connectionError: nil,
            refreshError: refreshError,
            aiAccess: .unavailable("Copilot analysis has not been enabled for this organization.")
        )
    }

    private func makeAccount() -> GitHubAccount {
        GitHubAccount(
            id: accountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_1")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID(rawValue: "credential")!,
            credentialStatus: .active,
            createdAt: now
        )
    }

    private func makeOrganization() -> GitHubOrganization {
        GitHubOrganization(
            id: organizationID,
            githubOrganizationID: 1,
            nodeID: GitHubNodeID(rawValue: "O_1")!,
            login: "github"
        )
    }

    private func makeAccess(state: OrganizationAccessState) -> OrganizationAccess {
        OrganizationAccess(
            accountID: accountID,
            organizationID: organizationID,
            state: state,
            capabilityRevision: CapabilityRevision(rawValue: "revision")!,
            capabilities: [],
            checkedAt: now
        )
    }
}
