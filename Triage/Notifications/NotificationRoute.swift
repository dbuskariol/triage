import CryptoKit
import Foundation
import Security

struct NotificationRoute: Codable, Equatable, Hashable, Sendable {
  let accountID: AccountID
  let organizationID: OrganizationID
  let workItemID: WorkItemID
  let destination: NotificationDestination
  /// Present only on a verified response action. Scheduling and persisted
  /// payload routes deliberately carry no mutable-action authority here.
  let actionAuthorization: NotificationActionAuthorization?

  init(
    accountID: AccountID,
    organizationID: OrganizationID,
    workItemID: WorkItemID,
    destination: NotificationDestination = .inbox,
    actionAuthorization: NotificationActionAuthorization? = nil
  ) {
    self.accountID = accountID
    self.organizationID = organizationID
    self.workItemID = workItemID
    self.destination = destination
    self.actionAuthorization = actionAuthorization
  }

  func authorizingAction(reason: NotificationReason, evidenceVersion: String) -> NotificationRoute {
    NotificationRoute(
      accountID: accountID,
      organizationID: organizationID,
      workItemID: workItemID,
      destination: destination,
      actionAuthorization: .init(reason: reason, evidenceVersion: evidenceVersion)
    )
  }
}

struct NotificationActionAuthorization: Codable, Equatable, Hashable, Sendable {
  let reason: NotificationReason
  let evidenceVersion: String
}

enum NotificationDestination: String, Codable, Sendable {
  case inbox
}

enum NotificationReason: String, CaseIterable, Codable, Hashable, Sendable {
  case directAssignment
  case directReviewRequest
  case teamReviewRequest
  case highPriorityInboxItem
  case waitingResponse
  case snoozeDue
  case explicitDeadline
}

extension NotificationReason {
  /// User-facing labels intentionally describe a local Triage condition rather
  /// than reproducing GitHub content in Settings.
  var title: String {
    switch self {
    case .directAssignment: "Assigned to you"
    case .directReviewRequest: "Direct review request"
    case .teamReviewRequest: "Team review request"
    case .highPriorityInboxItem: "High-priority inbox item"
    case .waitingResponse: "Waiting for a response"
    case .snoozeDue: "Snooze is due"
    case .explicitDeadline: "Upcoming deadline"
    }
  }

  var notificationSettingsTitle: String { title }
}

struct NotificationDedupeKey: Codable, Equatable, Hashable, Sendable {
  private static let requestIdentifierNamespace = "triage.notification.account"

  let route: NotificationRoute
  let reason: NotificationReason
  let evidenceVersion: String

  init(route: NotificationRoute, reason: NotificationReason, evidenceVersion: String) {
    self.route = route
    self.reason = reason
    self.evidenceVersion = evidenceVersion
  }

  /// A stable, opaque prefix lets local account removal target only this
  /// account's pending and delivered requests without inspecting notification
  /// payloads. Account IDs never appear in the identifier itself.
  static func requestIdentifierPrefix(for accountID: AccountID) -> String {
    let digest = SHA256.hash(data: Data(accountID.rawValue.utf8))
    let digestString = digest.map { String(format: "%02x", $0) }.joined()
    return "\(requestIdentifierNamespace).\(digestString)."
  }

  /// Opaque, hierarchical prefixes allow scope-specific cleanup without
  /// decoding notification payloads from the system notification store.
  static func requestIdentifierPrefix(
    for accountID: AccountID,
    organizationID: OrganizationID
  ) -> String {
    requestIdentifierPrefix(for: accountID)
      + "organization.\(digest(organizationID.rawValue))."
  }

  static func requestIdentifierPrefix(for route: NotificationRoute) -> String {
    requestIdentifierPrefix(for: route.accountID, organizationID: route.organizationID)
      + "work-item.\(digest(route.workItemID.rawValue))."
  }

  static var requestIdentifierNamespacePrefix: String {
    "\(requestIdentifierNamespace)."
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
    return Self.requestIdentifierPrefix(for: route) + Self.digest(canonicalValue)
  }

  private static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
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

  private struct SignedPayload: Codable {
    let payload: NotificationPayload
    let authenticationCode: String
  }

  static func encode(_ payload: NotificationPayload) throws -> String {
    try encode(payload, authenticator: KeychainNotificationPayloadAuthenticator())
  }

  static func encode(
    _ payload: NotificationPayload,
    authenticator: any NotificationPayloadAuthenticating
  ) throws -> String {
    let payloadData = try canonicalData(for: payload)
    let envelope = SignedPayload(
      payload: payload,
      authenticationCode: try authenticator.authenticationCode(for: payloadData)
    )
    let data = try JSONEncoder().encode(envelope)
    guard let string = String(data: data, encoding: .utf8) else {
      throw NotificationPayloadError.encodingFailed
    }
    return string
  }

  static func decode(userInfo: [AnyHashable: Any]) -> NotificationPayload? {
    decode(userInfo: userInfo, authenticator: KeychainNotificationPayloadAuthenticator())
  }

  static func decode(
    userInfo: [AnyHashable: Any],
    authenticator: any NotificationPayloadAuthenticating
  ) -> NotificationPayload? {
    guard let string = userInfo[userInfoKey] as? String,
      let data = string.data(using: .utf8),
      let signed = try? JSONDecoder().decode(SignedPayload.self, from: data),
      let payloadData = try? canonicalData(for: signed.payload),
      (try? authenticator.isValid(authenticationCode: signed.authenticationCode, for: payloadData)) == true
    else {
      return nil
    }

    return signed.payload
  }

  private static func canonicalData(for payload: NotificationPayload) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(payload)
  }

}

enum NotificationPayloadError: Error, Equatable, Sendable {
  case encodingFailed
}

protocol NotificationPayloadAuthenticating: Sendable {
  func authenticationCode(for payload: Data) throws -> String
  func isValid(authenticationCode: String, for payload: Data) throws -> Bool
}

/// Device-only Keychain authentication for notification response payloads.
/// A missing or unavailable key fails closed, so userInfo cannot authorize a
/// local workflow mutation merely by decoding successfully.
struct KeychainNotificationPayloadAuthenticator: NotificationPayloadAuthenticating {
  private static let service = "com.triage.mac.notification-payload"
  private static let account = "v1"
  private static let keyLength = 32

  func authenticationCode(for payload: Data) throws -> String {
    HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: try key()))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  func isValid(authenticationCode: String, for payload: Data) throws -> Bool {
    guard let codeData = Data(hexadecimalString: authenticationCode) else { return false }
    return HMAC<SHA256>.isValidAuthenticationCode(
      codeData,
      authenticating: payload,
      using: SymmetricKey(data: try key())
    )
  }

  private func key() throws -> Data {
    let query = Self.query
    var readQuery = query
    readQuery[kSecReturnData as String] = true
    readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
    if readStatus == errSecSuccess {
      guard let data = result as? Data, data.count == Self.keyLength else {
        throw NotificationPayloadAuthenticationError.invalidKey
      }
      return data
    }
    guard readStatus == errSecItemNotFound else {
      throw NotificationPayloadAuthenticationError.keychain(readStatus)
    }

    var generator = SystemRandomNumberGenerator()
    let generated = Data((0..<Self.keyLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    var insert = query
    insert[kSecValueData as String] = generated
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let addStatus = SecItemAdd(insert as CFDictionary, nil)
    if addStatus == errSecSuccess { return generated }
    if addStatus == errSecDuplicateItem {
      return try key()
    }
    throw NotificationPayloadAuthenticationError.keychain(addStatus)
  }

  private static var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
    ]
  }
}

enum NotificationPayloadAuthenticationError: Error, Equatable, Sendable {
  case invalidKey
  case keychain(OSStatus)
}

private extension Data {
  init?(hexadecimalString value: String) {
    guard value.count == 64 else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(value.count / 2)
    var index = value.startIndex
    while index < value.endIndex {
      let next = value.index(index, offsetBy: 2)
      guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    self.init(bytes)
  }
}
