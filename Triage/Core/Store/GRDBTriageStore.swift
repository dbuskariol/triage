import Foundation
import GRDB
import OSLog

enum GRDBTriageStoreError: Error, Equatable, Sendable {
    case invalidScope
}

actor GRDBTriageStore: TriageStore {
    private static let logger = Logger(subsystem: "com.triage.mac", category: "Store")
    private static let retentionMilliseconds: Int64 = 30 * 24 * 60 * 60 * 1_000

    private let vault: AccountVault
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(vault: AccountVault) {
        self.vault = vault
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    func replaceItems(_ items: [PersonalWorkItem], scope: WorkspaceScope, at date: Date) async throws {
        try await validate(scope)
        let itemRecords = try items.map { item in
            StoredItem(
                nodeID: item.id.rawValue,
                json: try encoder.encode(item),
                fingerprint: item.fingerprint,
                urgencyRank: item.primaryRelationship?.urgencyRank ?? Int.max,
                updatedAt: milliseconds(item.updatedAt)
            )
        }
        let seenAt = milliseconds(date)
        let cutoff = seenAt - Self.retentionMilliseconds

        try await vault.writeTransaction { database in
            for item in itemRecords {
                try database.execute(
                    sql: """
                        INSERT INTO triage_items (
                            account_id, organization_id, node_id, item_json, fingerprint,
                            urgency_rank, updated_at_ms, is_active, last_seen_at_ms
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)
                        ON CONFLICT(account_id, organization_id, node_id) DO UPDATE SET
                            item_json = excluded.item_json,
                            fingerprint = excluded.fingerprint,
                            urgency_rank = excluded.urgency_rank,
                            updated_at_ms = excluded.updated_at_ms,
                            is_active = 1,
                            last_seen_at_ms = excluded.last_seen_at_ms
                        """,
                    arguments: [
                        scope.accountID.rawValue, scope.organizationID.rawValue, item.nodeID,
                        item.json, item.fingerprint, item.urgencyRank, item.updatedAt, seenAt
                    ]
                )
                try database.execute(
                    sql: """
                        DELETE FROM triage_analysis_failures
                        WHERE account_id = ? AND organization_id = ? AND node_id = ?
                          AND fingerprint <> ?
                        """,
                    arguments: [scope.accountID.rawValue, scope.organizationID.rawValue, item.nodeID, item.fingerprint]
                )
            }
            try database.execute(
                sql: """
                    UPDATE triage_items SET is_active = 0
                    WHERE account_id = ? AND organization_id = ? AND last_seen_at_ms <> ?
                    """,
                arguments: [scope.accountID.rawValue, scope.organizationID.rawValue, seenAt]
            )
            try database.execute(
                sql: """
                    DELETE FROM triage_decisions
                    WHERE account_id = ? AND organization_id = ? AND node_id IN (
                        SELECT node_id FROM triage_items
                        WHERE account_id = ? AND organization_id = ?
                          AND is_active = 0 AND last_seen_at_ms < ?
                    )
                    """,
                arguments: [scope.accountID.rawValue, scope.organizationID.rawValue,
                            scope.accountID.rawValue, scope.organizationID.rawValue, cutoff]
            )
            try database.execute(
                sql: """
                    DELETE FROM triage_analysis_failures
                    WHERE account_id = ? AND organization_id = ? AND node_id IN (
                        SELECT node_id FROM triage_items
                        WHERE account_id = ? AND organization_id = ?
                          AND is_active = 0 AND last_seen_at_ms < ?
                    )
                    """,
                arguments: [scope.accountID.rawValue, scope.organizationID.rawValue,
                            scope.accountID.rawValue, scope.organizationID.rawValue, cutoff]
            )
            try database.execute(
                sql: """
                    DELETE FROM triage_local_status
                    WHERE account_id = ? AND organization_id = ? AND node_id IN (
                        SELECT node_id FROM triage_items
                        WHERE account_id = ? AND organization_id = ?
                          AND is_active = 0 AND last_seen_at_ms < ?
                    )
                    """,
                arguments: [scope.accountID.rawValue, scope.organizationID.rawValue,
                            scope.accountID.rawValue, scope.organizationID.rawValue, cutoff]
            )
            try database.execute(
                sql: """
                    DELETE FROM triage_read_state
                    WHERE account_id = ? AND organization_id = ? AND node_id IN (
                        SELECT node_id FROM triage_items
                        WHERE account_id = ? AND organization_id = ?
                          AND is_active = 0 AND last_seen_at_ms < ?
                    )
                    """,
                arguments: [scope.accountID.rawValue, scope.organizationID.rawValue,
                            scope.accountID.rawValue, scope.organizationID.rawValue, cutoff]
            )
            try database.execute(
                sql: """
                    DELETE FROM triage_items
                    WHERE account_id = ? AND organization_id = ?
                      AND is_active = 0 AND last_seen_at_ms < ?
                    """,
                arguments: [scope.accountID.rawValue, scope.organizationID.rawValue, cutoff]
            )
            try database.execute(
                sql: """
                    INSERT INTO triage_refreshes (account_id, organization_id, last_refresh_at_ms)
                    VALUES (?, ?, ?)
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET
                        last_refresh_at_ms = excluded.last_refresh_at_ms
                    """,
                arguments: [scope.accountID.rawValue, scope.organizationID.rawValue, seenAt]
            )
        }
    }

    func itemsNeedingAnalysis(
        scope: WorkspaceScope, rulesDigest: String, at date: Date, limit: Int
    ) async throws -> [PersonalWorkItem] {
        try await validate(scope)
        guard limit > 0 else { return [] }
        let decoder = self.decoder
        return try await vault.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT item_json FROM triage_items AS item
                    LEFT JOIN triage_decisions AS decision
                      ON decision.account_id = item.account_id
                     AND decision.organization_id = item.organization_id
                     AND decision.node_id = item.node_id
                    LEFT JOIN triage_analysis_failures AS failure
                      ON failure.account_id = item.account_id
                     AND failure.organization_id = item.organization_id
                     AND failure.node_id = item.node_id
                     AND failure.fingerprint = item.fingerprint
                    WHERE item.account_id = ? AND item.organization_id = ? AND item.is_active = 1
                      AND (decision.fingerprint IS NULL OR decision.fingerprint <> item.fingerprint
                           OR decision.rules_digest <> ?)
                      AND (failure.fingerprint IS NULL OR failure.retry_at_ms <= ?)
                    ORDER BY item.urgency_rank, item.updated_at_ms DESC
                    LIMIT ?
                    """,
                arguments: [scope.accountID.rawValue, scope.organizationID.rawValue, rulesDigest, Self.milliseconds(date), limit]
            )
            return rows.compactMap { row in
                guard let data: Data = row["item_json"] else { return nil }
                do {
                    return try decoder.decode(PersonalWorkItem.self, from: data)
                } catch {
                    Self.logger.error("Skipping malformed triage item.")
                    return nil
                }
            }
        }
    }

    func saveDecisions(_ decisions: [TriageDecision], scope: WorkspaceScope) async throws {
        try await validate(scope)
        let records = try decisions.map {
            StoredDecision(nodeID: $0.itemID.rawValue, fingerprint: $0.fingerprint, json: try encoder.encode($0), decidedAt: milliseconds($0.decidedAt), rulesDigest: $0.rulesDigest ?? "")
        }
        try await vault.writeTransaction { database in
            for decision in records {
                try database.execute(
                    sql: """
                        INSERT INTO triage_decisions (
                            account_id, organization_id, node_id, fingerprint, decision_json, decided_at_ms, rules_digest
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(account_id, organization_id, node_id) DO UPDATE SET
                            fingerprint = excluded.fingerprint,
                            decision_json = excluded.decision_json,
                            decided_at_ms = excluded.decided_at_ms,
                            rules_digest = excluded.rules_digest
                        """,
                    arguments: [scope.accountID.rawValue, scope.organizationID.rawValue, decision.nodeID,
                                decision.fingerprint, decision.json, decision.decidedAt, decision.rulesDigest]
                )
                try database.execute(
                    sql: """
                        DELETE FROM triage_analysis_failures
                        WHERE account_id = ? AND organization_id = ? AND node_id = ? AND fingerprint = ?
                        """,
                    arguments: [scope.accountID.rawValue, scope.organizationID.rawValue,
                                decision.nodeID, decision.fingerprint]
                )
            }
        }
    }

    func recordAnalysisFailure(
        itemIDs: [GitHubNodeID], reason: String, retryAt: Date, scope: WorkspaceScope
    ) async throws {
        try await validate(scope)
        let retryAt = milliseconds(retryAt)
        try await vault.writeTransaction { database in
            for itemID in itemIDs {
                try database.execute(
                    sql: """
                        INSERT INTO triage_analysis_failures (
                            account_id, organization_id, node_id, fingerprint, reason, retry_at_ms, attempts
                        )
                        SELECT account_id, organization_id, node_id, fingerprint, ?, ?, 1
                        FROM triage_items
                        WHERE account_id = ? AND organization_id = ? AND node_id = ?
                        ON CONFLICT(account_id, organization_id, node_id) DO UPDATE SET
                            fingerprint = excluded.fingerprint,
                            reason = excluded.reason,
                            retry_at_ms = excluded.retry_at_ms,
                            attempts = CASE
                                WHEN triage_analysis_failures.fingerprint = excluded.fingerprint
                                THEN triage_analysis_failures.attempts + 1
                                ELSE 1
                            END
                        """,
                    arguments: [reason, retryAt, scope.accountID.rawValue,
                                scope.organizationID.rawValue, itemID.rawValue]
                )
            }
        }
    }

    func setLocalStatus(_ status: LocalStatus, itemID: GitHubNodeID, scope: WorkspaceScope) async throws {
        try await validate(scope)
        try await vault.writeTransaction { database in
            if case .active = status {
                try database.execute(
                    sql: "DELETE FROM triage_local_status WHERE account_id = ? AND organization_id = ? AND node_id = ?",
                    arguments: [scope.accountID.rawValue, scope.organizationID.rawValue, itemID.rawValue]
                )
            } else {
                try database.execute(
                    sql: """
                        INSERT INTO triage_local_status (
                            account_id, organization_id, node_id, status_json, updated_at_ms
                        ) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(account_id, organization_id, node_id) DO UPDATE SET
                            status_json = excluded.status_json, updated_at_ms = excluded.updated_at_ms
                        """,
                    arguments: [scope.accountID.rawValue, scope.organizationID.rawValue, itemID.rawValue,
                                try encoder.encode(status), Self.milliseconds(Date())]
                )
            }
        }
    }

    func setReadAt(_ date: Date?, itemIDs: [GitHubNodeID], scope: WorkspaceScope) async throws {
        guard !itemIDs.isEmpty else { return }
        try await validate(scope)
        try await vault.writeTransaction { database in
            for itemID in itemIDs {
                let arguments: StatementArguments = [scope.accountID.rawValue, scope.organizationID.rawValue, itemID.rawValue]
                if let date {
                    try database.execute(
                        sql: """
                            INSERT INTO triage_read_state (account_id, organization_id, node_id, read_at_ms)
                            VALUES (?, ?, ?, ?)
                            ON CONFLICT(account_id, organization_id, node_id) DO UPDATE SET
                                read_at_ms = excluded.read_at_ms
                            """,
                        arguments: arguments + [Self.milliseconds(date)]
                    )
                } else {
                    try database.execute(
                        sql: "DELETE FROM triage_read_state WHERE account_id = ? AND organization_id = ? AND node_id = ?",
                        arguments: arguments
                    )
                }
            }
        }
    }

    func entries(scope: WorkspaceScope) async throws -> AsyncThrowingStream<[TriageEntry], Error> {
        try await validate(scope)
        let decoder = decoder
        let accountID = scope.accountID.rawValue
        let organizationID = scope.organizationID.rawValue
        var continuation: AsyncThrowingStream<[TriageEntry], Error>.Continuation!
        let stream = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        let valueContinuation = continuation!
        let cancellable = await vault.observe(
            { database in
                try Self.entries(in: database, accountID: accountID, organizationID: organizationID, decoder: decoder)
            },
            onError: { error in valueContinuation.finish(throwing: error) },
            onChange: { entries in
                if case .terminated = valueContinuation.yield(entries) {
                    valueContinuation.finish()
                }
            }
        )
        valueContinuation.onTermination = { @Sendable _ in cancellable.cancel() }
        return stream
    }

    func lastRefreshAt(scope: WorkspaceScope) async throws -> Date? {
        try await validate(scope)
        return try await vault.read { database in
            guard let value = try Int64.fetchOne(
                database,
                sql: "SELECT last_refresh_at_ms FROM triage_refreshes WHERE account_id = ? AND organization_id = ?",
                arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
            ) else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(value) / 1_000)
        }
    }

    func decisions(for ids: [GitHubNodeID], scope: WorkspaceScope) async throws -> [GitHubNodeID: TriageDecision] {
        try await validate(scope)
        guard !ids.isEmpty else { return [:] }
        let decoder = self.decoder
        let wanted = Set(ids.map(\.rawValue))
        return try await vault.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT node_id, decision_json FROM triage_decisions WHERE account_id = ? AND organization_id = ?",
                arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
            )
            var result: [GitHubNodeID: TriageDecision] = [:]
            for row in rows {
                guard let nodeID: String = row["node_id"], wanted.contains(nodeID),
                      let data: Data = row["decision_json"],
                      let decision = try? decoder.decode(TriageDecision.self, from: data)
                else { continue }
                result[decision.itemID] = decision
            }
            return result
        }
    }

    func markHandled(
        _ item: PersonalWorkItem, viewer: String, evidence: String, at date: Date, scope: WorkspaceScope
    ) async throws -> Bool {
        try await validate(scope)
        let status = try encoder.encode(LocalStatus.done(fingerprint: item.fingerprint, at: date, handledEvidence: evidence))
        let at = milliseconds(date)
        let decoder = self.decoder
        return try await vault.writeTransaction { database in
            let arguments: StatementArguments = [scope.accountID.rawValue, scope.organizationID.rawValue, item.id.rawValue]
            // Never override a status the user set while it still applies.
            if let existing = try Data.fetchOne(
                database,
                sql: "SELECT status_json FROM triage_local_status WHERE account_id = ? AND organization_id = ? AND node_id = ?",
                arguments: arguments
            ), try decoder.decode(LocalStatus.self, from: existing).hides(item, at: date, viewer: viewer) {
                return false
            }
            try database.execute(
                sql: """
                    INSERT INTO triage_local_status (account_id, organization_id, node_id, status_json, updated_at_ms)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, organization_id, node_id) DO UPDATE SET
                        status_json = excluded.status_json, updated_at_ms = excluded.updated_at_ms
                    """,
                arguments: arguments + [status, at]
            )
            return true
        }
    }

    func applyDoneStamps(
        _ stamps: [RuleDoneStamp], viewer: String, at date: Date, scope: WorkspaceScope
    ) async throws -> Set<RuleDoneStamp> {
        try await validate(scope)
        guard !stamps.isEmpty else { return [] }
        let encoder = self.encoder
        let decoder = self.decoder
        let stampedAt = Self.milliseconds(date)
        return try await vault.writeTransaction { database in
            var recorded: Set<RuleDoneStamp> = []
            let existing = try Row.fetchAll(
                database,
                sql: """
                    SELECT rule_id, node_id FROM triage_rule_done_stamps
                    WHERE account_id = ? AND organization_id = ?
                    """,
                arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
            )
            let already = Set(existing.compactMap { row -> String? in
                guard let ruleID: String = row["rule_id"], let nodeID: String = row["node_id"] else { return nil }
                return "\(ruleID)|\(nodeID)"
            })
            for stamp in stamps {
                let key = "\(stamp.ruleID.uuidString)|\(stamp.itemID.rawValue)"
                if already.contains(key) {
                    recorded.insert(stamp)
                    continue
                }
                guard let itemData = try Data.fetchOne(
                    database,
                    sql: """
                        SELECT item_json FROM triage_items
                        WHERE account_id = ? AND organization_id = ? AND node_id = ?
                        """,
                    arguments: [scope.accountID.rawValue, scope.organizationID.rawValue, stamp.itemID.rawValue]
                ), let item = try? decoder.decode(PersonalWorkItem.self, from: itemData) else { continue }
                if let statusData = try Data.fetchOne(
                    database,
                    sql: """
                        SELECT status_json FROM triage_local_status
                        WHERE account_id = ? AND organization_id = ? AND node_id = ?
                        """,
                    arguments: [scope.accountID.rawValue, scope.organizationID.rawValue, stamp.itemID.rawValue]
                ), let status = try? decoder.decode(LocalStatus.self, from: statusData),
                   status.hides(item, at: date, viewer: viewer) {
                    continue
                }
                let done = try encoder.encode(LocalStatus.done(fingerprint: item.fingerprint, at: date))
                try database.execute(
                    sql: """
                        INSERT INTO triage_local_status (
                            account_id, organization_id, node_id, status_json, updated_at_ms
                        ) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(account_id, organization_id, node_id) DO UPDATE SET
                            status_json = excluded.status_json, updated_at_ms = excluded.updated_at_ms
                        """,
                    arguments: [
                        scope.accountID.rawValue, scope.organizationID.rawValue, stamp.itemID.rawValue,
                        done, stampedAt
                    ]
                )
                try database.execute(
                    sql: """
                        INSERT OR IGNORE INTO triage_rule_done_stamps (
                            account_id, organization_id, node_id, rule_id, stamped_at_ms
                        ) VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        scope.accountID.rawValue, scope.organizationID.rawValue, stamp.itemID.rawValue,
                        stamp.ruleID.uuidString, stampedAt
                    ]
                )
                recorded.insert(stamp)
            }
            return recorded
        }
    }

    func rules(scope: WorkspaceScope) async throws -> TriageRules {
        try await validate(scope)
        let decoder = self.decoder
        let data = try await vault.read { database in
            try Data.fetchOne(
                database,
                sql: "SELECT rules_json FROM triage_rules WHERE account_id = ? AND organization_id = ?",
                arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
            )
        }
        guard let data else { return .empty }
        do {
            return try decoder.decode(TriageRules.self, from: data)
        } catch {
            Self.logger.error("Saved triage rules are unreadable; using none.")
            return .empty
        }
    }

    func saveRules(_ rules: TriageRules, scope: WorkspaceScope) async throws {
        try await validate(scope)
        let data = try encoder.encode(try rules.validated())
        try await vault.writeTransaction { database in
            try database.execute(
                sql: """
                    INSERT INTO triage_rules (account_id, organization_id, rules_json, updated_at_ms)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(account_id, organization_id) DO UPDATE SET
                        rules_json = excluded.rules_json, updated_at_ms = excluded.updated_at_ms
                    """,
                arguments: [scope.accountID.rawValue, scope.organizationID.rawValue, data, Self.milliseconds(Date())]
            )
        }
        Self.logger.notice("rules saved rules=\(rules.rules.count, privacy: .public) hasInstructions=\(rules.trimmedInstructions != nil, privacy: .public)")
    }

    private func validate(_ scope: WorkspaceScope) async throws {
        guard scope.accountID == vault.accountID else { throw GRDBTriageStoreError.invalidScope }
    }

    private static func entries(
        in database: Database, accountID: String, organizationID: String, decoder: JSONDecoder
    ) throws -> [TriageEntry] {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT item.item_json, item.fingerprint AS item_fingerprint,
                       decision.decision_json, decision.fingerprint AS decision_fingerprint,
                       failure.fingerprint AS failure_fingerprint, failure.reason, failure.retry_at_ms,
                       local.status_json, read.read_at_ms
                FROM triage_items AS item
                LEFT JOIN triage_decisions AS decision
                  ON decision.account_id = item.account_id AND decision.organization_id = item.organization_id
                 AND decision.node_id = item.node_id
                LEFT JOIN triage_analysis_failures AS failure
                  ON failure.account_id = item.account_id AND failure.organization_id = item.organization_id
                 AND failure.node_id = item.node_id AND failure.fingerprint = item.fingerprint
                LEFT JOIN triage_local_status AS local
                  ON local.account_id = item.account_id AND local.organization_id = item.organization_id
                 AND local.node_id = item.node_id
                LEFT JOIN triage_read_state AS read
                  ON read.account_id = item.account_id AND read.organization_id = item.organization_id
                 AND read.node_id = item.node_id
                WHERE item.account_id = ? AND item.organization_id = ? AND item.is_active = 1
                ORDER BY item.urgency_rank, item.updated_at_ms DESC
                """,
            arguments: [accountID, organizationID]
        )
        return rows.compactMap { row in
            do {
                guard let itemData: Data = row["item_json"] else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Missing item.")) }
                let item = try decoder.decode(PersonalWorkItem.self, from: itemData)
                let decisionData: Data? = row["decision_json"]
                let decision = try decisionData.map { try decoder.decode(TriageDecision.self, from: $0) }
                let localData: Data? = row["status_json"]
                let local = try localData.map { try decoder.decode(LocalStatus.self, from: $0) } ?? .active
                let decisionFingerprint: String? = row["decision_fingerprint"]
                let failureFingerprint: String? = row["failure_fingerprint"]
                let analysis: AnalysisState
                if decisionFingerprint == item.fingerprint {
                    analysis = .current
                } else if failureFingerprint == item.fingerprint,
                          let reason: String = row["reason"],
                          let retryAt: Int64 = row["retry_at_ms"] {
                    analysis = .failed(reason: reason, retryAt: Date(timeIntervalSince1970: TimeInterval(retryAt) / 1_000))
                } else {
                    analysis = .pending
                }
                let readAt = (row["read_at_ms"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
                return TriageEntry(item: item, decision: decision, analysis: analysis, local: local, readAt: readAt)
            } catch {
                logger.error("Skipping malformed triage entry.")
                return nil
            }
        }
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Self.milliseconds(date)
    }
}

private struct StoredItem: Sendable {
    let nodeID: String
    let json: Data
    let fingerprint: String
    let urgencyRank: Int
    let updatedAt: Int64
}

private struct StoredDecision: Sendable {
    let nodeID: String
    let fingerprint: String
    let json: Data
    let decidedAt: Int64
    let rulesDigest: String
}
