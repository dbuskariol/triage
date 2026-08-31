import Foundation
import XCTest

@testable import Triage

@MainActor
final class NativeNotificationSettingsTests: XCTestCase {
    func testDefaultsFailClosedUntilGlobalAndOrganizationConsent() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = NativeNotificationSettings(defaults: defaults)
        let organizationID = OrganizationID(rawValue: "organization")!

        XCTAssertFalse(settings.preferences.isEnabled)
        XCTAssertEqual(settings.preferences.privacy, .generic)
        let disabledPreferences = await settings.deliveryPreferences(for: organizationID)
        XCTAssertNil(disabledPreferences)

        settings.setEnabled(true)
        let organizationDisabledPreferences = await settings.deliveryPreferences(for: organizationID)
        XCTAssertNil(organizationDisabledPreferences)

        settings.setEnabled(true, for: organizationID)
        let preferences = await settings.deliveryPreferences(for: organizationID)
        XCTAssertEqual(preferences?.isEnabled, true)
        XCTAssertEqual(preferences?.privacy, .generic)
    }

    func testSettingsPersistPrivacyReasonsQuietHoursAndOrganizationConsent() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let organizationID = OrganizationID(rawValue: "organization")!
        let first = NativeNotificationSettings(defaults: defaults)

        first.setEnabled(true)
        first.setEnabled(true, for: organizationID)
        first.setPrivacy(.showDetails)
        first.setReason(.teamReviewRequest, enabled: false)
        first.setQuietSchedule(.init(startMinute: 1_320, endMinute: 420))

        let restored = NativeNotificationSettings(defaults: defaults)
        XCTAssertTrue(restored.preferences.isEnabled)
        XCTAssertEqual(restored.preferences.privacy, .showDetails)
        XCTAssertFalse(restored.preferences.enabledReasons.contains(.teamReviewRequest))
        XCTAssertEqual(restored.preferences.quietSchedule, .init(startMinute: 1_320, endMinute: 420))
        XCTAssertTrue(restored.isEnabled(for: organizationID))
    }

    func testQuietScheduleHandlesBothSameDayAndOvernightRanges() {
        let calendar = Calendar(identifier: .gregorian)
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        let evening = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: day)!
        let nextMorning = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: day)!

        XCTAssertTrue(NotificationQuietSchedule(startMinute: 480, endMinute: 1_080).contains(morning, calendar: calendar))
        XCTAssertFalse(NotificationQuietSchedule(startMinute: 480, endMinute: 1_080).contains(evening, calendar: calendar))
        XCTAssertTrue(NotificationQuietSchedule(startMinute: 1_320, endMinute: 420).contains(evening, calendar: calendar))
        XCTAssertTrue(NotificationQuietSchedule(startMinute: 1_320, endMinute: 420).contains(nextMorning, calendar: calendar))
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "NativeNotificationSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "NativeNotificationSettingsTests", code: 1)
        }
        return (defaults, suiteName)
    }
}
