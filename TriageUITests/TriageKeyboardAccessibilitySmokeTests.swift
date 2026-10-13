import XCTest

/// Launches the DEBUG-only, local fixture composition. The fixture is gated by
/// both a launch argument and environment variable, uses a per-session
/// preferences suite and temporary encrypted vaults, and never reads
/// credentials or contacts GitHub or Copilot.
@MainActor
final class TriageKeyboardAccessibilitySmokeTests: XCTestCase {
    private var app: XCUIApplication!
    private let session = UUID().uuidString.lowercased()

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    // MARK: Onboarding and account recovery

    func testOnboardingRouteIsAvailableWithoutCredentials() throws {
        launchFixture(scenario: "onboarding")
        let getStarted = app.buttons["Get Started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 10), "Without an account, Triage opens the Setup Assistant.")
        XCTAssertFalse(
            app.buttons["Organization"].isEnabled,
            "Steps after the required GitHub step stay unavailable until an account is connected."
        )

        getStarted.click()
        XCTAssertTrue(element(containing: "Connect GitHub").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Continue with GitHub"].exists)
        XCTAssertTrue(app.links["Use a personal access token instead…"].exists)
        XCTAssertFalse(app.buttons["Continue"].isEnabled, "GitHub is a required step.")
    }

    func testAccountRecoveryFixtureShowsSanitizedRecoveryControls() throws {
        launchFixture(scenario: "account-recovery")
        let getStarted = app.buttons["Get Started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 10), "With no usable account, Triage offers setup again.")
        getStarted.click()

        XCTAssertTrue(element(containing: "Some local account data needs attention").waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "cannot be opened. Remove it in Settings, then reconnect.").exists)
        XCTAssertTrue(app.buttons["Try Again"].exists)

        let rawIdentity = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "00000000-0000-4000-8000", "00000000-0000-4000-8000")
        )
        XCTAssertEqual(rawIdentity.count, 0, "Recovery UI must not expose its opaque local account identity.")

        let settings = openSettings(category: "Accounts")
        XCTAssertTrue(settings.staticTexts["Needs Attention"].waitForExistence(timeout: 5))
        XCTAssertTrue(settings.buttons["Try Again"].exists)
    }

    // MARK: Refresh failure

    func testRefreshFailureRetainsSavedWorkWithoutBrowserAuthorization() throws {
        launchFixture(scenario: "refresh-failure")
        try requireMainWindow()

        XCTAssertTrue(
            workRow(containing: "Fixture Acme keyboard accessibility smoke").waitForExistence(timeout: 10),
            "A failed refresh must keep already saved local work."
        )
        // The status banner is one combined accessibility element: message, then its actions.
        let banner = element(containing: "GitHub search timed out repeatedly. Showing saved work")
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        XCTAssertTrue(banner.label.hasSuffix("Retry"), "A failed refresh offers Retry.")
        XCTAssertFalse(
            element(containing: "Authorize on GitHub").exists,
            "A refresh failure that isn't single sign-on must not offer browser authorization."
        )
    }

    // MARK: Personal access tokens

    func testPATEntrySheetHidesOAuthErrorAndExplainsTokenSetup() throws {
        launchFixture(scenario: "personal-access-token")
        let getStarted = app.buttons["Get Started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 10))
        getStarted.click()

        let oauth = app.buttons["Continue with GitHub"]
        XCTAssertTrue(oauth.waitForExistence(timeout: 5))
        oauth.click()
        let oauthError = "GitHub sign-in isn't configured in this build."
        XCTAssertTrue(element(containing: oauthError).waitForExistence(timeout: 5))

        let tokenChoice = app.links["Use a personal access token instead…"]
        XCTAssertTrue(tokenChoice.exists)
        tokenChoice.click()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.secureTextFields.firstMatch.exists)
        XCTAssertEqual(sheet.textFields.firstMatch.placeholderValue, "e.g. acme", "The sheet asks for the token's organization.")
        for text in ["Get a token on GitHub", "Paste the token", "Create a fine-grained token", "Recommended"] {
            XCTAssertTrue(element(containing: text, in: sheet).exists, "The token sheet should explain: \(text)")
        }
        XCTAssertFalse(sheet.buttons["Connect"].isEnabled, "Connect stays disabled until a token is entered.")
        XCTAssertFalse(
            element(containing: oauthError, in: sheet).exists,
            "A parent OAuth failure must not be repeated in the independent token sheet."
        )

        sheet.buttons["Cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }

    func testClassicPATReplacementFixtureExposesReplacementSheet() throws {
        launchFixture(scenario: "personal-access-token-replacement")
        try requireMainWindow()
        let settings = openSettings(category: "Accounts")

        chooseAccountAction("Replace Token…", for: "fixture-primary", in: settings)

        let sheet = settings.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.secureTextFields.firstMatch.exists)
        for text in ["Get a new token for @fixture-primary", "Regenerate your current token", "Paste the new token"] {
            XCTAssertTrue(element(containing: text, in: sheet).exists, "The replacement sheet should explain: \(text)")
        }
        XCTAssertFalse(sheet.buttons["Replace Token"].isEnabled, "Replace stays disabled until a token is entered.")

        sheet.buttons["Cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }

    func testAddAccountFixtureExposesOwnerQualifiedPATEntryWithoutRemovingAccounts() throws {
        launchFixture(scenario: "personal-access-token-replacement")
        try requireMainWindow()
        let settings = openSettings(category: "Accounts")

        let addAccount = settings.buttons["Add Account…"]
        XCTAssertTrue(addAccount.waitForExistence(timeout: 5))
        addAccount.click()
        let dialog = settings.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 3))
        XCTAssertTrue(element(containing: "Add a GitHub Account", in: dialog).exists)
        XCTAssertTrue(dialog.buttons["Continue with GitHub"].exists)
        let tokenChoice = dialog.buttons["Use a Personal Access Token"]
        XCTAssertTrue(tokenChoice.exists)
        tokenChoice.click()

        let sheet = settings.sheets.firstMatch
        XCTAssertTrue(element(containing: "Connect with a Personal Access Token", in: sheet).waitForExistence(timeout: 5))
        XCTAssertEqual(
            sheet.textFields.firstMatch.placeholderValue, "e.g. acme",
            "Fine-grained tokens need their resource owner."
        )
        XCTAssertTrue(sheet.secureTextFields.firstMatch.exists)
        XCTAssertTrue(element(containing: "Stored in your Keychain.", in: sheet).exists)

        sheet.buttons["Cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(
            element(containing: "Fixture Primary", in: settings).exists,
            "Opening Add Account must retain the existing local account."
        )
    }

    // MARK: Workspace

    func testSeededWorkspaceSupportsKeyboardSearchDetailAndLocalActions() throws {
        launchFixture()
        try requireMainWindow()
        let title = "Fixture Acme keyboard accessibility smoke"
        let followUp = "Fixture Acme follow-up issue"
        XCTAssertTrue(workRow(containing: title).waitForExistence(timeout: 10))

        // The toolbar's sidebar control collapses and restores the sidebar.
        let hideSidebar = app.buttons["Hide Sidebar"]
        XCTAssertTrue(hideSidebar.exists)
        hideSidebar.click()
        XCTAssertTrue(app.buttons["Show Sidebar"].waitForExistence(timeout: 3))
        app.buttons["Show Sidebar"].click()
        XCTAssertTrue(app.buttons["Hide Sidebar"].waitForExistence(timeout: 3))
        XCTAssertTrue(element(named: "Triage sidebar").isHittable)

        // Command-F focuses search; `typeText` requires keyboard focus on the
        // field, so it is the portable macOS proof that the shortcut worked.
        let search = app.searchFields["Search work"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        app.typeKey("f", modifierFlags: .command)
        search.typeText("follow-up")
        XCTAssertTrue((search.value as? String)?.contains("follow-up") == true, "Focused search should receive keyboard input.")
        XCTAssertTrue(workRow(containing: title).waitForNonExistence(timeout: 5), "Search filters the list in place.")
        XCTAssertTrue(workRow(containing: followUp).exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(workRow(containing: title).waitForExistence(timeout: 5), "Escape clears the search.")

        // Keyboard selection: Go To ▸ Next and Previous Item.
        workRow(containing: title).click()
        XCTAssertTrue(workCell(containing: title).isSelected)
        app.typeKey(.downArrow, modifierFlags: [.command, .option])
        XCTAssertTrue(waitForSelection(of: followUp))
        app.typeKey(.upArrow, modifierFlags: [.command, .option])
        XCTAssertTrue(waitForSelection(of: title))

        for heading in ["Status", "Why you’re seeing this", "Description", "Recent activity"] {
            XCTAssertTrue(
                app.staticTexts[heading].waitForExistence(timeout: 5),
                "Detail should expose the \(heading) heading."
            )
        }
        XCTAssertTrue(element(containing: "Deterministic fixture decision: your review is requested.").exists)
        XCTAssertTrue(app.buttons["Open on GitHub"].exists)

        // Mark Done (Command-E) changes only Triage's local state.
        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(workRow(containing: title).waitForNonExistence(timeout: 5), "Mark Done removes the item from the Inbox.")
        app.typeKey("6", modifierFlags: .command)
        XCTAssertTrue(app.outlines["Done work"].waitForExistence(timeout: 5), "Command-6 opens Done.")
        XCTAssertTrue(workRow(containing: title).waitForExistence(timeout: 5), "Done work is listed under Done.")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(workRow(containing: followUp).waitForExistence(timeout: 5), "Command-1 returns to the Inbox.")
    }

    func testSettingsAndAccountRemovalCancelRemainLocal() throws {
        launchFixture()
        try requireMainWindow()
        let settings = openSettings(category: "Accounts")
        XCTAssertTrue(element(containing: "Fixture Primary", in: settings).waitForExistence(timeout: 5))

        chooseAccountAction("Remove…", for: "fixture-primary", in: settings)

        let confirmation = settings.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        XCTAssertTrue(element(containing: "Remove fixture-primary?", in: confirmation).exists)
        XCTAssertTrue(confirmation.buttons["Remove Account and Local Data"].exists)
        let cancel = confirmation.buttons["Cancel"]
        XCTAssertTrue(cancel.exists, "Removal confirmation should offer Cancel.")
        cancel.click()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 3))

        XCTAssertTrue(
            element(containing: "Fixture Primary", in: settings).exists,
            "Cancelling account removal must keep the account."
        )
        XCTAssertTrue(settings.menuButtons["account-actions-fixture-primary"].exists)
    }

    func testCopilotConsentIsExplicitAndFailClosedInSettings() throws {
        launchFixture()
        try requireMainWindow()
        let settings = openSettings(category: "Copilot")

        let consent = settings.groups
            .containing(NSPredicate(format: "value == %@", "Use Copilot to prioritize work"))
            .switches.firstMatch
        XCTAssertTrue(consent.waitForExistence(timeout: 5), "Copilot use is a per-organization choice.")
        XCTAssertEqual(consent.value as? Int, 0, "The fixture has not granted organization AI consent.")
        XCTAssertTrue(element(containing: "Fixture Acme", in: settings).exists)
        XCTAssertTrue(element(containing: "Turn on AI analysis to let Copilot prioritize your work.", in: settings).exists)

        let connect = settings.buttons["Connect Copilot…"]
        XCTAssertTrue(connect.exists)
        XCTAssertFalse(connect.isEnabled, "Copilot can't be connected before consent.")
        XCTAssertFalse(settings.buttons["Re-analyze…"].isEnabled)
        XCTAssertLessThanOrEqual(connect.frame.maxX, settings.frame.maxX)
        XCTAssertGreaterThanOrEqual(connect.frame.minX, settings.frame.minX)
    }

    func testAccountAndOrganizationSwitchingRestoresFixtureScope() throws {
        launchFixture()
        try requireMainWindow()
        XCTAssertTrue(workRow(containing: "Fixture Acme keyboard accessibility smoke").waitForExistence(timeout: 10))
        selectPopupItem(named: "Account", item: "Fixture Secondary")
        XCTAssertTrue(workRow(containing: "Fixture Studio account switch work").waitForExistence(timeout: 10))

        app.terminate()
        launchFixture(reset: false)
        XCTAssertTrue(
            workRow(containing: "Fixture Studio account switch work").waitForExistence(timeout: 10),
            "The selected account is restored at the next launch."
        )

        selectPopupItem(named: "Account", item: "Fixture Primary")
        XCTAssertTrue(workRow(containing: "Fixture Acme keyboard accessibility smoke").waitForExistence(timeout: 10))
        selectPopupItem(named: "Organization", item: "Fixture Beta")
        XCTAssertTrue(workRow(containing: "Fixture Beta notification route work").waitForExistence(timeout: 10))
        XCTAssertFalse(workRow(containing: "Fixture Acme keyboard accessibility smoke").exists)
    }

    func testNotificationRouteSelectsItsLocalFixtureWork() throws {
        launchFixture(scenario: "notification-route")
        try requireMainWindow()
        let target = "Fixture Beta notification route work"
        XCTAssertTrue(workRow(containing: target).waitForExistence(timeout: 10))
        XCTAssertEqual(
            app.popUpButtons["workspace-organization-picker"].value as? String,
            "Fixture Beta",
            "Opening a notification switches to its organization."
        )
        XCTAssertTrue(waitForSelection(of: target), "The notification's item is selected, not the list's first item.")
        XCTAssertFalse(workCell(containing: "Fixture Beta release review").isSelected)
    }

    // MARK: Helpers

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

    /// Opens Settings with Command-Comma and selects a category tab.
    private func openSettings(category: String) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Command-Comma should open Settings.")
        let tab = settings.toolbars.buttons[category]
        XCTAssertTrue(tab.waitForExistence(timeout: 3), "Settings should expose the \(category) category.")
        tab.click()
        return settings
    }

    private func chooseAccountAction(_ action: String, for login: String, in settings: XCUIElement) {
        let menu = settings.menuButtons["account-actions-\(login)"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Each account has an actions menu.")
        menu.click()
        let item = menu.menuItems[action]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "Expected \(action) in the account actions menu.")
        item.click()
    }

    private func selectPopupItem(named label: String, item: String) {
        let identifier = label == "Account" ? "workspace-account-picker" : "workspace-organization-picker"
        let popup = app.popUpButtons[identifier]
        XCTAssertTrue(popup.waitForExistence(timeout: 5), "Expected \(label) picker in the deterministic workspace.")
        let menuItem = popup.menuItems[item]
        // Another app's window can swallow the first click on a shared desktop; reopen the menu.
        for _ in 0..<3 where !menuItem.exists {
            popup.click()
            if menuItem.waitForExistence(timeout: 3) { break }
            app.typeKey(.escape, modifierFlags: [])
        }
        XCTAssertTrue(menuItem.exists, "Expected \(item) in the \(label) picker.")
        menuItem.click()
        XCTAssertTrue(
            NSPredicate(format: "value == %@", item).evaluate(with: popup) || waitForValue(item, of: popup),
            "The \(label) picker shows \(item)."
        )
    }

    private func waitForValue(_ value: String, of element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }

    private func element(named identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func element(containing text: String, in container: XCUIElement? = nil) -> XCUIElement {
        (container ?? app).descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text))
            .firstMatch
    }

    /// The work list (labelled "<section> work"), not the sidebar.
    private func workList() -> XCUIElement {
        app.outlines.matching(NSPredicate(format: "label ENDSWITH %@", " work")).firstMatch
    }

    /// A row's combined accessibility element, which includes its title.
    private func workRow(containing title: String) -> XCUIElement {
        workList().descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", title))
            .firstMatch
    }

    /// The list cell that carries a row's selection state.
    private func workCell(containing title: String) -> XCUIElement {
        workList().cells.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    private func waitForSelection(of title: String) -> Bool {
        let cell = workCell(containing: title)
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: cell)
        return XCTWaiter().wait(for: [selected], timeout: 5) == .completed
    }
}
