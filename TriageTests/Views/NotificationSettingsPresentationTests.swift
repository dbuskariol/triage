import XCTest
@preconcurrency import UserNotifications

@testable import Triage

final class NotificationSettingsPresentationTests: XCTestCase {
    func testDeniedPermissionRoutesToMacOSNotificationSettings() {
        XCTAssertEqual(
            NotificationSettingsPresentation.action(for: .denied),
            .openSystemSettings
        )
    }

    func testOnlyUndecidedPermissionRequestsAuthorization() {
        XCTAssertEqual(
            NotificationSettingsPresentation.action(for: .notDetermined),
            .requestAuthorization
        )
        XCTAssertEqual(
            NotificationSettingsPresentation.action(for: .authorized),
            .unavailable
        )
        XCTAssertEqual(
            NotificationSettingsPresentation.action(for: .provisional),
            .unavailable
        )
    }

    func testOrganizationScopeNamesTheExactOrganization() {
        XCTAssertEqual(
            NotificationSettingsPresentation.organizationScopeName(
                displayName: "Octo Org",
                login: "octo-org"
            ),
            "Octo Org (@octo-org)"
        )
        XCTAssertEqual(
            NotificationSettingsPresentation.organizationScopeName(
                displayName: nil,
                login: "octo-org"
            ),
            "octo-org"
        )
    }
}
