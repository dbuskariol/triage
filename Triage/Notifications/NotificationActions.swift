import Foundation

enum NotificationActionCategory {
  static let identifier = "triage.notification.actions"
}

enum NotificationActionIdentifier {
  static let openTriage = "triage.notification.open"
  static let snoozeOneHour = "triage.notification.snooze-one-hour"
  static let archiveInTriage = "triage.notification.archive"
  static let defaultOpen = "com.apple.UNNotificationDefaultActionIdentifier"
}

enum NotificationLocalAction: Equatable, Sendable {
  case openTriage(NotificationRoute)
  case snoozeOneHour(NotificationRoute, until: Date)
  case archiveInTriage(NotificationRoute)
}

enum NotificationLocalActionPolicy {
  static func action(
    identifier: String,
    route: NotificationRoute,
    now: Date
  ) -> NotificationLocalAction? {
    switch identifier {
    case NotificationActionIdentifier.openTriage, NotificationActionIdentifier.defaultOpen:
      .openTriage(route)
    case NotificationActionIdentifier.snoozeOneHour:
      .snoozeOneHour(route, until: now.addingTimeInterval(3_600))
    case NotificationActionIdentifier.archiveInTriage:
      .archiveInTriage(route)
    default:
      nil
    }
  }
}

@MainActor
protocol NotificationLocalActionHandling: Sendable {
    func handle(_ action: NotificationLocalAction) async
}
