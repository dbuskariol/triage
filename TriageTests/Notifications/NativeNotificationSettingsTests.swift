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
        await waitForDeliverySettingsMutation(settings)
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
        await waitForDeliverySettingsMutation(first)
        let enabledScope = await first.setEnabled(true, for: scope)
        XCTAssertTrue(enabledScope)
        first.setPrivacy(.showDetails)
        await waitForDeliverySettingsMutation(first)
        first.setReason(.teamReviewRequest, enabled: false)
        await waitForDeliverySettingsMutation(first)
        first.setQuietSchedule(.init(startMinute: 1_320, endMinute: 420))
        await waitForDeliverySettingsMutation(first)

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
        await waitForDeliverySettingsMutation(settings)
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
        await waitForDeliverySettingsMutation(settings)
        settings.setEnabled(false)
        await remover.waitForAllPurge(count: 1)
        await waitForDeliverySettingsMutation(settings)

        settings.setPrivacy(.showDetails)
        await waitForDeliverySettingsMutation(settings)
        settings.setPrivacy(.generic)
        await remover.waitForAllPurge(count: 2)
        await waitForDeliverySettingsMutation(settings)

        settings.setReason(.directAssignment, enabled: false)
        await remover.waitForAllPurge(count: 3)
        await waitForDeliverySettingsMutation(settings)
        settings.setQuietSchedule(.init(startMinute: 1_320, endMinute: 420))
        await remover.waitForAllPurge(count: 4)
        await waitForDeliverySettingsMutation(settings)

        let scopeEnabled = await settings.setEnabled(true, for: scope)
        let scopeDisabled = await settings.setEnabled(false, for: scope)
        XCTAssertTrue(scopeEnabled)
        XCTAssertTrue(scopeDisabled)
        let scopes = await remover.organizationScopes()
        XCTAssertEqual(scopes.count, 1)
        XCTAssertEqual(scopes.first?.0, scope.accountID)
        XCTAssertEqual(scopes.first?.1, scope.organizationID)
    }

    func testPrivacyDowngradeWaitsForTheSharedDeliveryLeaseBeforePurging() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let lease = NotificationDeliveryLeaseGate()
        let remover = NotificationRemovalSpy()
        let settings = NativeNotificationSettings(
            defaults: defaults,
            notificationRemover: remover,
            notificationDeliveryLeaseGate: lease
        )

        settings.setPrivacy(.showDetails)
        await waitForDeliverySettingsMutation(settings)
        await lease.acquire()
        settings.setPrivacy(.generic)
        XCTAssertTrue(settings.isDeliverySettingsMutationPending)
        XCTAssertEqual(settings.preferences.privacy, .showDetails)

        await lease.release()
        await waitForDeliverySettingsMutation(settings)
        XCTAssertEqual(settings.preferences.privacy, .generic)
        await remover.waitForAllPurge(count: 1)
    }

    func testStableDeliveryLeasePreservesExplicitDetailPreference() async throws {
        let lease = NotificationDeliveryLeaseGate()
        let center = LeaseRecordingNotificationScheduler()
        let scheduler = NotificationScheduler(
            preferences: .init(isEnabled: true, privacy: .showDetails),
            scheduling: center,
            deliveryLedger: InMemoryNotificationDeliveryLedger(),
            deliveryLeaseGate: lease
        )
        let route = NotificationRoute(
            accountID: AccountID(rawValue: "account")!,
            organizationID: OrganizationID(rawValue: "organization")!,
            workItemID: WorkItemID(rawValue: "work-item")!
        )

        _ = try await scheduler.schedule(
            candidate: .init(route: route, reason: .directAssignment, evidenceVersion: "one"),
            presentation: .init(title: "Private title", body: "Private body"),
            authorizingPreferences: { _ in .init(isEnabled: true, privacy: .showDetails) }
        )

        let request = await center.requests().first
        XCTAssertEqual(request?.content.title, "Private title")
        XCTAssertEqual(request?.content.body, "Private body")
    }

    func testCancelledDeliveryQueuedBehindLeaseDoesNotSubmitAfterAcquiringIt() async throws {
        let lease = NotificationDeliveryLeaseGate()
        let center = LeaseRecordingNotificationScheduler()
        let scheduler = NotificationScheduler(
            preferences: .init(isEnabled: true),
            scheduling: center,
            deliveryLedger: InMemoryNotificationDeliveryLedger(),
            deliveryLeaseGate: lease
        )
        let route = NotificationRoute(
            accountID: AccountID(rawValue: "account")!,
            organizationID: OrganizationID(rawValue: "organization")!,
            workItemID: WorkItemID(rawValue: "work-item")!
        )

        await lease.acquire()
        let delivery = Task {
            try await scheduler.schedule(
                candidate: .init(route: route, reason: .directAssignment, evidenceVersion: "one")
            )
        }
        await Task.yield()
        delivery.cancel()
        await lease.release()

        let result = await delivery.result
        guard case let .failure(error) = result else {
            return XCTFail("A cancelled queued delivery must not schedule.")
        }
        XCTAssertTrue(error is CancellationError)
        let requests = await center.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testCancellationDuringFinalAuthorityReadEvictsRequestWithoutRecordingLedger() async throws {
        let center = LeaseRecordingNotificationScheduler()
        let ledger = InMemoryNotificationDeliveryLedger()
        let scheduler = NotificationScheduler(
            preferences: .init(isEnabled: true),
            scheduling: center,
            deliveryLedger: ledger
        )
        let route = notificationRoute()
        let candidate = NotificationCandidate(
            route: route,
            reason: .directAssignment,
            evidenceVersion: "one"
        )
        let authority = PausingFinalAuthority()
        let delivery = Task {
            try await scheduler.schedule(
                candidate: candidate,
                authorizingPreferences: { _ in await authority.preferences() }
            )
        }
        await authority.waitUntilFinalRead()
        delivery.cancel()
        await authority.resumeFinalRead()

        let result = await delivery.result
        guard case let .failure(error) = result else {
            return XCTFail("A cancelled final authority read must not complete delivery.")
        }
        XCTAssertTrue(error is CancellationError)
        let requestsAfterCancellation = await center.requests()
        XCTAssertTrue(requestsAfterCancellation.isEmpty)

        let retry = try await scheduler.schedule(
            candidate: candidate,
            authorizingPreferences: { _ in .init(isEnabled: true) }
        )
        XCTAssertEqual(retry, .scheduled(replacing: 0))
    }

    func testGlobalDisableQueuedDuringPausedDetailDeliveryPurgesAfterDeliveryLease() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let lease = NotificationDeliveryLeaseGate()
        let events = NotificationLeaseEventLog()
        let settings = NativeNotificationSettings(
            defaults: defaults,
            notificationRemover: EventRecordingNotificationRemover(events: events),
            notificationDeliveryLeaseGate: lease
        )
        settings.setEnabled(true)
        await waitForDeliverySettingsMutation(settings)
        settings.setPrivacy(.showDetails)
        await waitForDeliverySettingsMutation(settings)
        let center = PausingLeaseNotificationScheduler(events: events)
        let scheduler = NotificationScheduler(
            preferences: .init(isEnabled: true, privacy: .showDetails),
            scheduling: center,
            deliveryLedger: InMemoryNotificationDeliveryLedger(),
            deliveryLeaseGate: lease
        )
        let route = notificationRoute()
        let delivery = Task {
            try await scheduler.schedule(
                candidate: .init(route: route, reason: .directAssignment, evidenceVersion: "one"),
                presentation: .init(title: "Private title", body: "Private body"),
                authorizingPreferences: { _ in await MainActor.run { settings.preferences } }
            )
        }
        await center.waitUntilScheduleStarted()

        settings.setEnabled(false)
        await Task.yield()
        XCTAssertTrue(settings.isDeliverySettingsMutationPending)
        XCTAssertTrue(settings.preferences.isEnabled)
        await center.resume()
        _ = try await delivery.value
        await waitForDeliverySettingsMutation(settings)

        let eventValues = await events.values()
        XCTAssertEqual(eventValues, ["schedule", "purge.all"])
    }

    func testOrganizationRevocationQueuedDuringPausedDeliveryPurgesAfterDeliveryLease() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let lease = NotificationDeliveryLeaseGate()
        let events = NotificationLeaseEventLog()
        let consent = InMemoryNotificationConsent()
        let settings = NativeNotificationSettings(
            defaults: defaults,
            notificationRemover: EventRecordingNotificationRemover(events: events),
            notificationDeliveryLeaseGate: lease,
            consentResolver: { _ in consent }
        )
        settings.setEnabled(true)
        await waitForDeliverySettingsMutation(settings)
        settings.setPrivacy(.showDetails)
        await waitForDeliverySettingsMutation(settings)
        let route = notificationRoute()
        let scope = NotificationScope(accountID: route.accountID, organizationID: route.organizationID)
        let consentEnabled = await settings.setEnabled(true, for: scope)
        XCTAssertTrue(consentEnabled)
        let center = PausingLeaseNotificationScheduler(events: events)
        let scheduler = NotificationScheduler(
            preferences: .init(isEnabled: true, privacy: .showDetails),
            scheduling: center,
            deliveryLedger: InMemoryNotificationDeliveryLedger(),
            deliveryLeaseGate: lease
        )
        let delivery = Task {
            try await scheduler.schedule(
                candidate: .init(route: route, reason: .directAssignment, evidenceVersion: "one"),
                presentation: .init(title: "Private title", body: "Private body"),
                authorizingPreferences: { route in
                    await settings.deliveryPreferences(
                        for: route.accountID,
                        organizationID: route.organizationID
                    )
                }
            )
        }
        await center.waitUntilScheduleStarted()

        let revoke = Task { await settings.setEnabled(false, for: scope) }
        await Task.yield()
        XCTAssertTrue(settings.isDeliverySettingsMutationPending)
        await center.resume()
        _ = try await delivery.value
        let revoked = await revoke.value
        XCTAssertTrue(revoked)

        let eventValues = await events.values()
        XCTAssertEqual(eventValues, ["schedule", "purge.organization"])
    }

    func testRevocationQueuedBeforeSchedulingLeaseCannotSubmitDetails() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let lease = NotificationDeliveryLeaseGate()
        let remover = NotificationRemovalSpy()
        let settings = NativeNotificationSettings(
            defaults: defaults,
            notificationRemover: remover,
            notificationDeliveryLeaseGate: lease
        )
        settings.setEnabled(true)
        await waitForDeliverySettingsMutation(settings)
        settings.setPrivacy(.showDetails)
        await waitForDeliverySettingsMutation(settings)

        let center = LeaseRecordingNotificationScheduler()
        let scheduler = NotificationScheduler(
            preferences: .init(isEnabled: true, privacy: .showDetails),
            scheduling: center,
            deliveryLedger: InMemoryNotificationDeliveryLedger(),
            deliveryLeaseGate: lease
        )
        let route = NotificationRoute(
            accountID: AccountID(rawValue: "account")!,
            organizationID: OrganizationID(rawValue: "organization")!,
            workItemID: WorkItemID(rawValue: "work-item")!
        )

        await lease.acquire()
        settings.setPrivacy(.generic)
        await Task.yield()
        let delivery = Task {
            try await scheduler.schedule(
                candidate: .init(route: route, reason: .directAssignment, evidenceVersion: "one"),
                presentation: .init(title: "Private title", body: "Private body"),
                authorizingPreferences: { _ in
                    await MainActor.run { settings.preferences }
                }
            )
        }
        await lease.release()
        _ = try await delivery.value
        await waitForDeliverySettingsMutation(settings)

        let request = await center.requests().first
        XCTAssertEqual(request?.content.title, "New Triage item")
        XCTAssertEqual(request?.content.body, "Open Triage to view it.")
        await remover.waitForAllPurge(count: 1)
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

    private func notificationRoute() -> NotificationRoute {
        .init(
            accountID: AccountID(rawValue: "account")!,
            organizationID: OrganizationID(rawValue: "organization")!,
            workItemID: WorkItemID(rawValue: "work-item")!
        )
    }

    private func waitForDeliverySettingsMutation(
        _ settings: NativeNotificationSettings,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 1_000 {
            if !settings.isDeliverySettingsMutationPending { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for the notification Settings mutation", file: file, line: line)
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

private actor LeaseRecordingNotificationScheduler: NotificationScheduling {
    private var scheduled = [NotificationRequest]()

    func pendingNotifications() -> [PendingNotification] {
        scheduled.map { .init(identifier: $0.identifier, dedupeKey: $0.payload.dedupeKey) }
    }

    func schedule(_ request: NotificationRequest) {
        scheduled.append(request)
    }

    func removePendingNotifications(identifiedBy identifiers: [String]) {
        scheduled.removeAll { identifiers.contains($0.identifier) }
    }

    func requests() -> [NotificationRequest] { scheduled }
}

private actor NotificationLeaseEventLog {
    private var events = [String]()

    func append(_ event: String) { events.append(event) }
    func values() -> [String] { events }
}

private actor PausingLeaseNotificationScheduler: NotificationScheduling {
    private let events: NotificationLeaseEventLog
    private var started = false
    private var mayFinish = false

    init(events: NotificationLeaseEventLog) { self.events = events }

    func pendingNotifications() -> [PendingNotification] { [] }

    func schedule(_: NotificationRequest) async {
        started = true
        await events.append("schedule")
        while !mayFinish { await Task.yield() }
    }

    func removePendingNotifications(identifiedBy _: [String]) {}

    func waitUntilScheduleStarted() async {
        while !started { await Task.yield() }
    }

    func resume() { mayFinish = true }
}

private actor EventRecordingNotificationRemover: AccountNotificationRemoving {
    private let events: NotificationLeaseEventLog

    init(events: NotificationLeaseEventLog) { self.events = events }

    func removeNotifications(for _: AccountID) {}
    func removeNotifications(for _: AccountID, organizationID _: OrganizationID) async {
        await events.append("purge.organization")
    }
    func removeAllTriageNotifications() async { await events.append("purge.all") }
}

private actor PausingFinalAuthority {
    private var readCount = 0
    private var finalReadWaiter: CheckedContinuation<Void, Never>?
    private var finalReadResume: CheckedContinuation<Void, Never>?

    func preferences() async -> NotificationPreferences? {
        readCount += 1
        if readCount == 2 {
            finalReadWaiter?.resume()
            finalReadWaiter = nil
            await withCheckedContinuation { finalReadResume = $0 }
        }
        return .init(isEnabled: true)
    }

    func waitUntilFinalRead() async {
        guard readCount < 2 else { return }
        await withCheckedContinuation { finalReadWaiter = $0 }
    }

    func resumeFinalRead() {
        finalReadResume?.resume()
        finalReadResume = nil
    }
}
