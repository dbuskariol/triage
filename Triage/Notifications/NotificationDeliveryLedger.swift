import Foundation

protocol NotificationDeliveryLedger: Sendable {
  func contains(_ key: NotificationDedupeKey) async -> Bool
  func record(_ key: NotificationDedupeKey) async
}

actor InMemoryNotificationDeliveryLedger: NotificationDeliveryLedger {
  private var keys: Set<NotificationDedupeKey> = []

  func contains(_ key: NotificationDedupeKey) -> Bool {
    keys.contains(key)
  }

  func record(_ key: NotificationDedupeKey) {
    keys.insert(key)
  }
}
