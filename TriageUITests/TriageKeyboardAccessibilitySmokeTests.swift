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
        XCTAssertTrue(visibleButton(named: "Use a Personal Access Token").exists)
    }

    func testAccountRecoveryFixtureShowsSanitizedRecoveryControls() throws {
        launchFixture(scenario: "account-recovery")

        XCTAssertTrue(element(named: "local-account-recovery-notice").waitForExistence(timeout: 10))
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
            workRow(containing: "Fixture Acme keyboard accessibility smoke").waitForExistence(timeout: 10),
            "Partial access must retain already synchronized local work."
        )
        let partialStatus = app.staticTexts.matching(
            NSPredicate(
                format: "label BEGINSWITH %@ OR value BEGINSWITH %@",
                "Partial access",
                "Partial access"
            )
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
            element(containing: "GitHub sign-in is unavailable in the local UI fixture.").waitForExistence(timeout: 5)
        )

        let tokenChoice = visibleButton(named: "Use a Personal Access Token")
        XCTAssertTrue(tokenChoice.waitForExistence(timeout: 5))
        tokenChoice.click()
        let sheet = element(named: "personal-access-token-entry-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["GitHub personal access token"].exists)
        XCTAssertTrue(
            element(containing: "Fine-grained tokens are preferred").exists,
            "The PAT sheet should explain the preferred token type without depending on AppKit's exact punctuation exposure."
        )
        let sheetOAuthError = sheet.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                "GitHub sign-in is unavailable in the local UI fixture.",
                "GitHub sign-in is unavailable in the local UI fixture."
            )
        )
        XCTAssertFalse(
            sheetOAuthError.firstMatch.exists,
            "A parent OAuth failure must not be repeated in the independent PAT sheet."
        )
    }

    func testClassicPATReplacementFixtureExposesReplacementSheet() throws {
        launchFixture(scenario: "personal-access-token-replacement")
        try requireMainWindow()
        app.typeKey(",", modifierFlags: .command)

        let settingsWindow = settingsWindow()
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

        let settingsWindow = settingsWindow()
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
        let accounts = settingsWindow.descendants(matching: .any)["Accounts"]
        XCTAssertTrue(accounts.waitForExistence(timeout: 3))
        accounts.click()
        let addAccount = settingsWindow.buttons["Add Account…"]
        XCTAssertTrue(addAccount.waitForExistence(timeout: 5))
        addAccount.click()
        let tokenChoice = visibleButton(named: "Use a Personal Access Token")
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

        let selectedRow = workRow(containing: "Fixture Acme keyboard accessibility smoke")
        XCTAssertTrue(selectedRow.waitForExistence(timeout: 5))
        selectedRow.click()

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

        let settingsWindow = settingsWindow()
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3), "Command-Comma should open Settings.")
        XCTAssertEqual(
            settingsWindow.buttons.matching(identifier: "Hide Sidebar").count,
            1,
            "Settings should expose one native sidebar control in its toolbar."
        )

        let accounts = settingsWindow.descendants(matching: .any)["Accounts"]
        XCTAssertTrue(accounts.waitForExistence(timeout: 3), "Settings should expose the Accounts section.")
        accounts.click()

        let remove = visibleButton(named: "Remove…", in: settingsWindow)
        XCTAssertTrue(remove.waitForExistence(timeout: 5))

        remove.click()
        let removalConfirmation = settingsWindow.sheets.firstMatch
        XCTAssertTrue(removalConfirmation.waitForExistence(timeout: 2))
        XCTAssertTrue(
            removalConfirmation.staticTexts
                .matching(NSPredicate(format: "value == %@", "Remove fixture-primary?"))
                .firstMatch
                .exists
        )
        let cancel = visibleButton(named: "Cancel", in: removalConfirmation)
        XCTAssertTrue(cancel.waitForExistence(timeout: 2), "Removal confirmation should offer Cancel.")
        cancel.click()

        XCTAssertTrue(remove.exists, "Cancelling account removal must leave the account action available.")
    }

    func testAIConsentIsExplicitAndFailClosedInSettings() throws {
        try requireMainWindow()
        app.typeKey(",", modifierFlags: .command)
        let settingsWindow = settingsWindow()
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
        let ai = settingsWindow.descendants(matching: .any)["AI"]
        XCTAssertTrue(ai.waitForExistence(timeout: 3))
        ai.click()
        XCTAssertTrue(
            settingsWindow.descendants(matching: .any)["Allow AI analysis for Fixture Acme (@fixture-acme)"].waitForExistence(timeout: 5),
            "Fixture Settings should retain per-organization consent controls."
        )
        XCTAssertTrue(element(named: "Consent required").waitForExistence(timeout: 5))
        let connect = settingsWindow.buttons["Connect Copilot"]
        XCTAssertTrue(connect.exists)
        XCTAssertFalse(connect.isEnabled, "The fixture has not granted organization AI consent.")
        XCTAssertLessThanOrEqual(connect.frame.maxX, settingsWindow.frame.maxX)
        XCTAssertGreaterThanOrEqual(connect.frame.minX, settingsWindow.frame.minX)
    }

    func testAccountAndOrganizationSwitchingRestoresFixtureScope() throws {
        try requireMainWindow()
        selectPopupItem(named: "Account", item: "Fixture Secondary")
        XCTAssertTrue(workRow(containing: "Fixture Studio account switch work").waitForExistence(timeout: 5))

        app.terminate()
        launchFixture(reset: false)
        XCTAssertTrue(workRow(containing: "Fixture Studio account switch work").waitForExistence(timeout: 5))

        selectPopupItem(named: "Account", item: "Fixture Primary")
        selectPopupItem(named: "Organization", item: "Fixture Beta")
        XCTAssertTrue(workRow(containing: "Fixture Beta notification route work").waitForExistence(timeout: 5))
    }

    func testNotificationRouteSelectsItsLocalFixtureWork() throws {
        launchFixture(scenario: "notification-route")
        XCTAssertTrue(workRow(containing: "Fixture Beta notification route work").waitForExistence(timeout: 10))
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
        let pickerIdentifier: String
        switch label {
        case "Account":
            pickerIdentifier = "workspace-account-picker"
        case "Organization":
            pickerIdentifier = "workspace-organization-picker"
        default:
            XCTFail("No stable workspace picker identifier is defined for \(label).")
            return
        }
        let popup = app.descendants(matching: .any)[pickerIdentifier]
        XCTAssertTrue(popup.waitForExistence(timeout: 5), "Expected \(label) picker in the deterministic workspace.")
        popup.click()
        let menuItem = popup.menuItems.matching(NSPredicate(format: "title == %@", item)).firstMatch
        XCTAssertTrue(menuItem.waitForExistence(timeout: 3), "Expected \(item) in the \(label) picker.")
        menuItem.click()
    }

    private func element(named identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func element(containing text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text))
            .firstMatch
    }

    private func workRow(containing title: String) -> XCUIElement {
        app.outlines["work-list"].descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", title, title))
            .firstMatch
    }

    private func visibleButton(named label: String, in container: XCUIElement? = nil) -> XCUIElement {
        let buttons = (container ?? app).buttons.matching(NSPredicate(format: "label == %@", label))
        return firstHittableElement(in: buttons)
    }

    private func firstHittableElement(in query: XCUIElementQuery) -> XCUIElement {
        query.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? query.firstMatch
    }

    private func searchField() -> XCUIElement {
        let candidates = [
            app.searchFields["Search work"],
            app.textFields["Search work"],
            element(named: "Search work")
        ]
        return candidates.first(where: { $0.exists }) ?? candidates[0]
    }

    private func settingsWindow() -> XCUIElement {
        app.windows["Triage Settings"]
    }
}
