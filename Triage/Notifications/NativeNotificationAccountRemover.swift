import Foundation
@preconcurrency import UserNotifications

/// Removes only the native-notification requests that belong to one opaque
/// local account. Implementations must not inspect notification payloads:
/// request identifiers carry the privacy-safe account scope needed here.
protocol AccountNotificationRemoving: Sendable {
    func removeNotifications(for accountID: AccountID) async
    func removeNotifications(for accountID: AccountID, organizationID: OrganizationID) async
    func removeNotifications(for route: NotificationRoute) async
    func removeAllTriageNotifications() async
}

extension AccountNotificationRemoving {
    func removeNotifications(for _: AccountID, organizationID _: OrganizationID) async {}
    func removeNotifications(for _: NotificationRoute) async {}
    func removeAllTriageNotifications() async {}
}

struct NoopAccountNotificationRemover: AccountNotificationRemoving {
    func removeNotifications(for _: AccountID) async {}
}

/// Narrow adapter around `UNUserNotificationCenter` for deletion. It exposes
/// identifiers only, so account removal cannot read a notification's title,
/// body, route, or other payload contents.
protocol NativeNotificationRequestRemoving: Sendable {
    func pendingRequestIdentifiers() async -> [String]
    func deliveredRequestIdentifiers() async -> [String]
    func removePendingRequests(identifiedBy identifiers: [String]) async
    func removeDeliveredNotifications(identifiedBy identifiers: [String]) async
}

actor UserNotificationCenterRequestRemover: NativeNotificationRequestRemoving {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func pendingRequestIdentifiers() async -> [String] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests.map(\.identifier))
            }
        }
    }

    func deliveredRequestIdentifiers() async -> [String] {
        await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications.map(\.request.identifier))
            }
        }
    }

    func removePendingRequests(identifiedBy identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredNotifications(identifiedBy identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Account deletion uses this service after notification delivery has been
/// fenced. It filters exact opaque account prefixes from identifiers only;
/// legacy or unrecognized request IDs are deliberately left untouched.
actor NativeNotificationAccountRemover: AccountNotificationRemoving {
    private let requests: any NativeNotificationRequestRemoving

    init(requests: any NativeNotificationRequestRemoving = UserNotificationCenterRequestRemover()) {
        self.requests = requests
    }

    func removeNotifications(for accountID: AccountID) async {
        await removeNotifications(matching: NotificationDedupeKey.requestIdentifierPrefix(for: accountID))
    }

    func removeNotifications(for accountID: AccountID, organizationID: OrganizationID) async {
        await removeNotifications(
            matching: NotificationDedupeKey.requestIdentifierPrefix(
                for: accountID,
                organizationID: organizationID
            )
        )
    }

    func removeNotifications(for route: NotificationRoute) async {
        await removeNotifications(matching: NotificationDedupeKey.requestIdentifierPrefix(for: route))
    }

    func removeAllTriageNotifications() async {
        await removeNotifications(matching: NotificationDedupeKey.requestIdentifierNamespacePrefix)
    }

    private func removeNotifications(matching prefix: String) async {
        let pending = await requests.pendingRequestIdentifiers().filter { $0.hasPrefix(prefix) }
        await requests.removePendingRequests(identifiedBy: pending)

        let delivered = await requests.deliveredRequestIdentifiers().filter { $0.hasPrefix(prefix) }
        await requests.removeDeliveredNotifications(identifiedBy: delivered)
    }
}
