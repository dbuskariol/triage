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

    func testUnavailableVaultKeyUsesRecoveryRouteBeforeConnection() {
        let state = makeState(
            accounts: [],
            localAccountRecovery: .unavailableVaultKey
        )

        XCTAssertEqual(
            state.route(completedSteps: []),
            .localAccountRecovery(.unavailableVaultKey)
        )
        XCTAssertEqual(
            OnboardingRoute.localAccountRecovery(.unavailableVaultKey).accessibilityLabel,
            "Local account recovery required before setup"
        )
        XCTAssertEqual(
            LocalAccountRecoveryPresentation.unavailableVaultKey.detail,
            "Triage cannot open encrypted local data for one or more saved accounts. In Account Settings, remove each unavailable account’s local data. This removes data stored on this Mac only; it does not change GitHub. Then reconnect to GitHub to resync."
        )
    }

    func testPureRecoveryOnboardingRetainsItsRouteWhileSharedRestorationIsInFlight() {
        let state = makeState(
            accounts: [],
            isRestoringAccounts: true,
            localAccountRecovery: .encryptedLocalDataUnavailable
        )

        XCTAssertTrue(state.isRestoringAccounts)
        XCTAssertEqual(
            state.route(completedSteps: []),
            .localAccountRecovery(.encryptedLocalDataUnavailable)
        )
    }

    func testGenericEncryptedLocalDataFailureKeepsRecoveryCopySanitized() {
        let recovery = LocalAccountRecoveryPresentation.encryptedLocalDataUnavailable

        XCTAssertFalse(recovery.detail.contains("/"))
        XCTAssertFalse(recovery.detail.localizedCaseInsensitiveContains("keychain"))
        XCTAssertTrue(recovery.detail.contains("Try again"))
        XCTAssertFalse(recovery.detail.localizedCaseInsensitiveContains("remove"))
        XCTAssertFalse(recovery.canOpenAccountSettings)
    }

    func testEncryptedVaultRepairDoesNotImplyAMissingKeyOrAutomaticDeletion() {
        let recovery = LocalAccountRecoveryPresentation.encryptedVaultNeedsRepair

        XCTAssertTrue(recovery.canOpenAccountSettings)
        XCTAssertTrue(recovery.detail.localizedCaseInsensitiveContains("original encrypted data"))
        XCTAssertFalse(recovery.detail.localizedCaseInsensitiveContains("vault key is unavailable"))
        XCTAssertFalse(recovery.detail.localizedCaseInsensitiveContains("remove each unavailable"))
        XCTAssertTrue(recovery.detail.localizedCaseInsensitiveContains("verified migration backup"))
    }

    func testUnavailableVaultRecoveryExposesTheReachableSettingsRemovalPath() {
        XCTAssertTrue(LocalAccountRecoveryPresentation.unavailableVaultKey.canOpenAccountSettings)
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

    func testSSOAuthorizationControlRequiresGitHubAuthorizationURL() {
        let recovery = OnboardingAccessRecovery.ssoRequired(isPartial: true)
        let withoutURL = makeState(access: makeAccess(state: .partialSSOAuthorization))
        let withURL = OnboardingPresentationState(
            accounts: [makeAccount()],
            selectedAccountID: accountID,
            organizations: [makeOrganization()],
            selectedOrganizationID: organizationID,
            organizationAccess: makeAccess(state: .partialSSOAuthorization),
            isConnecting: false,
            isSynchronizing: false,
            connectionError: nil,
            refreshError: nil,
            aiAccess: .consentRequired,
            hasSSOAuthorizationURL: true
        )

        XCTAssertFalse(withoutURL.shouldOfferSSOAuthorization(for: recovery))
        XCTAssertTrue(withURL.shouldOfferSSOAuthorization(for: recovery))
        XCTAssertFalse(withURL.shouldOfferSSOAuthorization(for: .approvalRequired))
    }

    func testAIConsentDisclosureCoversTheRequiredPrivacyDecisions() {
        let disclosure = AIConsentPresentation.disclosure(
            account: makeAccount(),
            organization: makeOrganization()
        )

        XCTAssertTrue(disclosure.contains("octocat"))
        XCTAssertTrue(disclosure.contains("github"))
        XCTAssertTrue(disclosure.contains("GitHub Copilot"))
        XCTAssertTrue(disclosure.contains("GitHub"))
        XCTAssertTrue(disclosure.contains("Model selection"))
        XCTAssertTrue(disclosure.contains("conversation excerpts"))
        XCTAssertTrue(disclosure.contains("AI caches"))
        XCTAssertTrue(disclosure.contains("dashboard works without AI"))
    }

    func testPATSheetSuppressesAParentOAuthConfigurationError() {
        let oauthError = "GitHub sign-in is not configured in this build."

        XCTAssertNil(
            PersonalAccessTokenErrorPresentation.sharedConnectionError(
                oauthError,
                isPresentingPersonalAccessToken: true
            )
        )
        XCTAssertEqual(
            PersonalAccessTokenErrorPresentation.sharedConnectionError(
                oauthError,
                isPresentingPersonalAccessToken: false
            ),
            oauthError
        )
    }

    func testOnlyClassicPATAccountsOfferCredentialReplacement() {
        XCTAssertEqual(
            PersonalAccessTokenReplacementPresentation.action(for: .classicPersonalAccessToken),
            .replaceClassicToken
        )
        XCTAssertEqual(
            PersonalAccessTokenReplacementPresentation.action(for: .fineGrainedPersonalAccessToken),
            .fineGrainedReplacementUnavailable
        )
        XCTAssertNil(PersonalAccessTokenReplacementPresentation.action(for: .oauth))
        XCTAssertEqual(
            PersonalAccessTokenReplacementPresentation.fineGrainedReplacementUnavailable.unavailableDetail,
            "Fine-grained tokens cannot be replaced in place. Connect the new token as a separate account and enter the resource-owner organization selected when you created it."
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
        isRestoringAccounts: Bool = false,
        refreshError: String? = nil,
        localAccountRecovery: LocalAccountRecoveryPresentation? = nil
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
            isRestoringAccounts: isRestoringAccounts,
            connectionError: nil,
            refreshError: refreshError,
            aiAccess: .unavailable("Copilot analysis has not been enabled for this organization."),
            localAccountRecovery: localAccountRecovery
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
