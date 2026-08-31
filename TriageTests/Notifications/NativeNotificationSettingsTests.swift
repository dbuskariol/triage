import Foundation
import XCTest

@testable import Triage

@MainActor
final class NativeNotificationSettingsTests: XCTestCase {
    func testInMemoryNotificationAuthorizationNeverUsesSystemAuthorization() async {
        let provider = InMemoryNotificationSystemAuthorizationProvider()
        let authorization = NotificationSystemAuthorization(provider: provider)

        await authorization.refresh()
        await authorization.requestAuthorization()

        XCTAssertEqual(authorization.status, .notDetermined)
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testDefaultsFailClosedUntilGlobalAndAccountOrganizationConsent() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let consent = InMemoryNotificationConsent()
        let settings = NativeNotificationSettings(
            defaults: defaults,
            consentResolver: { _ in consent }
        )
        let organizationID = OrganizationID(rawValue: "organization")!
        let scope = fixtureScope(account: "account-a", organization: organizationID)

        XCTAssertFalse(settings.preferences.isEnabled)
        XCTAssertEqual(settings.preferences.privacy, .generic)
        let disabledPreferences = await settings.deliveryPreferences(for: scope)
        XCTAssertNil(disabledPreferences)

        settings.setEnabled(true)
        let organizationDisabledPreferences = await settings.deliveryPreferences(for: scope)
        XCTAssertNil(organizationDisabledPreferences)

        let enabledScope = await settings.setEnabled(true, for: scope)
        XCTAssertTrue(enabledScope)
        let preferences = await settings.deliveryPreferences(for: scope)
        XCTAssertEqual(preferences?.isEnabled, true)
        XCTAssertEqual(preferences?.privacy, .generic)
    }

    func testSettingsPersistPrivacyReasonsQuietHoursAndAccountOrganizationConsent() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let organizationID = OrganizationID(rawValue: "organization")!
        let accountID = AccountID(rawValue: "account-a")!
        let scope = fixtureScope(account: accountID.rawValue, organization: organizationID)
        let consent = InMemoryNotificationConsent()
        let first = NativeNotificationSettings(
            defaults: defaults,
            consentResolver: { _ in consent }
        )

        first.setEnabled(true)
        let enabledScope = await first.setEnabled(true, for: scope)
        XCTAssertTrue(enabledScope)
        first.setPrivacy(.showDetails)
        first.setReason(.teamReviewRequest, enabled: false)
        first.setQuietSchedule(.init(startMinute: 1_320, endMinute: 420))

        let restored = NativeNotificationSettings(
            defaults: defaults,
            consentResolver: { _ in consent }
        )
        XCTAssertTrue(restored.preferences.isEnabled)
        XCTAssertEqual(restored.preferences.privacy, .showDetails)
        XCTAssertFalse(restored.preferences.enabledReasons.contains(.teamReviewRequest))
        XCTAssertEqual(restored.preferences.quietSchedule, .init(startMinute: 1_320, endMinute: 420))
        let restoredScopeEnabled = await restored.isEnabled(for: scope)
        XCTAssertTrue(restoredScopeEnabled)
    }

    func testOrganizationConsentDoesNotCrossAccounts() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let consent = InMemoryNotificationConsent()
        let settings = NativeNotificationSettings(
            defaults: defaults,
            consentResolver: { _ in consent }
        )
        let organizationID = OrganizationID(rawValue: "shared-organization")!
        let firstAccount = AccountID(rawValue: "account-a")!
        let secondAccount = AccountID(rawValue: "account-b")!

        settings.setEnabled(true)
        let firstScope = fixtureScope(account: firstAccount.rawValue, organization: organizationID)
        let secondScope = fixtureScope(account: secondAccount.rawValue, organization: organizationID)
        let firstScopeEnabled = await settings.setEnabled(true, for: firstScope)
        XCTAssertTrue(firstScopeEnabled)

        let firstPreferences = await settings.deliveryPreferences(for: firstScope)
        let secondPreferences = await settings.deliveryPreferences(for: secondScope)
        XCTAssertNotNil(firstPreferences)
        XCTAssertNil(secondPreferences)
        XCTAssertFalse(settings.isEnabled(for: organizationID))
    }

    func testDisablePrivacyDowngradeAndOrganizationDisablePurgeNativeRequests() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let consent = InMemoryNotificationConsent()
        let remover = NotificationRemovalSpy()
        let settings = NativeNotificationSettings(
            defaults: defaults,
            notificationRemover: remover,
            consentResolver: { _ in consent }
        )
        let scope = fixtureScope(
            account: "account-a",
            organization: OrganizationID(rawValue: "organization")!
        )

        settings.setEnabled(true)
        settings.setEnabled(false)
        await remover.waitForAllPurge(count: 1)

        settings.setPrivacy(.showDetails)
        settings.setPrivacy(.generic)
        await remover.waitForAllPurge(count: 2)

        let scopeEnabled = await settings.setEnabled(true, for: scope)
        let scopeDisabled = await settings.setEnabled(false, for: scope)
        XCTAssertTrue(scopeEnabled)
        XCTAssertTrue(scopeDisabled)
        let scopes = await remover.organizationScopes()
        XCTAssertEqual(scopes.count, 1)
        XCTAssertEqual(scopes.first?.0, scope.accountID)
        XCTAssertEqual(scopes.first?.1, scope.organizationID)
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

    private func fixtureScope(account: String, organization: OrganizationID) -> SynchronizationScope {
        .init(
            accountID: AccountID(rawValue: account)!,
            organizationID: organization,
            credentialRevision: CredentialRevision(rawValue: "credential-\(account)")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-\(account)")!
        )
    }
}

private actor InMemoryNotificationConsent: NotificationOrganizationConsentPersisting {
    private var values = [String: Bool]()

    func isEnabled(accountID: AccountID, organizationID: OrganizationID) -> Bool {
        values["\(accountID.rawValue)\u{1F}\(organizationID.rawValue)"] == true
    }

    func setEnabled(_ isEnabled: Bool, accountID: AccountID, organizationID: OrganizationID) {
        values["\(accountID.rawValue)\u{1F}\(organizationID.rawValue)"] = isEnabled
    }

    func removeAll(accountID: AccountID) {
        values = values.filter { !$0.key.hasPrefix("\(accountID.rawValue)\u{1F}") }
    }
}

private actor NotificationRemovalSpy: AccountNotificationRemoving {
    private var allPurgeCount = 0
    private var allPurgeWaiters = [(count: Int, continuation: CheckedContinuation<Void, Never>)]()
    private var scopes = [(AccountID, OrganizationID)]()

    func removeNotifications(for _: AccountID) {}

    func removeNotifications(for accountID: AccountID, organizationID: OrganizationID) {
        scopes.append((accountID, organizationID))
    }

    func removeAllTriageNotifications() {
        allPurgeCount += 1
        let ready = allPurgeWaiters.filter { $0.count <= allPurgeCount }
        allPurgeWaiters.removeAll { $0.count <= allPurgeCount }
        ready.forEach { $0.continuation.resume() }
    }

    func waitForAllPurge(count: Int) async {
        guard allPurgeCount < count else { return }
        await withCheckedContinuation { allPurgeWaiters.append((count, $0)) }
    }

    func organizationScopes() -> [(AccountID, OrganizationID)] { scopes }
}
