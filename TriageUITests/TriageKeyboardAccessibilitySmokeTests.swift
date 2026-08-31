import XCTest

/// UI smoke coverage deliberately does not manufacture accounts, organizations,
/// or work items. Content-dependent checks skip when the launched app does not
/// expose deterministic seeded workspace content.
@MainActor
final class TriageKeyboardAccessibilitySmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
    }

    func testLaunchesAUsableMainWindow() throws {
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 10),
            "Triage should present a main window after launch."
        )
    }

    func testSidebarAndSearchKeyboardSmokeWhenWorkspaceIsSeeded() throws {
        try requireMainWindow()
        let sidebar = element(named: "Triage sidebar")
        guard sidebar.waitForExistence(timeout: 3) else {
            throw XCTSkip("No deterministic seeded workspace is available for sidebar and search smoke coverage.")
        }

        let search = searchField()
        guard search.waitForExistence(timeout: 3) else {
            throw XCTSkip("The launched workspace has no work-list search field.")
        }

        app.typeKey("f", modifierFlags: .command)

        let query = "keyboard accessibility smoke"
        // `typeText` requires keyboard focus on this element or a descendant,
        // so it is the portable macOS proof that Command-F focused the field.
        search.typeText(query)
        let enteredQuery = search.value as? String
        XCTAssertTrue(enteredQuery?.contains(query) == true, "Focused search should receive keyboard input.")

        app.typeKey(.escape, modifierFlags: [])
        let clearedSearch = NSPredicate(format: "value == '' OR value == %@", "Search work")
        expectation(for: clearedSearch, evaluatedWith: search)
        waitForExpectations(timeout: 2)
    }

    func testInspectorHeadingsAndLocalWorkflowSemanticsWhenWorkIsSeeded() throws {
        try requireMainWindow()
        let inspectorToggle = app.buttons["work-detail-inspector-toggle"]
        guard inspectorToggle.waitForExistence(timeout: 3) else {
            throw XCTSkip("No deterministic selected work item is available for detail and inspector smoke coverage.")
        }

        for heading in ["Sync and coverage", "Why this is here", "Action items", "Evidence and provenance"] {
            XCTAssertTrue(
                element(named: heading).exists,
                "Detail should expose the \(heading) accessibility heading."
            )
        }

        inspectorToggle.click()
        let inspector = element(named: "work-inspector")
        XCTAssertTrue(inspector.waitForExistence(timeout: 3), "Inspector should open from its keyboard-accessible toggle.")

        let archive = app.buttons["work-inspector-archive"]
        XCTAssertTrue(archive.exists, "Inspector should expose the local archive action.")
        XCTAssertTrue(
            element(named: "These controls change only Triage's encrypted local workflow state. They do not modify GitHub.").exists,
            "Inspector should state that workflow actions are local-only."
        )
    }

    func testSettingsRemovalCancelWhenAccountIsSeeded() throws {
        try requireMainWindow()
        app.typeKey(",", modifierFlags: .command)

        let settingsWindow = app.windows["Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3), "Command-Comma should open Settings.")

        let remove = settingsWindow.buttons["Remove…"]
        guard remove.waitForExistence(timeout: 3) else {
            throw XCTSkip("No deterministic connected account is available for Settings removal-cancel coverage.")
        }

        remove.click()
        let cancel = settingsWindow.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 2), "Removal confirmation should offer Cancel.")
        cancel.click()

        XCTAssertTrue(remove.exists, "Cancelling account removal must leave the account action available.")
    }

    private func requireMainWindow() throws {
        guard app.windows.firstMatch.waitForExistence(timeout: 10) else {
            XCTFail("Triage did not present a main window.")
            throw XCTSkip("No window is available for content-dependent smoke coverage.")
        }
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
