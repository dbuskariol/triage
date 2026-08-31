import XCTest
@testable import Triage

final class NativeNotificationAccountRemoverTests: XCTestCase {
    func testRemovesOnlyTheDeletedAccountsPendingAndDeliveredRequests() async {
        let removedAccount = AccountID(rawValue: "removed-account")!
        let retainedAccount = AccountID(rawValue: "retained-account")!
        let requests = RecordingNativeNotificationRequests(
            pending: [
                requestIdentifier(accountID: removedAccount, suffix: "pending"),
                requestIdentifier(accountID: retainedAccount, suffix: "pending"),
                "triage.notification.legacy-request"
            ],
            delivered: [
                requestIdentifier(accountID: retainedAccount, suffix: "delivered"),
                requestIdentifier(accountID: removedAccount, suffix: "delivered"),
                "unrelated.notification"
            ]
        )
        let remover = NativeNotificationAccountRemover(requests: requests)

        await remover.removeNotifications(for: removedAccount)

        let removedPending = await requests.pendingRemovalIDs()
        let removedDelivered = await requests.deliveredRemovalIDs()
        XCTAssertEqual(removedPending, [
            requestIdentifier(accountID: removedAccount, suffix: "pending")
        ])
        XCTAssertEqual(removedDelivered, [
            requestIdentifier(accountID: removedAccount, suffix: "delivered")
        ])
    }

    func testAccountIdentifierPrefixIsOpaqueAndAccountSpecific() {
        let first = AccountID(rawValue: "first-account")!
        let second = AccountID(rawValue: "second-account")!

        let firstPrefix = NotificationDedupeKey.requestIdentifierPrefix(for: first)
        XCTAssertNotEqual(firstPrefix, NotificationDedupeKey.requestIdentifierPrefix(for: second))
        XCTAssertFalse(firstPrefix.contains(first.rawValue))
        XCTAssertTrue(firstPrefix.hasPrefix("triage.notification.account."))
    }

    func testRemovesOnlyTheSelectedOrganizationRequests() async {
        let accountID = AccountID(rawValue: "account")!
        let selectedOrganizationID = OrganizationID(rawValue: "organization-a")!
        let retainedOrganizationID = OrganizationID(rawValue: "organization-b")!
        let selected = NotificationDedupeKey.requestIdentifierPrefix(
            for: accountID,
            organizationID: selectedOrganizationID
        ) + "request"
        let retained = NotificationDedupeKey.requestIdentifierPrefix(
            for: accountID,
            organizationID: retainedOrganizationID
        ) + "request"
        let requests = RecordingNativeNotificationRequests(
            pending: [selected, retained],
            delivered: [selected, retained]
        )
        let remover = NativeNotificationAccountRemover(requests: requests)

        await remover.removeNotifications(for: accountID, organizationID: selectedOrganizationID)

        let removedPending = await requests.pendingRemovalIDs()
        let removedDelivered = await requests.deliveredRemovalIDs()
        XCTAssertEqual(removedPending, [selected])
        XCTAssertEqual(removedDelivered, [selected])
    }

    func testRemovesOnlyTheSelectedWorkItemRequests() async {
        let accountID = AccountID(rawValue: "account")!
        let organizationID = OrganizationID(rawValue: "organization")!
        let selectedRoute = NotificationRoute(
            accountID: accountID,
            organizationID: organizationID,
            workItemID: WorkItemID(rawValue: "item-a")!
        )
        let retainedRoute = NotificationRoute(
            accountID: accountID,
            organizationID: organizationID,
            workItemID: WorkItemID(rawValue: "item-b")!
        )
        let selected = NotificationDedupeKey.requestIdentifierPrefix(for: selectedRoute) + "request"
        let retained = NotificationDedupeKey.requestIdentifierPrefix(for: retainedRoute) + "request"
        let requests = RecordingNativeNotificationRequests(
            pending: [selected, retained],
            delivered: [selected, retained]
        )
        let remover = NativeNotificationAccountRemover(requests: requests)

        await remover.removeNotifications(for: selectedRoute)

        let removedPending = await requests.pendingRemovalIDs()
        let removedDelivered = await requests.deliveredRemovalIDs()
        XCTAssertEqual(removedPending, [selected])
        XCTAssertEqual(removedDelivered, [selected])
    }

    private func requestIdentifier(accountID: AccountID, suffix: String) -> String {
        NotificationDedupeKey.requestIdentifierPrefix(for: accountID) + suffix
    }
}

private actor RecordingNativeNotificationRequests: NativeNotificationRequestRemoving {
    private let pending: [String]
    private let delivered: [String]
    private var removedPending = [String]()
    private var removedDelivered = [String]()

    init(pending: [String], delivered: [String]) {
        self.pending = pending
        self.delivered = delivered
    }

    func pendingRequestIdentifiers() -> [String] { pending }
    func deliveredRequestIdentifiers() -> [String] { delivered }

    func removePendingRequests(identifiedBy identifiers: [String]) {
        removedPending = identifiers
    }

    func removeDeliveredNotifications(identifiedBy identifiers: [String]) {
        removedDelivered = identifiers
    }

    func pendingRemovalIDs() -> [String] { removedPending }
    func deliveredRemovalIDs() -> [String] { removedDelivered }
}
