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

/// Revalidates the account-and-organization notification authority at the
/// point macOS is about to receive a request. Returning `nil` means consent
/// has been withdrawn (or cannot be read) and must fail closed.
typealias NotificationPreferencesAuthorizing = @Sendable (NotificationRoute) async -> NotificationPreferences?

/// A non-reentrant lease shared by delivery and Settings mutations. Holding it
/// across the final authority read and `UNUserNotificationCenter.add` gives
/// every detailed notification a linearization point relative to revocation.
actor NotificationDeliveryLeaseGate: Sendable {
  private var isHeld = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    guard isHeld else {
      isHeld = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    if waiters.isEmpty {
      isHeld = false
    } else {
      waiters.removeFirst().resume()
    }
  }
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
  private let deliveryLeaseGate: NotificationDeliveryLeaseGate

  init(
    preferences: NotificationPreferences = .init(),
    eligibilityPolicy: NotificationEligibilityPolicy = .init(),
    scheduling: any NotificationScheduling,
    deliveryLedger: any NotificationDeliveryLedger,
    calendar: Calendar = .current,
    deliveryLeaseGate: NotificationDeliveryLeaseGate = .init()
  ) {
    self.preferences = preferences
    self.eligibilityPolicy = eligibilityPolicy
    self.scheduling = scheduling
    self.deliveryLedger = deliveryLedger
    self.calendar = calendar
    self.deliveryLeaseGate = deliveryLeaseGate
  }

  func updatePreferences(_ preferences: NotificationPreferences) {
    self.preferences = preferences
  }

  func schedule(
    candidate: NotificationCandidate,
    presentation: NotificationPresentation = .init(),
    at date: Date = .now,
    authorizingPreferences: NotificationPreferencesAuthorizing? = nil
  ) async throws -> NotificationScheduleResult {
    await deliveryLeaseGate.acquire()
    do {
      // A task may have been cancelled while queued behind a Settings
      // mutation. Once it owns the lease it must not submit an old request.
      try Task.checkCancellation()
      let result = try await scheduleWhileHoldingDeliveryLease(
        candidate: candidate,
        presentation: presentation,
        at: date,
        authorizingPreferences: authorizingPreferences
      )
      await deliveryLeaseGate.release()
      return result
    } catch {
      await deliveryLeaseGate.release()
      throw error
    }
  }

  private func scheduleWhileHoldingDeliveryLease(
    candidate: NotificationCandidate,
    presentation: NotificationPresentation,
    at date: Date,
    authorizingPreferences: NotificationPreferencesAuthorizing?
  ) async throws -> NotificationScheduleResult {
    guard let initialPreferences = schedulingPreferences(
      preferences,
      for: candidate,
      at: date
    ) else {
      return suppressionResult(for: preferences, candidate: candidate, at: date)
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

    // The observer's initial preferences read may have suspended while vault
    // and scheduler work ran. Read the authoritative account/organization
    // consent again directly at the scheduling boundary so a Settings
    // revocation wins over an in-flight delivery.
    let finalPreferences: NotificationPreferences
    if let authorizingPreferences {
      guard let authorized = await authorizingPreferences(candidate.route) else {
        return .suppressedDisabled
      }
      guard schedulingPreferences(authorized, for: candidate, at: date) != nil else {
        return suppressionResult(for: authorized, candidate: candidate, at: date)
      }
      finalPreferences = authorized
    } else {
      finalPreferences = initialPreferences
    }

    let request = NotificationRequest(
      identifier: payload.dedupeKey.requestIdentifier,
      payload: payload,
      content: NotificationContentFactory.make(
        preferences: finalPreferences,
        presentation: presentation
      )
    )
    // A cancellation can arrive while the authority or pending-request reads
    // above are suspended. Do not start a native add for a request that has
    // already been evicted by its observer.
    try Task.checkCancellation()
    try await scheduling.schedule(request)

    // `UNUserNotificationCenter.add` can complete after eviction has
    // cancelled its delivery task. Remove this exact request before exposing
    // cancellation, and never write a ledger entry for it.
    if Task.isCancelled {
      await scheduling.removePendingNotifications(identifiedBy: [request.identifier])
      throw CancellationError()
    }

    // `UNUserNotificationCenter.add` is asynchronous. A revocation that
    // races that call must remove the newly pending request rather than leave
    // it visible until a later Settings purge reaches the center.
    if let authorizingPreferences {
      guard let confirmedPreferences = await authorizingPreferences(candidate.route),
            schedulingPreferences(confirmedPreferences, for: candidate, at: date) != nil
      else {
        await scheduling.removePendingNotifications(identifiedBy: [request.identifier])
        return .suppressedDisabled
      }
    }
    do {
      // Final authority revalidation may itself suspend. A cancellation in
      // that interval must evict the already-added exact request rather than
      // record a dedupe entry for work the observer abandoned.
      try Task.checkCancellation()
    } catch {
      await scheduling.removePendingNotifications(identifiedBy: [request.identifier])
      throw error
    }
    try await deliveryLedger.record(payload.dedupeKey)
    return .scheduled(replacing: related.count)
  }

  private func schedulingPreferences(
    _ preferences: NotificationPreferences,
    for candidate: NotificationCandidate,
    at date: Date
  ) -> NotificationPreferences? {
    guard preferences.isEnabled,
          preferences.enabledReasons.contains(candidate.reason),
          preferences.quietSchedule?.contains(date, calendar: calendar) != true
    else { return nil }
    return preferences
  }

  private func suppressionResult(
    for preferences: NotificationPreferences,
    candidate: NotificationCandidate,
    at date: Date
  ) -> NotificationScheduleResult {
    guard preferences.isEnabled else { return .suppressedDisabled }
    guard preferences.enabledReasons.contains(candidate.reason) else {
      return .suppressedReasonDisabled
    }
    if preferences.quietSchedule?.contains(date, calendar: calendar) == true {
      return .suppressedQuietHours
    }
    // Keep this branch future-proof if an additional scheduling condition is
    // added above; current callers cannot reach it.
    return .suppressedDisabled
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
