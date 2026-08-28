import Foundation
import GRDB

enum NotificationDeliveryLedgerError: Error, Equatable, Sendable {
  case accountScopeMismatch
  case workItemScopeMismatch
  case invalidEvidenceVersion
}

protocol NotificationDeliveryLedger: Sendable {
  func contains(_ key: NotificationDedupeKey) async throws -> Bool
  func record(_ key: NotificationDedupeKey) async throws
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

actor PersistentNotificationDeliveryLedger: NotificationDeliveryLedger {
  private static let maximumEvidenceVersionLength = 2_048

  private let vault: AccountVault

  init(vault: AccountVault) {
    self.vault = vault
  }

  func contains(_ key: NotificationDedupeKey) async throws -> Bool {
    try await validate(key)
    return try await vault.read { database in
      try Bool.fetchOne(
        database,
        sql: """
          SELECT EXISTS(
            SELECT 1
            FROM notification_deliveries
            WHERE dedupe_key = ? AND account_id = ? AND organization_id = ? AND work_item_id = ?
          )
          """,
        arguments: [
          key.requestIdentifier,
          key.route.accountID.rawValue,
          key.route.organizationID.rawValue,
          key.route.workItemID.rawValue,
        ]
      ) ?? false
    }
  }

  func record(_ key: NotificationDedupeKey) async throws {
    try await validate(key)
    let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    try await vault.write { database in
      try database.execute(
        sql: """
          INSERT OR IGNORE INTO notification_deliveries (
            dedupe_key, account_id, organization_id, work_item_id, reason, evidence_version, delivered_at_ms
          ) VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          key.requestIdentifier,
          key.route.accountID.rawValue,
          key.route.organizationID.rawValue,
          key.route.workItemID.rawValue,
          key.reason.rawValue,
          key.evidenceVersion,
          now,
        ]
      )
    }
  }

  private func validate(_ key: NotificationDedupeKey) async throws {
    guard key.route.accountID == vault.accountID else {
      throw NotificationDeliveryLedgerError.accountScopeMismatch
    }
    guard !key.evidenceVersion.isEmpty,
      key.evidenceVersion.count <= Self.maximumEvidenceVersionLength
    else {
      throw NotificationDeliveryLedgerError.invalidEvidenceVersion
    }
    let ownsWorkItem = try await vault.read { database in
      try Bool.fetchOne(
        database,
        sql: """
          SELECT EXISTS(
            SELECT 1
            FROM work_items
            WHERE id = ? AND account_id = ? AND organization_id = ?
          )
          """,
        arguments: [
          key.route.workItemID.rawValue,
          key.route.accountID.rawValue,
          key.route.organizationID.rawValue,
        ]
      ) ?? false
    }
    guard ownsWorkItem else {
      throw NotificationDeliveryLedgerError.workItemScopeMismatch
    }
  }
}
