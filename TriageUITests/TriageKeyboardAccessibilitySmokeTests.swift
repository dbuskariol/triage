import XCTest

/// Launches the DEBUG-only, local fixture composition. The fixture is gated by
/// both a launch argument and environment variable, uses a per-test defaults
/// suite and vault root, and never creates a GitHub client or reads credentials.
@MainActor
final class TriageKeyboardAccessibilitySmokeTests: XCTestCase {
    private var app: XCUIApplication!
    private let session = UUID().uuidString.lowercased()

    override func setUp() async throws {
        continueAfterFailure = false
        launchFixture()
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
    }

    func testOnboardingRouteIsAvailableWithoutCredentials() throws {
        launchFixture(scenario: "onboarding")
        XCTAssertTrue(element(named: "Step 1 of 7: connect a GitHub account").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Continue with GitHub"].exists)
        XCTAssertTrue(app.buttons["Use a Personal Access Token"].exists)
    }

    func testAccountRecoveryFixtureShowsSanitizedRecoveryControls() throws {
        launchFixture(scenario: "account-recovery")

        let recoveryCopy = "Recover encrypted local account data. Triage cannot open encrypted local data for one or more saved accounts. In Account Settings, remove each unavailable account’s local data. This removes data stored on this Mac only; it does not change GitHub. Then reconnect to GitHub to resync."
        XCTAssertTrue(element(named: recoveryCopy).waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Open Account Settings…"].exists)
        XCTAssertTrue(app.buttons["Try Again"].exists)

        let rawIdentity = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "fixture-unavailable-account")
        )
        XCTAssertEqual(rawIdentity.count, 0, "Recovery UI must not expose its opaque local account identity.")
    }

    func testPartialAccessFixtureRetainsCachedWorkWithoutBrowserAuthorization() throws {
        launchFixture(scenario: "partial-access")
        try requireMainWindow()

        XCTAssertTrue(
            element(named: "Fixture Acme keyboard accessibility smoke").waitForExistence(timeout: 10),
            "Partial access must retain already synchronized local work."
        )
        let partialStatus = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Partial access")
        )
        XCTAssertTrue(partialStatus.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.buttons["Authorize in Browser"].exists,
            "Partial access without an authorization-required URL must not offer a browser action."
        )
    }

    func testPATEntrySheetHidesFixtureOAuthErrorAndExposesLayout() throws {
        launchFixture(scenario: "personal-access-token")

        let oauth = app.buttons["Continue with GitHub"]
        XCTAssertTrue(oauth.waitForExistence(timeout: 10))
        oauth.click()
        XCTAssertTrue(
            element(named: "GitHub sign-in is unavailable in the local UI fixture.").waitForExistence(timeout: 5)
        )

        app.buttons["Use a Personal Access Token"].click()
        let sheet = element(named: "personal-access-token-entry-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["GitHub personal access token"].exists)
        XCTAssertTrue(
            element(named: "Fine-grained tokens are preferred. Classic tokens should include `repo` and `read:org`.").exists
        )
        XCTAssertFalse(
            element(named: "GitHub sign-in is unavailable in the local UI fixture.").exists,
            "A parent OAuth failure must not be repeated in the independent PAT sheet."
        )
    }

    func testClassicPATReplacementFixtureExposesReplacementSheet() throws {
        launchFixture(scenario: "personal-access-token-replacement")
        try requireMainWindow()
        app.typeKey(",", modifierFlags: .command)

        let settingsWindow = app.windows["Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
        let accounts = settingsWindow.descendants(matching: .any)["Accounts"]
        XCTAssertTrue(accounts.waitForExistence(timeout: 3))
        accounts.click()
        let replace = settingsWindow.buttons["Replace Token"]
        XCTAssertTrue(replace.waitForExistence(timeout: 5))
        replace.click()

        let sheet = element(named: "personal-access-token-replacement-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["GitHub personal access token"].exists)
        XCTAssertTrue(
            element(named: "Triage validates that the new token belongs to this GitHub account before replacing the Keychain credential.").exists
        )
    }

    func testAddAccountFixtureExposesOwnerQualifiedPATEntryWithoutRemovingAccounts() throws {
        launchFixture(scenario: "personal-access-token-replacement")
        try requireMainWindow()
        app.typeKey(",", modifierFlags: .command)

        let settingsWindow = app.windows["Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
        let accounts = settingsWindow.descendants(matching: .any)["Accounts"]
        XCTAssertTrue(accounts.waitForExistence(timeout: 3))
        accounts.click()
        let addAccount = settingsWindow.buttons["Add Account…"]
        XCTAssertTrue(addAccount.waitForExistence(timeout: 5))
        addAccount.click()
        let tokenChoice = app.buttons["Use a Personal Access Token"]
        XCTAssertTrue(tokenChoice.waitForExistence(timeout: 3))
        tokenChoice.click()

        let sheet = element(named: "personal-access-token-entry-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["GitHub personal access token"].exists)
        XCTAssertTrue(
            element(named: "Triage stores the token only in your macOS Keychain and uses GitHub read APIs.").exists
        )
        XCTAssertTrue(
            element(named: "Fixture Primary").exists,
            "Opening Add Account must retain the existing local account."
        )
    }

    func testSeededWorkspaceSupportsKeyboardSearchInspectorAndAccessibility() throws {
        try requireMainWindow()
        let sidebar = element(named: "Triage sidebar")
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))

        // Cmd-Control-S is the standard View-menu sidebar toggle. Exercise it
        // before other focused commands so an accidental duplicate shortcut
        // cannot route to a workflow action instead.
        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertFalse(sidebar.waitForExistence(timeout: 2))
        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(sidebar.waitForExistence(timeout: 2))

        let search = searchField()
        XCTAssertTrue(search.waitForExistence(timeout: 5))

        app.typeKey("f", modifierFlags: .command)

        let query = "keyboard accessibility"
        // `typeText` requires keyboard focus on this element or a descendant,
        // so it is the portable macOS proof that Command-F focused the field.
        search.typeText(query)
        let enteredQuery = search.value as? String
        XCTAssertTrue(enteredQuery?.contains(query) == true, "Focused search should receive keyboard input.")

        app.typeKey(.escape, modifierFlags: [])
        let clearedSearch = NSPredicate(format: "value == '' OR value == %@", "Search work")
        expectation(for: clearedSearch, evaluatedWith: search)
        waitForExpectations(timeout: 2)

        let inspectorToggle = app.buttons["work-detail-inspector-toggle"]
        XCTAssertTrue(inspectorToggle.waitForExistence(timeout: 5))

        for heading in [
            "Source",
            "Sync and coverage",
            "Why this is here",
            "Action items",
            "Related content",
            "Review state",
            "Project context",
            "Timeline",
            "Evidence and provenance"
        ] {
            XCTAssertTrue(
                element(named: heading).exists,
                "Detail should expose the \(heading) accessibility heading."
            )
        }

        app.typeKey("i", modifierFlags: [.command, .option])
        let inspector = element(named: "work-inspector")
        XCTAssertTrue(inspector.waitForExistence(timeout: 3), "Inspector should open from its keyboard-accessible toggle.")

        let archive = app.buttons["work-inspector-archive"]
        XCTAssertTrue(archive.exists, "Inspector should expose the local archive action.")
        XCTAssertTrue(
            element(named: "These controls change only Triage's encrypted local workflow state. They do not modify GitHub.").exists,
            "Inspector should state that workflow actions are local-only."
        )
    }

    func testSettingsAndAccountRemovalCancelRemainLocal() throws {
        try requireMainWindow()
        app.typeKey(",", modifierFlags: .command)

        let settingsWindow = app.windows["Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3), "Command-Comma should open Settings.")

        let accounts = settingsWindow.descendants(matching: .any)["Accounts"]
        XCTAssertTrue(accounts.waitForExistence(timeout: 3), "Settings should expose the Accounts section.")
        accounts.click()

        let remove = settingsWindow.buttons["Remove…"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))

        remove.click()
        let cancel = settingsWindow.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 2), "Removal confirmation should offer Cancel.")
        cancel.click()

        XCTAssertTrue(remove.exists, "Cancelling account removal must leave the account action available.")
    }

    func testAIConsentIsExplicitAndFailClosedInSettings() throws {
        try requireMainWindow()
        app.typeKey(",", modifierFlags: .command)
        let settingsWindow = app.windows["Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
        let ai = settingsWindow.descendants(matching: .any)["AI"]
        XCTAssertTrue(ai.waitForExistence(timeout: 3))
        ai.click()
        XCTAssertTrue(
            settingsWindow.descendants(matching: .any)["Allow AI analysis for Fixture Acme (@fixture-acme)"].waitForExistence(timeout: 5),
            "Fixture Settings should retain per-organization consent controls."
        )
        XCTAssertTrue(element(named: "Blocked").waitForExistence(timeout: 5))
    }

    func testAccountAndOrganizationSwitchingRestoresFixtureScope() throws {
        try requireMainWindow()
        selectPopupItem(named: "Account", item: "Fixture Secondary")
        XCTAssertTrue(element(named: "Fixture Studio account switch work").waitForExistence(timeout: 5))

        app.terminate()
        launchFixture(reset: false)
        XCTAssertTrue(element(named: "Fixture Studio account switch work").waitForExistence(timeout: 5))

        selectPopupItem(named: "Account", item: "Fixture Primary")
        selectPopupItem(named: "Organization", item: "Fixture Beta")
        XCTAssertTrue(element(named: "Fixture Beta notification route work").waitForExistence(timeout: 5))
    }

    func testNotificationRouteSelectsItsLocalFixtureWork() throws {
        launchFixture(scenario: "notification-route")
        XCTAssertTrue(element(named: "Fixture Beta notification route work").waitForExistence(timeout: 10))
    }

    private func requireMainWindow() throws {
        guard app.windows.firstMatch.waitForExistence(timeout: 10) else {
            XCTFail("Triage did not present a main window.")
            throw NSError(domain: "TriageUITests", code: 1)
        }
    }

    private func launchFixture(scenario: String = "workspace", reset: Bool = true) {
        app?.terminate()
        let fixtureApp = XCUIApplication()
        fixtureApp.launchArguments = ["-triage-ui-fixture"]
        fixtureApp.launchEnvironment = [
            "TRIAGE_UI_TEST_MODE": "1",
            "TRIAGE_UI_TEST_SCENARIO": scenario,
            "TRIAGE_UI_TEST_SESSION": session,
            "TRIAGE_UI_TEST_RESET": reset ? "1" : "0"
        ]
        fixtureApp.launch()
        app = fixtureApp
    }

    private func selectPopupItem(named label: String, item: String) {
        let popup = app.popUpButtons[label]
        XCTAssertTrue(popup.waitForExistence(timeout: 5), "Expected \(label) picker in the deterministic workspace.")
        popup.click()
        let menuItem = app.menuItems[item]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 3), "Expected \(item) in the \(label) picker.")
        menuItem.click()
    }

    private func element(named identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func searchField() -> XCUIElement {
        let candidates = [
            app.searchFields["Search work"],
            app.textFields["Search work"],
            element(named: "Search work")
        ]
        return candidates.first(where: { $0.exists }) ?? candidates[0]
    }
}
