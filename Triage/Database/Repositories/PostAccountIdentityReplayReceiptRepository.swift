import CryptoKit
import Foundation
import GRDB

/// Account-scoped `/user/orgs` replay must not be represented by an invented
/// organization scope.  These identities are intentionally separate from
/// `ConditionalRequestIdentity`, which is only valid after an organization
/// capability scope exists.
struct AccountOrganizationInventoryReplayIdentity: Equatable, Sendable {
    static let requestKey = "GET /user/orgs?per_page=100"

    let accountID: AccountID
    let credentialRevision: CredentialRevision
}

struct OrganizationMetadataReplayIdentity: Equatable, Sendable {
    let scope: SynchronizationScope
    let streamID: SyncStreamID
    let requestKey: String
}

enum PostAccountIdentityReplayReceiptRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case staleAuthority
    case invalidRequest
    case invalidValidator
    case invalidReceipt
    case invalidRawEvidence
    case invalidOrganization
    case ssoEvidencePreventsReplay
    /// A transport 304 may still carry GitHub's SSO recovery evidence. Keep
    /// that evidence intact so callers can distinguish required, partial, and
    /// malformed SSO state instead of treating it as receipt corruption.
    case ssoRequirement(GitHubSSOHeader)
}

actor PostAccountIdentityReplayReceiptRepository {
    static let parserVersion = 1
    static let maximumPages = 100
    static let maximumObjectsPerPage = 100
    static let maximumRawPageBytes = 2 * 1_024 * 1_024
    static let maximumInventoryAggregateRawBytes = 1 * 1_024 * 1_024
    static let maximumMetadataRawPayloadBytes = 256 * 1_024

    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func ensureMetadataStream(for scope: SynchronizationScope) async throws -> SyncStreamID {
        try Task.checkCancellation()
        guard scope.accountID == vault.accountID else {
            throw PostAccountIdentityReplayReceiptRepositoryError.accountScopeMismatch
        }
        let streamID = SyncStreamID(rawValue: "organization-metadata-\(scope.organizationID.rawValue)")!
        let attemptedAt = Self.milliseconds(Date())
        try await vault.writeTransaction { database in
            try Task.checkCancellation()
            try Self.validateMetadataScope(scope, in: database)
            try Task.checkCancellation()
            // Do not reset an existing stream or claim completion before the
            // metadata response has passed its exact authority checks.
            try database.execute(sql: """
                INSERT INTO sync_streams (
                    id, account_id, organization_id, feature, high_water_ms,
                    last_successful_at_ms, last_attempt_at_ms, state, failure_detail
                ) VALUES (?, ?, ?, 'organizationMetadata', NULL, NULL, ?, 'unknown', NULL)
                ON CONFLICT(id) DO NOTHING
                """, arguments: [
                    streamID.rawValue, scope.accountID.rawValue,
                    scope.organizationID.rawValue, attemptedAt
                ])
        }
        return streamID
    }

    func inventoryValidators(
        for identity: AccountOrganizationInventoryReplayIdentity
    ) async throws -> GitHubHTTPValidators? {
        guard identity.accountID == vault.accountID else {
            throw PostAccountIdentityReplayReceiptRepositoryError.accountScopeMismatch
        }
        return try await vault.read { database in
            try Self.validateInventoryAuthority(identity, in: database)
            guard let row = try Row.fetchOne(database, sql: """
                SELECT etag, last_modified FROM account_organization_inventory_replay_receipts
                WHERE account_id = ? AND credential_revision = ? AND request_key = ?
                """, arguments: [identity.accountID.rawValue, identity.credentialRevision.rawValue, AccountOrganizationInventoryReplayIdentity.requestKey])
            else { return nil }
            return try? Self.validators(eTag: row["etag"], lastModified: row["last_modified"])
        }
    }

    /// A failed inventory attempt must not advance the successful-receipt
    /// timestamp, otherwise daily identity validation could hide incomplete
    /// organization visibility for a full cadence interval.
    func inventoryValidatedAt(
        for identity: AccountOrganizationInventoryReplayIdentity
    ) async throws -> Date? {
        guard identity.accountID == vault.accountID else {
            throw PostAccountIdentityReplayReceiptRepositoryError.accountScopeMismatch
        }
        return try await vault.read { database in
            try Self.validateInventoryAuthority(identity, in: database)
            guard let milliseconds: Int64 = try Int64.fetchOne(database, sql: """
                SELECT validated_at_ms FROM account_organization_inventory_replay_receipts
                WHERE account_id = ? AND credential_revision = ? AND request_key = ?
                """, arguments: [
                    identity.accountID.rawValue,
                    identity.credentialRevision.rawValue,
                    AccountOrganizationInventoryReplayIdentity.requestKey
                ]) else {
                return nil
            }
            return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
        }
    }

    func replaceInventory(
        _ inventory: GitHubOrganizationInventory,
        for identity: AccountOrganizationInventoryReplayIdentity,
        observedAt: Date
    ) async throws {
        try Task.checkCancellation()
        guard identity.accountID == vault.accountID else {
            throw PostAccountIdentityReplayReceiptRepositoryError.accountScopeMismatch
        }
        try await vault.writeTransaction { database in
            try Task.checkCancellation()
            try Self.validateInventoryAuthority(identity, in: database)
            try Self.replaceInventory(inventory, identity: identity, observedAt: observedAt, in: database)
        }
    }

    /// A 304 only yields inventory when all page payloads, topology, validators
    /// and normalized digest still validate under the exact current account and
    /// credential revision.  It never manufactures an empty inventory.
    func validatedInventory(
        for identity: AccountOrganizationInventoryReplayIdentity,
        validatedAt: Date
    ) async throws -> GitHubOrganizationInventory? {
        guard identity.accountID == vault.accountID else {
            throw PostAccountIdentityReplayReceiptRepositoryError.accountScopeMismatch
        }
        try Task.checkCancellation()
        return try await vault.writeTransaction { database in
            try Task.checkCancellation()
            try Self.validateInventoryAuthority(identity, in: database)
            do {
                return try Self.validatedInventory(identity, validatedAt: validatedAt, in: database)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return nil
            }
        }
    }

    func metadataValidators(
        for identity: OrganizationMetadataReplayIdentity,
        organization: GitHubOrganization
    ) async throws -> GitHubHTTPValidators? {
        guard identity.scope.accountID == vault.accountID else {
            throw PostAccountIdentityReplayReceiptRepositoryError.accountScopeMismatch
        }
        return try await vault.read { database in
            try Self.validateMetadataAuthority(identity, organization: organization, in: database)
            guard let row = try Row.fetchOne(database, sql: """
                SELECT etag, last_modified FROM organization_metadata_replay_receipts
                WHERE account_id = ? AND organization_id = ? AND credential_revision = ?
                  AND capability_revision = ? AND feature = 'organizationMetadata'
                  AND stream_id = ? AND request_key = ?
                """, arguments: [
                    identity.scope.accountID.rawValue, identity.scope.organizationID.rawValue,
                    identity.scope.credentialRevision.rawValue, identity.scope.capabilityRevision.rawValue,
                    identity.streamID.rawValue, identity.requestKey
                ]) else { return nil }
            return try? Self.validators(eTag: row["etag"], lastModified: row["last_modified"])
        }
    }

    func replaceMetadata(
        _ response: GitHubResponse<GitHubOrganizationDTO>,
        for identity: OrganizationMetadataReplayIdentity,
        organization: GitHubOrganization,
        observedAt: Date
    ) async throws {
        try Task.checkCancellation()
        guard identity.scope.accountID == vault.accountID else {
            throw PostAccountIdentityReplayReceiptRepositoryError.accountScopeMismatch
        }
        let streamID = try await ensureMetadataStream(for: identity.scope)
        guard streamID == identity.streamID else {
            throw PostAccountIdentityReplayReceiptRepositoryError.invalidRequest
        }
        try Task.checkCancellation()
        try await vault.writeTransaction { database in
            try Task.checkCancellation()
            try Self.validateMetadataAuthority(identity, organization: organization, in: database)
            try Self.validateOrganization(response.value, matches: organization)
            guard response.ssoHeader == nil else {
                throw PostAccountIdentityReplayReceiptRepositoryError.ssoEvidencePreventsReplay
            }
            guard let validators = try? GitHubHTTPValidators(eTag: response.etag, lastModified: response.lastModified) else {
                throw PostAccountIdentityReplayReceiptRepositoryError.invalidValidator
            }
            guard validators.eTag != nil || validators.lastModified != nil else {
                throw PostAccountIdentityReplayReceiptRepositoryError.invalidValidator
            }
            guard response.payload.count <= Self.maximumMetadataRawPayloadBytes else {
                throw PostAccountIdentityReplayReceiptRepositoryError.invalidRawEvidence
            }
            let snapshot = try Self.rawSnapshot(
                accountID: identity.scope.accountID,
                githubNodeID: organization.nodeID,
                endpoint: Self.endpoint(from: identity.requestKey),
                eTag: response.etag,
                lastModified: response.lastModified,
                payload: response.payload,
                observedAt: observedAt,
                discriminator: identity.requestKey,
                requestIdentity: ConditionalRequestIdentity(
                    scope: identity.scope,
                    feature: .organizationMetadata,
                    streamID: identity.streamID,
                    requestKey: identity.requestKey
                )
            )
            try Task.checkCancellation()
            try RawAPISnapshotRepository.save(snapshot, in: database)
            try Task.checkCancellation()
            try database.execute(sql: """
                DELETE FROM organization_metadata_replay_receipts
                WHERE account_id = ? AND organization_id = ? AND feature = 'organizationMetadata'
                  AND stream_id = ? AND request_key = ?
                """, arguments: [identity.scope.accountID.rawValue, identity.scope.organizationID.rawValue, identity.streamID.rawValue, identity.requestKey])
            try database.execute(sql: """
                INSERT INTO organization_metadata_replay_receipts (
                    id, account_id, organization_id, feature, stream_id, credential_revision,
                    capability_revision, request_key, etag, last_modified, raw_snapshot_id,
                    raw_payload_digest, normalized_digest, parser_version, source_revision,
                    observed_at_ms, committed_at_ms, validated_at_ms, receipt_version
                ) VALUES (?, ?, ?, 'organizationMetadata', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                """, arguments: [
                    Self.receiptID(domain: "metadata", values: [identity.scope.accountID.rawValue, identity.scope.organizationID.rawValue, identity.scope.credentialRevision.rawValue, identity.scope.capabilityRevision.rawValue, identity.streamID.rawValue, identity.requestKey, Self.hex(Self.digest(response.payload))]),
                    identity.scope.accountID.rawValue, identity.scope.organizationID.rawValue,
                    identity.streamID.rawValue, identity.scope.credentialRevision.rawValue,
                    identity.scope.capabilityRevision.rawValue, identity.requestKey,
                    response.etag, response.lastModified, snapshot.id.rawValue,
                    Self.digest(response.payload), Self.organizationDigest([response.value]), Self.parserVersion,
                    Self.hex(Self.digest(response.payload)), Self.milliseconds(observedAt),
                    Self.milliseconds(observedAt), Self.milliseconds(observedAt)
                ])
            try Task.checkCancellation()
            try database.execute(sql: """
                UPDATE sync_streams
                SET last_successful_at_ms = ?, last_attempt_at_ms = ?, state = 'complete', failure_detail = NULL
                WHERE id = ? AND account_id = ? AND organization_id = ? AND feature = 'organizationMetadata'
                """, arguments: [
                    Self.milliseconds(observedAt), Self.milliseconds(observedAt),
                    identity.streamID.rawValue, identity.scope.accountID.rawValue,
                    identity.scope.organizationID.rawValue
                ])
        }
    }

    func validatedMetadata(
        for identity: OrganizationMetadataReplayIdentity,
        organization: GitHubOrganization,
        validatedAt: Date
    ) async throws -> GitHubResponse<GitHubOrganizationDTO>? {
        guard identity.scope.accountID == vault.accountID else {
            throw PostAccountIdentityReplayReceiptRepositoryError.accountScopeMismatch
        }
        try Task.checkCancellation()
        return try await vault.writeTransaction { database in
            try Task.checkCancellation()
            try Self.validateMetadataAuthority(identity, organization: organization, in: database)
            do {
                guard let row = try Row.fetchOne(database, sql: """
                SELECT raw_snapshot_id, etag, last_modified, raw_payload_digest, normalized_digest,
                       parser_version, source_revision
                FROM organization_metadata_replay_receipts
                WHERE account_id = ? AND organization_id = ? AND credential_revision = ?
                  AND capability_revision = ? AND feature = 'organizationMetadata'
                  AND stream_id = ? AND request_key = ?
                """, arguments: [identity.scope.accountID.rawValue, identity.scope.organizationID.rawValue,
                                     identity.scope.credentialRevision.rawValue, identity.scope.capabilityRevision.rawValue,
                                     identity.streamID.rawValue, identity.requestKey]),
                  let rawID = RawAPISnapshotID(rawValue: row["raw_snapshot_id"]),
                  let snapshot = try Self.snapshot(rawID, accountID: identity.scope.accountID, in: database),
                  (row["parser_version"] as Int?) == Self.parserVersion,
                  (row["raw_payload_digest"] as Data?) == Self.digest(snapshot.payload),
                  (row["source_revision"] as String?) == Self.hex(Self.digest(snapshot.payload)),
                  let dto = try? Self.githubDecoder.decode(GitHubOrganizationDTO.self, from: snapshot.payload),
                  (row["normalized_digest"] as Data?) == Self.organizationDigest([dto]),
                  snapshot.payload.count <= Self.maximumMetadataRawPayloadBytes,
                  snapshot.githubNodeID == organization.nodeID
                else { return nil }
                try Self.validateOrganization(dto, matches: organization)
                guard snapshot.endpoint == Self.endpoint(from: identity.requestKey),
                  snapshot.eTag == (row["etag"] as String?),
                  snapshot.lastModified == (row["last_modified"] as String?),
                  snapshot.parserVersion == Self.parserVersion,
                  snapshot.requestIdentity == ConditionalRequestIdentity(
                    scope: identity.scope,
                    feature: .organizationMetadata,
                    streamID: identity.streamID,
                    requestKey: identity.requestKey
                  )
                else { return nil }
                try Task.checkCancellation()
                try database.execute(sql: """
                UPDATE organization_metadata_replay_receipts SET validated_at_ms = ?
                WHERE account_id = ? AND organization_id = ? AND credential_revision = ?
                  AND capability_revision = ? AND feature = 'organizationMetadata'
                  AND stream_id = ? AND request_key = ?
                """, arguments: [Self.milliseconds(validatedAt), identity.scope.accountID.rawValue,
                                     identity.scope.organizationID.rawValue, identity.scope.credentialRevision.rawValue,
                                     identity.scope.capabilityRevision.rawValue, identity.streamID.rawValue, identity.requestKey])
                try Task.checkCancellation()
                try database.execute(sql: """
                    UPDATE sync_streams
                    SET last_successful_at_ms = ?, last_attempt_at_ms = ?, state = 'complete', failure_detail = NULL
                    WHERE id = ? AND account_id = ? AND organization_id = ? AND feature = 'organizationMetadata'
                    """, arguments: [
                        Self.milliseconds(validatedAt), Self.milliseconds(validatedAt),
                        identity.streamID.rawValue, identity.scope.accountID.rawValue,
                        identity.scope.organizationID.rawValue
                    ])
                return GitHubResponse(value: dto, payload: snapshot.payload, etag: snapshot.eTag, lastModified: snapshot.lastModified, ssoHeader: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return nil
            }
        }
    }

    private nonisolated static func replaceInventory(
        _ inventory: GitHubOrganizationInventory,
        identity: AccountOrganizationInventoryReplayIdentity,
        observedAt: Date,
        in database: Database
    ) throws {
        guard inventory.ssoHeaders.isEmpty else {
            throw PostAccountIdentityReplayReceiptRepositoryError.ssoEvidencePreventsReplay
        }
        guard !inventory.pages.isEmpty, inventory.pages.count <= maximumPages,
              inventory.pages.first?.requestKey == AccountOrganizationInventoryReplayIdentity.requestKey,
              inventory.pages.last?.nextRequestKey == nil,
              inventory.pages.enumerated().allSatisfy({ offset, page in
                  page.requestKey == expectedInventoryRequestKey(page: offset + 1) &&
                  page.nextRequestKey == expectedInventoryNextRequestKey(page: offset + 1, totalPages: inventory.pages.count)
              }),
              let first = inventory.pages.first,
              first.page.etag != nil || first.page.lastModified != nil,
              inventory.pages.reduce(0, { $0 + $1.page.payload.count }) <= maximumInventoryAggregateRawBytes
        else { throw PostAccountIdentityReplayReceiptRepositoryError.invalidReceipt }
        let flattened = inventory.pages.flatMap { $0.page.values }
        try validateOrganizations(flattened)
        guard flattened == inventory.organizations else { throw PostAccountIdentityReplayReceiptRepositoryError.invalidReceipt }
        let pageInputs = try inventory.pages.enumerated().map { offset, page -> (GitHubOrganizationInventoryPage, RawAPISnapshot, Data, Data) in
            try Task.checkCancellation()
            guard page.page.values.count <= maximumObjectsPerPage,
                  page.page.payload.count <= maximumRawPageBytes,
                  page.requestKey == expectedInventoryRequestKey(page: offset + 1),
                  page.nextRequestKey == expectedInventoryNextRequestKey(page: offset + 1, totalPages: inventory.pages.count)
            else { throw PostAccountIdentityReplayReceiptRepositoryError.invalidReceipt }
            let snapshot = try rawSnapshot(accountID: identity.accountID, endpoint: endpoint(from: page.requestKey), eTag: page.page.etag, lastModified: page.page.lastModified, payload: page.page.payload, observedAt: observedAt, discriminator: "\(offset + 1):\(page.requestKey)")
            try RawAPISnapshotRepository.save(snapshot, in: database)
            return (page, snapshot, digest(page.page.payload), organizationDigest(page.page.values))
        }
        let rawSourceRevision = hex(digest(pageInputs.reduce(into: Data()) { $0.append($1.1.payload) }))
        try Task.checkCancellation()
        try database.execute(sql: """
            DELETE FROM account_organization_inventory_replay_receipts
            WHERE account_id = ? AND request_key = ?
            """, arguments: [identity.accountID.rawValue, AccountOrganizationInventoryReplayIdentity.requestKey])
        let receiptID = Self.receiptID(domain: "inventory", values: [identity.accountID.rawValue, identity.credentialRevision.rawValue, rawSourceRevision])
        try database.execute(sql: """
            INSERT INTO account_organization_inventory_replay_receipts (
                id, account_id, credential_revision, request_key, etag, last_modified,
                parser_version, source_revision, normalized_digest, page_count, organization_count,
                observed_at_ms, committed_at_ms, validated_at_ms, receipt_version
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
            """, arguments: [receiptID, identity.accountID.rawValue, identity.credentialRevision.rawValue,
                                 AccountOrganizationInventoryReplayIdentity.requestKey, first.page.etag, first.page.lastModified,
                                 Self.parserVersion, rawSourceRevision, organizationDigest(flattened), pageInputs.count,
                                 flattened.count, milliseconds(observedAt), milliseconds(observedAt), milliseconds(observedAt)])
        for (offset, input) in pageInputs.enumerated() {
            try Task.checkCancellation()
            try database.execute(sql: """
                INSERT INTO account_organization_inventory_replay_receipt_pages (
                    receipt_id, page_ordinal, raw_snapshot_id, request_key, raw_payload_digest,
                    organization_ids_digest, is_terminal
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [receiptID, offset + 1, input.1.id.rawValue, input.0.requestKey,
                                     input.2, input.3, offset + 1 == pageInputs.count])
        }
    }

    private nonisolated static func validatedInventory(
        _ identity: AccountOrganizationInventoryReplayIdentity,
        validatedAt: Date,
        in database: Database
    ) throws -> GitHubOrganizationInventory? {
        guard let receipt = try Row.fetchOne(database, sql: """
            SELECT id, etag, last_modified, parser_version, source_revision, normalized_digest,
                   page_count, organization_count, observed_at_ms
            FROM account_organization_inventory_replay_receipts
            WHERE account_id = ? AND credential_revision = ? AND request_key = ?
            """, arguments: [identity.accountID.rawValue, identity.credentialRevision.rawValue, AccountOrganizationInventoryReplayIdentity.requestKey]),
              (receipt["parser_version"] as Int?) == Self.parserVersion,
              let expectedCount: Int = receipt["organization_count"],
              let expectedPages: Int = receipt["page_count"]
        else { return nil }
        let rows = try Row.fetchAll(database, sql: """
            SELECT account_organization_inventory_replay_receipt_pages.page_ordinal,
                   account_organization_inventory_replay_receipt_pages.raw_snapshot_id,
                   account_organization_inventory_replay_receipt_pages.request_key,
                   account_organization_inventory_replay_receipt_pages.raw_payload_digest,
                   account_organization_inventory_replay_receipt_pages.organization_ids_digest,
                   account_organization_inventory_replay_receipt_pages.is_terminal,
                   raw_api_snapshots.id, raw_api_snapshots.account_id, raw_api_snapshots.github_node_id,
                   raw_api_snapshots.endpoint, raw_api_snapshots.etag, raw_api_snapshots.last_modified,
                   raw_api_snapshots.authority_organization_id, raw_api_snapshots.authority_feature,
                   raw_api_snapshots.authority_stream_id, raw_api_snapshots.authority_request_key,
                   raw_api_snapshots.authority_credential_revision, raw_api_snapshots.authority_capability_revision,
                   raw_api_snapshots.parser_version, raw_api_snapshots.observed_at_ms, raw_api_snapshots.payload
            FROM account_organization_inventory_replay_receipt_pages
            JOIN raw_api_snapshots ON raw_api_snapshots.id = account_organization_inventory_replay_receipt_pages.raw_snapshot_id
            WHERE receipt_id = ? ORDER BY page_ordinal
            """, arguments: [receipt["id"]])
        guard rows.count == expectedPages, !rows.isEmpty, rows.count <= maximumPages else { return nil }
        var pages = [GitHubOrganizationInventoryPage]()
        var all = [GitHubOrganizationDTO]()
        var rawMaterial = Data()
        var totalRawBytes = 0
        for (offset, row) in rows.enumerated() {
            try Task.checkCancellation()
            let snapshot: RawAPISnapshot
            do {
                snapshot = try RawAPISnapshotRepository.snapshot(from: row)
            } catch {
                return nil
            }
            guard (row["page_ordinal"] as Int?) == offset + 1,
                  let rawID = RawAPISnapshotID(rawValue: row["raw_snapshot_id"]),
                  snapshot.id == rawID,
                  snapshot.accountID == identity.accountID,
                  snapshot.requestIdentity == nil,
                  snapshot.parserVersion == Self.parserVersion,
                  snapshot.payload.count <= maximumRawPageBytes,
                  snapshot.endpoint == endpoint(from: row["request_key"]),
                  (row["raw_payload_digest"] as Data?) == digest(snapshot.payload),
                  let values = try? githubDecoder.decode([GitHubOrganizationDTO].self, from: snapshot.payload),
                  values.count <= maximumObjectsPerPage,
                  (row["organization_ids_digest"] as Data?) == organizationDigest(values),
                  let requestKey: String = row["request_key"],
                  requestKey == expectedInventoryRequestKey(page: offset + 1),
                  ((row["is_terminal"] as Bool?) == true) == (offset + 1 == rows.count)
            else { return nil }
            totalRawBytes += snapshot.payload.count
            guard totalRawBytes <= maximumInventoryAggregateRawBytes else { return nil }
            if offset == 0 {
                guard snapshot.eTag == (receipt["etag"] as String?),
                      snapshot.lastModified == (receipt["last_modified"] as String?),
                      milliseconds(snapshot.observedAt) == (receipt["observed_at_ms"] as Int64?)
                else { return nil }
            }
            let nextKey: String?
            if offset + 1 < rows.count { nextKey = rows[offset + 1]["request_key"] } else { nextKey = nil }
            pages.append(GitHubOrganizationInventoryPage(page: GitHubPage(values: values, payload: snapshot.payload, nextPageURL: nil, linkHeader: nil, etag: snapshot.eTag, lastModified: snapshot.lastModified, ssoHeader: nil), requestKey: requestKey, nextRequestKey: nextKey))
            all.append(contentsOf: values)
            rawMaterial.append(snapshot.payload)
        }
        guard all.count == expectedCount,
              (receipt["normalized_digest"] as Data?) == organizationDigest(all),
              (receipt["source_revision"] as String?) == hex(digest(rawMaterial))
        else { return nil }
        try validateOrganizations(all)
        try Task.checkCancellation()
        try database.execute(sql: "UPDATE account_organization_inventory_replay_receipts SET validated_at_ms = ? WHERE id = ?", arguments: [milliseconds(validatedAt), receipt["id"]])
        return GitHubOrganizationInventory(organizations: all, pages: pages, ssoHeaders: [])
    }

    private nonisolated static func validateInventoryAuthority(_ identity: AccountOrganizationInventoryReplayIdentity, in database: Database) throws {
        let revision: String? = try String.fetchOne(database, sql: "SELECT credential_revision FROM accounts WHERE id = ?", arguments: [identity.accountID.rawValue])
        guard revision == identity.credentialRevision.rawValue else { throw PostAccountIdentityReplayReceiptRepositoryError.staleAuthority }
    }

    private nonisolated static func validateMetadataAuthority(_ identity: OrganizationMetadataReplayIdentity, organization: GitHubOrganization, in database: Database) throws {
        guard identity.scope.organizationID == organization.id,
              identity.requestKey == "GET /orgs/\(organization.login)",
              identity.streamID == SyncStreamID(rawValue: "organization-metadata-\(organization.id.rawValue)")!
        else { throw PostAccountIdentityReplayReceiptRepositoryError.invalidRequest }
        let row = try Row.fetchOne(database, sql: """
            SELECT accounts.credential_revision, account_organizations.capability_revision,
                   organizations.github_organization_id, organizations.github_node_id, organizations.login,
                   sync_streams.feature
            FROM accounts JOIN account_organizations ON account_organizations.account_id = accounts.id
            JOIN organizations ON organizations.id = account_organizations.organization_id
            JOIN sync_streams ON sync_streams.id = ? AND sync_streams.account_id = accounts.id
                            AND sync_streams.organization_id = organizations.id
            WHERE accounts.id = ? AND organizations.id = ?
            """, arguments: [identity.streamID.rawValue, identity.scope.accountID.rawValue, organization.id.rawValue])
        guard let row,
              (row["credential_revision"] as String?) == identity.scope.credentialRevision.rawValue,
              (row["capability_revision"] as String?) == identity.scope.capabilityRevision.rawValue,
              (row["github_organization_id"] as String?) == String(organization.githubOrganizationID),
              (row["github_node_id"] as String?) == organization.nodeID.rawValue,
              let login: String = row["login"], login.caseInsensitiveCompare(organization.login) == .orderedSame,
              (row["feature"] as String?) == CoverageFeature.organizationMetadata.rawValue
        else { throw PostAccountIdentityReplayReceiptRepositoryError.staleAuthority }
    }

    private nonisolated static func validateMetadataScope(
        _ scope: SynchronizationScope,
        in database: Database
    ) throws {
        let row = try Row.fetchOne(database, sql: """
            SELECT accounts.credential_revision, account_organizations.capability_revision
            FROM accounts
            JOIN account_organizations ON account_organizations.account_id = accounts.id
            WHERE accounts.id = ? AND account_organizations.organization_id = ?
            """, arguments: [scope.accountID.rawValue, scope.organizationID.rawValue])
        guard let row,
              (row["credential_revision"] as String?) == scope.credentialRevision.rawValue,
              (row["capability_revision"] as String?) == scope.capabilityRevision.rawValue
        else { throw PostAccountIdentityReplayReceiptRepositoryError.staleAuthority }
    }

    private nonisolated static func validateOrganization(_ dto: GitHubOrganizationDTO, matches organization: GitHubOrganization) throws {
        guard dto.id == organization.githubOrganizationID,
              dto.nodeID == organization.nodeID.rawValue,
              dto.login.caseInsensitiveCompare(organization.login) == .orderedSame,
              !dto.nodeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !dto.login.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw PostAccountIdentityReplayReceiptRepositoryError.invalidOrganization }
    }

    private nonisolated static func validateOrganizations(_ values: [GitHubOrganizationDTO]) throws {
        var numeric = Set<UInt64>(); var nodes = Set<String>(); var logins = Set<String>()
        for value in values {
            guard value.id > 0,
                  GitHubNodeID(rawValue: value.nodeID) != nil,
                  RepositoryInventoryReplayReceiptRepository.validGitHubLogin(value.login),
                  numeric.insert(value.id).inserted,
                  nodes.insert(value.nodeID).inserted,
                  logins.insert(value.login.lowercased()).inserted
            else { throw PostAccountIdentityReplayReceiptRepositoryError.invalidReceipt }
        }
    }

    private nonisolated static func snapshot(_ id: RawAPISnapshotID, accountID: AccountID, in database: Database) throws -> RawAPISnapshot? {
        guard let row = try Row.fetchOne(database, sql: """
            SELECT id, account_id, github_node_id, endpoint, etag, last_modified,
                   authority_organization_id, authority_feature, authority_stream_id,
                   authority_request_key, authority_credential_revision,
                   authority_capability_revision, parser_version, observed_at_ms, payload
            FROM raw_api_snapshots WHERE id = ? AND account_id = ?
            """, arguments: [id.rawValue, accountID.rawValue]) else { return nil }
        return try RawAPISnapshotRepository.snapshot(from: row)
    }

    private nonisolated static func rawSnapshot(accountID: AccountID, githubNodeID: GitHubNodeID? = nil, endpoint: String, eTag: String?, lastModified: String?, payload: Data, observedAt: Date, discriminator: String, requestIdentity: ConditionalRequestIdentity? = nil) throws -> RawAPISnapshot {
        let id = RawAPISnapshotID(rawValue: "identity-replay-\(hex(digest(Data("\(accountID.rawValue)|\(discriminator)|\(milliseconds(observedAt))".utf8))))")!
        return RawAPISnapshot(id: id, accountID: accountID, githubNodeID: githubNodeID, endpoint: endpoint, eTag: eTag, lastModified: lastModified, parserVersion: Self.parserVersion, observedAt: observedAt, payload: payload, requestIdentity: requestIdentity)
    }

    private nonisolated static func endpoint(from requestKey: String?) -> String {
        guard let requestKey, requestKey.hasPrefix("GET ") else { return "/invalid" }
        return String(requestKey.dropFirst(4))
    }

    private nonisolated static func expectedInventoryRequestKey(page: Int) -> String {
        if page == 1 { return AccountOrganizationInventoryReplayIdentity.requestKey }
        return "GET /user/orgs?page=\(page)&per_page=100"
    }

    private nonisolated static func expectedInventoryNextRequestKey(page: Int, totalPages: Int) -> String? {
        page < totalPages ? expectedInventoryRequestKey(page: page + 1) : nil
    }

    private nonisolated static func validators(eTag: String?, lastModified: String?) throws -> GitHubHTTPValidators? {
        guard eTag != nil || lastModified != nil else { return nil }
        return try GitHubHTTPValidators(eTag: eTag, lastModified: lastModified)
    }

    private nonisolated static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    private nonisolated static var githubDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
    private nonisolated static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private nonisolated static func receiptID(domain: String, values: [String]) -> String { "identity-replay-\(domain)-\(hex(digest(Data(values.joined(separator: "|").utf8))))" }
    private nonisolated static func organizationDigest(_ values: [GitHubOrganizationDTO]) -> Data {
        var data = Data("triage.identity-organization-normalized.v1".utf8)
        for value in values.sorted(by: { $0.id < $1.id }) { data.append(Data("|\(value.id)|\(value.nodeID)|\(value.login.lowercased())".utf8)) }
        return digest(data)
    }
    private nonisolated static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000).rounded()) }
}

/// The only place that converts 304 transport evidence into a selected-org
/// metadata response.  Invalid/missing receipts receive one nonconditional
/// retry; a 304 is never interpreted as a synthetic empty organization.
actor PostAccountOrganizationMetadataReplayService {
    private let client: GitHubIdentityClient
    private let receipts: PostAccountIdentityReplayReceiptRepository
    private let rawSnapshots: RawAPISnapshotRepository?
    private let clock: @Sendable () -> Date

    init(
        client: GitHubIdentityClient,
        receipts: PostAccountIdentityReplayReceiptRepository,
        rawSnapshots: RawAPISnapshotRepository? = nil,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.receipts = receipts
        self.rawSnapshots = rawSnapshots
        self.clock = clock
    }

    func organization(
        _ organization: GitHubOrganization,
        scope: SynchronizationScope
    ) async throws -> GitHubResponse<GitHubOrganizationDTO> {
        let streamID = try await receipts.ensureMetadataStream(for: scope)
        try Task.checkCancellation()
        let identity = OrganizationMetadataReplayIdentity(
            scope: scope,
            streamID: streamID,
            requestKey: "GET /orgs/\(organization.login)"
        )
        let validators = try await receipts.metadataValidators(for: identity, organization: organization)
        try Task.checkCancellation()
        let result = try await client.fetchOrganization(named: organization.login, validators: validators)
        try Task.checkCancellation()
        switch result {
        case let .modified(response):
            try Task.checkCancellation()
            let observedAt = clock()
            try await receipts.replaceMetadata(response, for: identity, organization: organization, observedAt: observedAt)
            try await compactUnpinnedSnapshots(for: scope.accountID, at: observedAt)
            try Task.checkCancellation()
            return response
        case let .notModified(ssoHeader):
            if let ssoHeader {
                throw PostAccountIdentityReplayReceiptRepositoryError.ssoRequirement(ssoHeader)
            }
            if let replay = try await receipts.validatedMetadata(for: identity, organization: organization, validatedAt: clock()) {
                try Task.checkCancellation()
                return replay
            }
            let retry = try await client.fetchOrganization(named: organization.login, validators: nil)
            try Task.checkCancellation()
            switch retry {
            case let .modified(response):
                try Task.checkCancellation()
                let observedAt = clock()
                try await receipts.replaceMetadata(response, for: identity, organization: organization, observedAt: observedAt)
                try await compactUnpinnedSnapshots(for: scope.accountID, at: observedAt)
                try Task.checkCancellation()
                return response
            case let .notModified(ssoHeader?):
                throw PostAccountIdentityReplayReceiptRepositoryError.ssoRequirement(ssoHeader)
            case .notModified:
                throw PostAccountIdentityReplayReceiptRepositoryError.invalidReceipt
            }
        }
    }

    private func compactUnpinnedSnapshots(for accountID: AccountID, at date: Date) async throws {
        guard let rawSnapshots else { return }
        try Task.checkCancellation()
        _ = try await rawSnapshots.compact(
            accountID: accountID,
            retainingMostRecentPerSource: 1,
            before: date
        )
    }
}

/// Post-account membership discovery.  Callers reconcile the returned
/// inventory only after this service has proved a complete traversal; failed,
/// partial, SSO, or malformed traversals leave existing memberships untouched.
actor PostAccountOrganizationInventoryReplayService {
    private let client: GitHubIdentityClient
    private let receipts: PostAccountIdentityReplayReceiptRepository
    private let rawSnapshots: RawAPISnapshotRepository?
    private let clock: @Sendable () -> Date

    init(
        client: GitHubIdentityClient,
        receipts: PostAccountIdentityReplayReceiptRepository,
        rawSnapshots: RawAPISnapshotRepository? = nil,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.receipts = receipts
        self.rawSnapshots = rawSnapshots
        self.clock = clock
    }

    func organizations(
        accountID: AccountID,
        credentialRevision: CredentialRevision
    ) async throws -> GitHubOrganizationInventory {
        let identity = AccountOrganizationInventoryReplayIdentity(
            accountID: accountID,
            credentialRevision: credentialRevision
        )
        let validators = try await receipts.inventoryValidators(for: identity)
        try Task.checkCancellation()
        let result = try await client.fetchAllOrganizations(validators: validators)
        try Task.checkCancellation()
        switch result {
        case let .modified(inventory):
            try Task.checkCancellation()
            let observedAt = clock()
            try await receipts.replaceInventory(inventory, for: identity, observedAt: observedAt)
            try await compactUnpinnedSnapshots(for: accountID, at: observedAt)
            try Task.checkCancellation()
            return inventory
        case let .notModified(ssoHeader):
            if let ssoHeader {
                throw PostAccountIdentityReplayReceiptRepositoryError.ssoRequirement(ssoHeader)
            }
            if let replay = try await receipts.validatedInventory(for: identity, validatedAt: clock()) {
                try Task.checkCancellation()
                return replay
            }
            let retry = try await client.fetchAllOrganizations(validators: nil)
            try Task.checkCancellation()
            switch retry {
            case let .modified(inventory):
                try Task.checkCancellation()
                let observedAt = clock()
                try await receipts.replaceInventory(inventory, for: identity, observedAt: observedAt)
                try await compactUnpinnedSnapshots(for: accountID, at: observedAt)
                try Task.checkCancellation()
                return inventory
            case let .notModified(ssoHeader?):
                throw PostAccountIdentityReplayReceiptRepositoryError.ssoRequirement(ssoHeader)
            case .notModified:
                throw PostAccountIdentityReplayReceiptRepositoryError.invalidReceipt
            }
        }
    }

    private func compactUnpinnedSnapshots(for accountID: AccountID, at date: Date) async throws {
        guard let rawSnapshots else { return }
        try Task.checkCancellation()
        _ = try await rawSnapshots.compact(
            accountID: accountID,
            retainingMostRecentPerSource: 1,
            before: date
        )
    }
}
