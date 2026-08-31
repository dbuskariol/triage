import Foundation

struct NotificationPreferences: Codable, Equatable, Sendable {
  var isEnabled: Bool
  var privacy: NotificationPrivacy
  var enabledReasons: Set<NotificationReason>
  var quietSchedule: NotificationQuietSchedule?

  init(
    isEnabled: Bool = false,
    privacy: NotificationPrivacy = .generic,
    enabledReasons: Set<NotificationReason> = Set(NotificationReason.allCases),
    quietSchedule: NotificationQuietSchedule? = nil
  ) {
    self.isEnabled = isEnabled
    self.privacy = privacy
    self.enabledReasons = enabledReasons
    self.quietSchedule = quietSchedule
  }
}

struct NotificationQuietSchedule: Codable, Equatable, Sendable {
  var startMinute: Int
  var endMinute: Int

  init(startMinute: Int, endMinute: Int) {
    self.startMinute = min(max(startMinute, 0), 1_439)
    self.endMinute = min(max(endMinute, 0), 1_439)
  }

  func contains(_ date: Date, calendar: Calendar) -> Bool {
    guard startMinute != endMinute else { return false }
    let components = calendar.dateComponents([.hour, .minute], from: date)
    let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
    if startMinute < endMinute { return minute >= startMinute && minute < endMinute }
    return minute >= startMinute || minute < endMinute
  }
}

enum NotificationPrivacy: String, Codable, Hashable, Sendable {
  case generic
  case showDetails
}

struct NotificationCandidate: Sendable {
  let route: NotificationRoute
  let reason: NotificationReason
  let evidenceVersion: String
  let isNewEvidence: Bool
  let isInboxItem: Bool
  let isHighPriority: Bool
  let isWaiting: Bool
  let dueAt: Date?

  init(
    route: NotificationRoute,
    reason: NotificationReason,
    evidenceVersion: String,
    isNewEvidence: Bool = true,
    isInboxItem: Bool = true,
    isHighPriority: Bool = false,
    isWaiting: Bool = false,
    dueAt: Date? = nil
  ) {
    self.route = route
    self.reason = reason
    self.evidenceVersion = evidenceVersion
    self.isNewEvidence = isNewEvidence
    self.isInboxItem = isInboxItem
    self.isHighPriority = isHighPriority
    self.isWaiting = isWaiting
    self.dueAt = dueAt
  }

  var dedupeKey: NotificationDedupeKey {
    NotificationDedupeKey(
      route: route,
      reason: reason,
      evidenceVersion: evidenceVersion
    )
  }
}

enum NotificationEligibilityDecision: Equatable, Sendable {
  case eligible
  case missingEvidenceVersion
  case unchangedEvidence
  case notInboxItem
  case notHighPriority
  case notWaitingItem
  case notDue
  case deadlineNotApproaching
}

struct NotificationEligibilityPolicy: Sendable {
  let deadlineLeadTime: TimeInterval

  init(deadlineLeadTime: TimeInterval = 3 * 86_400) {
    precondition(deadlineLeadTime > 0, "A notification deadline lead time must be positive.")
    self.deadlineLeadTime = deadlineLeadTime
  }

  func decision(
    for candidate: NotificationCandidate,
    at date: Date
  ) -> NotificationEligibilityDecision {
    guard !candidate.evidenceVersion.isEmpty else {
      return .missingEvidenceVersion
    }

    switch candidate.reason {
    case .directAssignment, .directReviewRequest, .teamReviewRequest:
      return candidate.isNewEvidence ? .eligible : .unchangedEvidence

    case .waitingResponse:
      guard candidate.isNewEvidence else { return .unchangedEvidence }
      return candidate.isWaiting ? .eligible : .notWaitingItem

    case .highPriorityInboxItem:
      guard candidate.isNewEvidence else { return .unchangedEvidence }
      guard candidate.isInboxItem else { return .notInboxItem }
      return candidate.isHighPriority ? .eligible : .notHighPriority

    case .snoozeDue:
      guard let dueAt = candidate.dueAt, dueAt <= date else {
        return .notDue
      }
      return .eligible

    case .explicitDeadline:
      guard let dueAt = candidate.dueAt,
        dueAt > date,
        dueAt <= date.addingTimeInterval(deadlineLeadTime)
      else {
        return .deadlineNotApproaching
      }
      return .eligible
    }
  }
}

struct NotificationPresentation: Equatable, Sendable {
  let title: String?
  let body: String?

  init(title: String? = nil, body: String? = nil) {
    self.title = title
    self.body = body
  }
}

struct TriageNotificationContent: Equatable, Sendable {
  let title: String
  let body: String
  let categoryIdentifier: String
}

enum NotificationContentFactory {
  static func make(
    preferences: NotificationPreferences,
    presentation: NotificationPresentation = .init()
  ) -> TriageNotificationContent {
    switch preferences.privacy {
    case .generic:
      TriageNotificationContent(
        title: "New Triage item",
        body: "Open Triage to view it.",
        categoryIdentifier: NotificationActionCategory.identifier
      )

    case .showDetails:
      TriageNotificationContent(
        title: presentation.title ?? "New Triage item",
        body: presentation.body ?? "Open Triage to view it.",
        categoryIdentifier: NotificationActionCategory.identifier
      )
    }
  }
}
