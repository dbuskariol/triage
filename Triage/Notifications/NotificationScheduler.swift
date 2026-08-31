import Foundation
@preconcurrency import UserNotifications

struct PendingNotification: Equatable, Sendable {
  let identifier: String
  let dedupeKey: NotificationDedupeKey
}

struct NotificationRequest: Equatable, Sendable {
  let identifier: String
  let payload: NotificationPayload
  let content: TriageNotificationContent
}

protocol NotificationScheduling: Sendable {
  func pendingNotifications() async -> [PendingNotification]
  func schedule(_ request: NotificationRequest) async throws
  func removePendingNotifications(identifiedBy identifiers: [String]) async
}

enum NotificationScheduleResult: Equatable, Sendable {
  case scheduled(replacing: Int)
  case suppressedDisabled
  case suppressedReasonDisabled
  case suppressedQuietHours
  case suppressedIneligible(NotificationEligibilityDecision)
  case suppressedDuplicate
}

actor NotificationScheduler {
  private var preferences: NotificationPreferences
  private let eligibilityPolicy: NotificationEligibilityPolicy
  private let scheduling: any NotificationScheduling
  private let deliveryLedger: any NotificationDeliveryLedger
  private let calendar: Calendar

  init(
    preferences: NotificationPreferences = .init(),
    eligibilityPolicy: NotificationEligibilityPolicy = .init(),
    scheduling: any NotificationScheduling,
    deliveryLedger: any NotificationDeliveryLedger,
    calendar: Calendar = .current
  ) {
    self.preferences = preferences
    self.eligibilityPolicy = eligibilityPolicy
    self.scheduling = scheduling
    self.deliveryLedger = deliveryLedger
    self.calendar = calendar
  }

  func updatePreferences(_ preferences: NotificationPreferences) {
    self.preferences = preferences
  }

  func schedule(
    candidate: NotificationCandidate,
    presentation: NotificationPresentation = .init(),
    at date: Date = .now
  ) async throws -> NotificationScheduleResult {
    guard preferences.isEnabled else {
      return .suppressedDisabled
    }
    guard preferences.enabledReasons.contains(candidate.reason) else {
      return .suppressedReasonDisabled
    }
    if preferences.quietSchedule?.contains(date, calendar: calendar) == true {
      return .suppressedQuietHours
    }

    let eligibility = eligibilityPolicy.decision(for: candidate, at: date)
    guard eligibility == .eligible else {
      return .suppressedIneligible(eligibility)
    }

    let payload = NotificationPayload(
      route: candidate.route,
      reason: candidate.reason,
      evidenceVersion: candidate.evidenceVersion
    )
    guard !(try await deliveryLedger.contains(payload.dedupeKey)) else {
      return .suppressedDuplicate
    }

    let pending = await scheduling.pendingNotifications()
    let related = pending.filter {
      $0.dedupeKey.route == payload.route && $0.dedupeKey.reason == payload.reason
    }

    guard !related.contains(where: { $0.dedupeKey == payload.dedupeKey }) else {
      return .suppressedDuplicate
    }

    if !related.isEmpty {
      await scheduling.removePendingNotifications(identifiedBy: related.map(\.identifier))
    }

    let request = NotificationRequest(
      identifier: payload.dedupeKey.requestIdentifier,
      payload: payload,
      content: NotificationContentFactory.make(
        preferences: preferences,
        presentation: presentation
      )
    )
    try await scheduling.schedule(request)
    try await deliveryLedger.record(payload.dedupeKey)
    return .scheduled(replacing: related.count)
  }
}

actor UserNotificationCenterScheduler: NotificationScheduling {
  private let center: UNUserNotificationCenter

  init(center: UNUserNotificationCenter = .current()) {
    self.center = center
  }

  func registerLocalActions() {
    center.setNotificationCategories([NotificationActionCategory.makeCategory()])
  }

  func pendingNotifications() async -> [PendingNotification] {
    await withCheckedContinuation { continuation in
      center.getPendingNotificationRequests { requests in
        continuation.resume(
          returning: requests.compactMap { request in
            guard
              let payload = NotificationPayloadCodec.decode(
                userInfo: request.content.userInfo
              )
            else {
              return nil
            }
            return PendingNotification(
              identifier: request.identifier,
              dedupeKey: payload.dedupeKey
            )
          }
        )
      }
    }
  }

  func schedule(_ request: NotificationRequest) async throws {
    let content = UNMutableNotificationContent()
    content.title = request.content.title
    content.body = request.content.body
    content.categoryIdentifier = request.content.categoryIdentifier
    content.sound = nil
    content.interruptionLevel = .passive
    content.userInfo = [
      NotificationPayloadCodec.userInfoKey: try NotificationPayloadCodec.encode(request.payload)
    ]

    let request = UNNotificationRequest(
      identifier: request.identifier,
      content: content,
      trigger: nil
    )
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      center.add(request) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  func removePendingNotifications(identifiedBy identifiers: [String]) {
    center.removePendingNotificationRequests(withIdentifiers: identifiers)
  }
}

extension NotificationActionCategory {
  static func makeCategory() -> UNNotificationCategory {
    let actions = [
      UNNotificationAction(
        identifier: NotificationActionIdentifier.openTriage,
        title: "Open Triage",
        options: [.foreground]
      ),
      UNNotificationAction(
        identifier: NotificationActionIdentifier.snoozeOneHour,
        title: "Snooze 1 Hour",
        options: [.foreground]
      ),
      UNNotificationAction(
        identifier: NotificationActionIdentifier.archiveInTriage,
        title: "Archive in Triage",
        options: [.foreground]
      ),
    ]
    return UNNotificationCategory(
      identifier: identifier,
      actions: actions,
      intentIdentifiers: [],
      options: []
    )
  }
}

enum NotificationResponseRouter {
  static func localAction(
    from response: UNNotificationResponse,
    now: Date = .now
  ) -> NotificationLocalAction? {
    guard
      let payload = NotificationPayloadCodec.decode(
        userInfo: response.notification.request.content.userInfo
      )
    else {
      return nil
    }

    return NotificationLocalActionPolicy.action(
      identifier: response.actionIdentifier,
      route: payload.route.authorizingAction(
        reason: payload.reason,
        evidenceVersion: payload.evidenceVersion
      ),
      now: now
    )
  }
}
