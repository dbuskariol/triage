import XCTest
@testable import Triage

@MainActor
final class AppNavigationModelTests: XCTestCase {
    func testSettingsSidebarUsesReadableNativeColumnWidths() {
        XCTAssertEqual(SettingsSidebarLayout.minimumWidth, 240)
        XCTAssertEqual(SettingsSidebarLayout.idealWidth, 260)
        XCTAssertEqual(SettingsSidebarLayout.maximumWidth, 320)
        XCTAssertGreaterThan(SettingsSidebarLayout.idealWidth, SettingsSidebarLayout.minimumWidth)
        XCTAssertGreaterThan(SettingsSidebarLayout.maximumWidth, SettingsSidebarLayout.idealWidth)
        XCTAssertGreaterThanOrEqual(SettingsSidebarLayout.minimumWindowWidth, 800)
        XCTAssertGreaterThan(SettingsSidebarLayout.defaultWindowWidth, SettingsSidebarLayout.minimumWindowWidth)
    }

    func testRestoresPersistedSectionAndSettingsCategory() {
        let suiteName = "AppNavigationModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppSection.reviews.rawValue, forKey: "workspace.selected-section")
        defaults.set(SettingsCategory.notifications.rawValue, forKey: "settings.selected-category")

        let navigation = AppNavigationModel(defaults: defaults)

        XCTAssertEqual(navigation.section, .reviews)
        XCTAssertEqual(navigation.settingsCategory, .notifications)
    }

    func testPersistsNavigationChanges() {
        let suiteName = "AppNavigationModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let navigation = AppNavigationModel(defaults: defaults)

        navigation.section = .waiting
        navigation.settingsCategory = .updates

        XCTAssertEqual(defaults.string(forKey: "workspace.selected-section"), AppSection.waiting.rawValue)
        XCTAssertEqual(defaults.string(forKey: "settings.selected-category"), SettingsCategory.updates.rawValue)
    }

    func testRestoresPresentationChoices() {
        let suiteName = "AppNavigationModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let navigation = AppNavigationModel(defaults: defaults)
        navigation.searchScope = .organization
        navigation.searchSort = .recent
        navigation.listFilter = .openActionItems
        navigation.isInspectorVisible = true
        navigation.isSidebarVisible = false

        let restored = AppNavigationModel(defaults: defaults)

        XCTAssertEqual(restored.searchScope, .organization)
        XCTAssertEqual(restored.searchSort, .recent)
        XCTAssertEqual(restored.listFilter, .openActionItems)
        XCTAssertTrue(restored.isInspectorVisible)
        XCTAssertFalse(restored.isSidebarVisible)
    }

    func testRestoresSelectionOnlyForMatchingAccountAndOrganization() {
        let suiteName = "AppNavigationModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let accountID = AccountID(rawValue: "account-a")!
        let organizationID = OrganizationID(rawValue: "organization-a")!
        let otherOrganizationID = OrganizationID(rawValue: "organization-b")!
        let workItemID = WorkItemID(rawValue: "work-item-a")!
        let navigation = AppNavigationModel(defaults: defaults)

        navigation.setSelectedWorkItem(
            workItemID,
            accountID: accountID,
            organizationID: organizationID
        )

        XCTAssertEqual(
            navigation.validatedSelectedWorkItem(
                accountID: accountID,
                organizationID: organizationID,
                validWorkItemIDs: [workItemID]
            ),
            workItemID
        )
        XCTAssertNil(
            navigation.validatedSelectedWorkItem(
                accountID: accountID,
                organizationID: otherOrganizationID,
                validWorkItemIDs: [workItemID]
            )
        )
        XCTAssertEqual(
            AppNavigationModel(defaults: defaults).validatedSelectedWorkItem(
                accountID: accountID,
                organizationID: organizationID,
                validWorkItemIDs: [workItemID]
            ),
            workItemID
        )
    }

    func testDeletedSelectionIsClearedBeforeTheNextRestoration() {
        let suiteName = "AppNavigationModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let accountID = AccountID(rawValue: "account-a")!
        let organizationID = OrganizationID(rawValue: "organization-a")!
        let deletedWorkItemID = WorkItemID(rawValue: "deleted-work-item")!
        let navigation = AppNavigationModel(defaults: defaults)

        navigation.setSelectedWorkItem(
            deletedWorkItemID,
            accountID: accountID,
            organizationID: organizationID
        )

        XCTAssertNil(
            navigation.validatedSelectedWorkItem(
                accountID: accountID,
                organizationID: organizationID,
                validWorkItemIDs: []
            )
        )
        XCTAssertNil(
            AppNavigationModel(defaults: defaults).validatedSelectedWorkItem(
                accountID: accountID,
                organizationID: organizationID,
                validWorkItemIDs: [deletedWorkItemID]
            )
        )
    }

    func testSelectionBindingClearsOnlyTheActiveScope() {
        let suiteName = "AppNavigationModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let accountID = AccountID(rawValue: "account-a")!
        let organizationA = OrganizationID(rawValue: "organization-a")!
        let organizationB = OrganizationID(rawValue: "organization-b")!
        let itemA = WorkItemID(rawValue: "work-item-a")!
        let itemB = WorkItemID(rawValue: "work-item-b")!
        let navigation = AppNavigationModel(defaults: defaults)

        navigation.setSelectedWorkItem(itemA, accountID: accountID, organizationID: organizationA)
        navigation.setSelectedWorkItem(itemB, accountID: accountID, organizationID: organizationB)
        navigation.setSelectedWorkItem(nil, accountID: accountID, organizationID: organizationA)

        let restored = AppNavigationModel(defaults: defaults)
        XCTAssertNil(restored.validatedSelectedWorkItem(
            accountID: accountID,
            organizationID: organizationA,
            validWorkItemIDs: [itemA]
        ))
        XCTAssertEqual(restored.validatedSelectedWorkItem(
            accountID: accountID,
            organizationID: organizationB,
            validWorkItemIDs: [itemB]
        ), itemB)
    }

    func testSelectionHistoryNavigatesBackAndForwardWithoutRecordingReplay() {
        let defaults = makeDefaults()
        let navigation = AppNavigationModel(defaults: defaults)
        let accountID = AccountID(rawValue: "account")!
        let organizationID = OrganizationID(rawValue: "organization")!
        let first = WorkItemID(rawValue: "first")!
        let second = WorkItemID(rawValue: "second")!
        let third = WorkItemID(rawValue: "third")!
        let valid: Set<WorkItemID> = [first, second, third]

        navigation.setSelectedWorkItem(first, accountID: accountID, organizationID: organizationID)
        navigation.setSelectedWorkItem(second, accountID: accountID, organizationID: organizationID)
        navigation.setSelectedWorkItem(third, accountID: accountID, organizationID: organizationID)

        XCTAssertTrue(navigation.canNavigateSelectionBack(
            accountID: accountID,
            organizationID: organizationID,
            validWorkItemIDs: valid
        ))
        XCTAssertEqual(navigation.navigateSelectionBack(
            accountID: accountID,
            organizationID: organizationID,
            validWorkItemIDs: valid
        ), second)
        // This mirrors the list's onChange after the toolbar/command changes
        // the app-model selection; it must not create a new history entry.
        navigation.setSelectedWorkItem(second, accountID: accountID, organizationID: organizationID)
        XCTAssertEqual(navigation.navigateSelectionBack(
            accountID: accountID,
            organizationID: organizationID,
            validWorkItemIDs: valid
        ), first)
        XCTAssertEqual(navigation.navigateSelectionForward(
            accountID: accountID,
            organizationID: organizationID,
            validWorkItemIDs: valid
        ), second)
        XCTAssertEqual(navigation.navigateSelectionForward(
            accountID: accountID,
            organizationID: organizationID,
            validWorkItemIDs: valid
        ), third)
    }

    func testSelectionHistoryIsScopeSafeAndPrunesUnavailableTargets() {
        let defaults = makeDefaults()
        let navigation = AppNavigationModel(defaults: defaults)
        let accountID = AccountID(rawValue: "account")!
        let organizationA = OrganizationID(rawValue: "organization-a")!
        let organizationB = OrganizationID(rawValue: "organization-b")!
        let first = WorkItemID(rawValue: "first")!
        let unavailable = WorkItemID(rawValue: "unavailable")!
        let current = WorkItemID(rawValue: "current")!
        let otherScope = WorkItemID(rawValue: "other-scope")!

        navigation.setSelectedWorkItem(first, accountID: accountID, organizationID: organizationA)
        navigation.setSelectedWorkItem(unavailable, accountID: accountID, organizationID: organizationA)
        navigation.setSelectedWorkItem(current, accountID: accountID, organizationID: organizationA)
        navigation.setSelectedWorkItem(otherScope, accountID: accountID, organizationID: organizationB)

        XCTAssertEqual(navigation.navigateSelectionBack(
            accountID: accountID,
            organizationID: organizationA,
            validWorkItemIDs: [first, current]
        ), first)
        XCTAssertNil(navigation.navigateSelectionBack(
            accountID: accountID,
            organizationID: organizationB,
            validWorkItemIDs: [otherScope]
        ))
    }

    func testSelectionHistoryIsBounded() {
        let navigation = AppNavigationModel(defaults: makeDefaults())
        let accountID = AccountID(rawValue: "account")!
        let organizationID = OrganizationID(rawValue: "organization")!
        let items = (0...22).map { WorkItemID(rawValue: "item-\($0)")! }
        let valid = Set(items)

        for item in items {
            navigation.setSelectedWorkItem(item, accountID: accountID, organizationID: organizationID)
        }

        var visited = [WorkItemID]()
        while let item = navigation.navigateSelectionBack(
            accountID: accountID,
            organizationID: organizationID,
            validWorkItemIDs: valid
        ) {
            visited.append(item)
            navigation.setSelectedWorkItem(item, accountID: accountID, organizationID: organizationID)
        }

        XCTAssertEqual(visited.count, 20)
        XCTAssertEqual(visited.first, items[21])
        XCTAssertEqual(visited.last, items[2])
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppNavigationModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
