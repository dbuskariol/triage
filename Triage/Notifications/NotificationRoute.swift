import CryptoKit
import Foundation

struct NotificationRoute: Codable, Equatable, Hashable, Sendable {
  let accountID: AccountID
  let organizationID: OrganizationID
  let workItemID: WorkItemID
  let destination: NotificationDestination

  init(
    accountID: AccountID,
    organizationID: OrganizationID,
    workItemID: WorkItemID,
    destination: NotificationDestination = .inbox
  ) {
    self.accountID = accountID
    self.organizationID = organizationID
    self.workItemID = workItemID
    self.destination = destination
  }
}

enum NotificationDestination: String, Codable, Sendable {
  case inbox
}

enum NotificationReason: String, CaseIterable, Codable, Sendable {
  case directAssignment
  case directReviewRequest
  case teamReviewRequest
  case highPriorityInboxItem
  case waitingResponse
  case snoozeDue
  case explicitDeadline
}

struct NotificationDedupeKey: Codable, Equatable, Hashable, Sendable {
  let route: NotificationRoute
  let reason: NotificationReason
  let evidenceVersion: String

  init(route: NotificationRoute, reason: NotificationReason, evidenceVersion: String) {
    self.route = route
    self.reason = reason
    self.evidenceVersion = evidenceVersion
  }

  var requestIdentifier: String {
    let canonicalValue = [
      route.accountID.rawValue,
      route.organizationID.rawValue,
      route.workItemID.rawValue,
      route.destination.rawValue,
      reason.rawValue,
      evidenceVersion,
    ].joined(separator: "\u{1F}")
    let digest = SHA256.hash(data: Data(canonicalValue.utf8))
    let digestString = digest.map { String(format: "%02x", $0) }.joined()
    return "triage.notification.\(digestString)"
  }
}

struct NotificationPayload: Codable, Equatable, Sendable {
  let route: NotificationRoute
  let reason: NotificationReason
  let evidenceVersion: String

  init(route: NotificationRoute, reason: NotificationReason, evidenceVersion: String) {
    self.route = route
    self.reason = reason
    self.evidenceVersion = evidenceVersion
  }

  var dedupeKey: NotificationDedupeKey {
    NotificationDedupeKey(
      route: route,
      reason: reason,
      evidenceVersion: evidenceVersion
    )
  }
}

enum NotificationPayloadCodec {
  static let userInfoKey = "triage.notification.payload"

  static func encode(_ payload: NotificationPayload) throws -> String {
    let data = try JSONEncoder().encode(payload)
    guard let string = String(data: data, encoding: .utf8) else {
      throw NotificationPayloadError.encodingFailed
    }
    return string
  }

  static func decode(userInfo: [AnyHashable: Any]) -> NotificationPayload? {
    guard let string = userInfo[userInfoKey] as? String,
      let data = string.data(using: .utf8)
    else {
      return nil
    }

    return try? JSONDecoder().decode(NotificationPayload.self, from: data)
  }
}

enum NotificationPayloadError: Error, Equatable, Sendable {
  case encodingFailed
}
