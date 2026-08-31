import XCTest
@testable import Triage

@MainActor
final class AppNavigationModelTests: XCTestCase {
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
}
