import CryptoKit
import Foundation
import GRDB

/// `/user` has account and credential authority, but no organization scope.
/// It therefore cannot use organization-scoped conditional-request records.
struct AuthenticatedUserReplayIdentity: Equatable, Sendable {
    static let requestKey = "GET /user"

    let accountID: AccountID
    let credentialRevision: CredentialRevision
}

enum AuthenticatedUserReplayReceiptRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case staleAuthority
    case immutableIdentityMismatch
    case invalidReceipt
    case invalidValidator
    /// Preserve SSO evidence attached to a 304, including its recovery URL.
    case ssoRequirement(GitHubSSOHeader)
}

actor AuthenticatedUserReplayReceiptRepository {
    static let parserVersion = 1
    static let maximumRawPayloadBytes = 256 * 1_024

    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    func validators(for identity: AuthenticatedUserReplayIdentity) async throws -> GitHubHTTPValidators? {
        try validateAccountScope(identity)
        return try await vault.read { database in
            try Self.validateAuthority(identity, in: database)
            guard let row = try Row.fetchOne(database, sql: """
                SELECT etag, last_modified FROM authenticated_user_replay_receipts
                WHERE account_id = ? AND credential_revision = ? AND request_key = ?
                """, arguments: [
                    identity.accountID.rawValue,
                    identity.credentialRevision.rawValue,
                    AuthenticatedUserReplayIdentity.requestKey
                ]) else {
                return nil
            }
            return try? GitHubHTTPValidators(eTag: row["etag"], lastModified: row["last_modified"])
        }
    }

    func replace(
        _ response: GitHubResponse<GitHubUserDTO>,
        for identity: AuthenticatedUserReplayIdentity,
        observedAt: Date
    ) async throws {
        try Task.checkCancellation()
        try validateAccountScope(identity)
        try await vault.writeTransaction { database in
            try Task.checkCancellation()
            try Self.validateAuthority(identity, in: database)
            try Self.validate(response.value)
            try Self.validateImmutableIdentity(response.value, accountID: identity.accountID, in: database)
            guard response.ssoHeader == nil,
                  response.payload.count <= Self.maximumRawPayloadBytes,
                  let validators = try? GitHubHTTPValidators(
                      eTag: response.etag,
                      lastModified: response.lastModified
                  ),
                  validators.eTag != nil || validators.lastModified != nil
            else {
                throw AuthenticatedUserReplayReceiptRepositoryError.invalidReceipt
            }

            let payloadDigest = Self.digest(response.payload)
            let snapshot = RawAPISnapshot(
                id: Self.snapshotID(
                    identity: identity,
                    payloadDigest: payloadDigest,
                    eTag: response.etag,
                    lastModified: response.lastModified,
                    observedAt: observedAt
                ),
                accountID: identity.accountID,
                githubNodeID: nil,
                endpoint: "/user",
                eTag: response.etag,
                lastModified: response.lastModified,
                parserVersion: Self.parserVersion,
                observedAt: observedAt,
                payload: response.payload
            )
            try RawAPISnapshotRepository.save(snapshot, in: database)
            try Task.checkCancellation()
            try database.execute(sql: """
                DELETE FROM authenticated_user_replay_receipts
                WHERE account_id = ? AND request_key = ?
                """, arguments: [identity.accountID.rawValue, AuthenticatedUserReplayIdentity.requestKey])
            try database.execute(sql: """
                INSERT INTO authenticated_user_replay_receipts (
                    id, account_id, credential_revision, request_key, etag, last_modified,
                    raw_snapshot_id, raw_payload_digest, normalized_digest, parser_version,
                    source_revision, observed_at_ms, committed_at_ms, validated_at_ms,
                    receipt_version
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                """, arguments: [
                    Self.receiptID(identity: identity, payloadDigest: payloadDigest),
                    identity.accountID.rawValue, identity.credentialRevision.rawValue,
                    AuthenticatedUserReplayIdentity.requestKey, response.etag, response.lastModified,
                    snapshot.id.rawValue, payloadDigest, Self.userDigest(response.value),
                    Self.parserVersion, Self.hex(payloadDigest), Self.milliseconds(observedAt),
                    Self.milliseconds(observedAt), Self.milliseconds(observedAt)
                ])
        }
    }

    /// A 304 is usable only when its encrypted raw evidence, normalized user
    /// and exact account/credential authority all still validate.
    func validatedUser(
        for identity: AuthenticatedUserReplayIdentity,
        validatedAt: Date
    ) async throws -> GitHubResponse<GitHubUserDTO>? {
        try Task.checkCancellation()
        try validateAccountScope(identity)
        return try await vault.writeTransaction { database in
            try Task.checkCancellation()
            try Self.validateAuthority(identity, in: database)
            do {
                guard let row = try Row.fetchOne(database, sql: """
                    SELECT id, etag, last_modified, raw_snapshot_id, raw_payload_digest,
                           normalized_digest, parser_version, source_revision,
                           observed_at_ms, committed_at_ms, validated_at_ms
                    FROM authenticated_user_replay_receipts
                    WHERE account_id = ? AND credential_revision = ? AND request_key = ?
                    """, arguments: [
                        identity.accountID.rawValue, identity.credentialRevision.rawValue,
                        AuthenticatedUserReplayIdentity.requestKey
                    ]),
                    let receiptID: String = row["id"],
                    let snapshotID = RawAPISnapshotID(rawValue: row["raw_snapshot_id"]),
                    let snapshot = try Self.snapshot(snapshotID, accountID: identity.accountID, in: database),
                    let rawPayloadDigest: Data = row["raw_payload_digest"],
                    rawPayloadDigest.count == SHA256.Digest.byteCount,
                    receiptID == Self.receiptID(
                        identity: identity,
                        payloadDigest: rawPayloadDigest
                    ),
                    (row["parser_version"] as Int?) == Self.parserVersion,
                    snapshot.accountID == identity.accountID,
                    snapshot.githubNodeID == nil,
                    snapshot.requestIdentity == nil,
                    snapshot.endpoint == "/user",
                    snapshot.parserVersion == Self.parserVersion,
                    snapshot.payload.count <= Self.maximumRawPayloadBytes,
                    snapshot.eTag == (row["etag"] as String?),
                    snapshot.lastModified == (row["last_modified"] as String?),
                    rawPayloadDigest == Self.digest(snapshot.payload),
                    (row["source_revision"] as String?) == Self.hex(Self.digest(snapshot.payload)),
                    let observedAtMilliseconds: Int64 = row["observed_at_ms"],
                    let committedAtMilliseconds: Int64 = row["committed_at_ms"],
                    let lastValidatedAtMilliseconds: Int64 = row["validated_at_ms"],
                    observedAtMilliseconds >= 0,
                    committedAtMilliseconds >= observedAtMilliseconds,
                    lastValidatedAtMilliseconds >= committedAtMilliseconds,
                    Self.milliseconds(validatedAt) >= committedAtMilliseconds,
                    Self.milliseconds(validatedAt) >= lastValidatedAtMilliseconds,
                    let user = try? Self.decoder.decode(GitHubUserDTO.self, from: snapshot.payload),
                    (row["normalized_digest"] as Data?) == Self.userDigest(user),
                    Self.matchesImmutableIdentity(user, accountID: identity.accountID, in: database)
                else {
                    return nil
                }
                try Self.validate(user)
                try Task.checkCancellation()
                try database.execute(sql: """
                    UPDATE authenticated_user_replay_receipts SET validated_at_ms = ?
                    WHERE id = ? AND account_id = ? AND credential_revision = ?
                    """, arguments: [
                        Self.milliseconds(validatedAt), row["id"], identity.accountID.rawValue,
                        identity.credentialRevision.rawValue
                    ])
                return GitHubResponse(
                    value: user,
                    payload: snapshot.payload,
                    etag: snapshot.eTag,
                    lastModified: snapshot.lastModified,
                    ssoHeader: nil,
                    source: .replay(snapshot.id)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return nil
            }
        }
    }

    private func validateAccountScope(_ identity: AuthenticatedUserReplayIdentity) throws {
        guard identity.accountID == vault.accountID else {
            throw AuthenticatedUserReplayReceiptRepositoryError.accountScopeMismatch
        }
    }

    private nonisolated static func validateAuthority(
        _ identity: AuthenticatedUserReplayIdentity,
        in database: Database
    ) throws {
        let revision: String? = try String.fetchOne(
            database,
            sql: "SELECT credential_revision FROM accounts WHERE id = ? AND disabled_at_ms IS NULL",
            arguments: [identity.accountID.rawValue]
        )
        guard revision == identity.credentialRevision.rawValue else {
            throw AuthenticatedUserReplayReceiptRepositoryError.staleAuthority
        }
    }

    private nonisolated static func validate(_ user: GitHubUserDTO) throws {
        guard user.id > 0,
              GitHubNodeID(rawValue: user.nodeID) != nil,
              RepositoryInventoryReplayReceiptRepository.validGitHubLogin(user.login)
        else {
            throw AuthenticatedUserReplayReceiptRepositoryError.invalidReceipt
        }
    }

    private nonisolated static func validateImmutableIdentity(
        _ user: GitHubUserDTO,
        accountID: AccountID,
        in database: Database
    ) throws {
        guard matchesImmutableIdentity(user, accountID: accountID, in: database) else {
            throw AuthenticatedUserReplayReceiptRepositoryError.immutableIdentityMismatch
        }
    }

    private nonisolated static func matchesImmutableIdentity(
        _ user: GitHubUserDTO,
        accountID: AccountID,
        in database: Database
    ) -> Bool {
        guard let row = try? Row.fetchOne(database, sql: """
            SELECT github_user_id, github_node_id FROM accounts
            WHERE id = ? AND disabled_at_ms IS NULL
            """, arguments: [accountID.rawValue]),
            let githubUserID: String = row["github_user_id"],
            let githubNodeID: String = row["github_node_id"]
        else {
            return false
        }
        return githubUserID == String(user.id) && githubNodeID == user.nodeID
    }

    private nonisolated static func snapshot(
        _ id: RawAPISnapshotID,
        accountID: AccountID,
        in database: Database
    ) throws -> RawAPISnapshot? {
        guard let row = try Row.fetchOne(database, sql: """
            SELECT id, account_id, github_node_id, endpoint, etag, last_modified,
                   authority_organization_id, authority_feature, authority_stream_id,
                   authority_request_key, authority_credential_revision,
                   authority_capability_revision, parser_version, observed_at_ms, payload
            FROM raw_api_snapshots WHERE id = ? AND account_id = ?
            """, arguments: [id.rawValue, accountID.rawValue]) else {
            return nil
        }
        return try RawAPISnapshotRepository.snapshot(from: row)
    }

    private nonisolated static func userDigest(_ user: GitHubUserDTO) -> Data {
        let material = [
            String(user.id), user.nodeID, user.login.lowercased(), user.name ?? "",
            user.avatarURL?.absoluteString ?? ""
        ].joined(separator: "\u{1F}")
        return digest(Data(material.utf8))
    }

    private nonisolated static var decoder: JSONDecoder {
        JSONDecoder()
    }

    private nonisolated static func snapshotID(
        identity: AuthenticatedUserReplayIdentity,
        payloadDigest: Data,
        eTag: String?,
        lastModified: String?,
        observedAt: Date
    ) -> RawAPISnapshotID {
        let authority = [
            identity.accountID.rawValue,
            identity.credentialRevision.rawValue,
            hex(payloadDigest),
            eTag ?? "",
            lastModified ?? "",
            String(milliseconds(observedAt))
        ].joined(separator: "|")
        return RawAPISnapshotID(
            rawValue: "authenticated-user-replay-\(hex(digest(Data(authority.utf8))))"
        )!
    }

    private nonisolated static func receiptID(
        identity: AuthenticatedUserReplayIdentity,
        payloadDigest: Data
    ) -> String {
        "authenticated-user-receipt-\(hex(digest(Data("\(identity.accountID.rawValue)|\(identity.credentialRevision.rawValue)|\(hex(payloadDigest))".utf8))))"
    }

    private nonisolated static func digest(_ value: Data) -> Data {
        Data(SHA256.hash(data: value))
    }

    private nonisolated static func hex(_ value: Data) -> String {
        value.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

/// Converts transport 304 evidence into identity only through the exact
/// account/credential-bound receipt. Invalid/missing receipt evidence gets one
/// unconditional retry and never becomes an empty or stale identity.
actor PostAccountAuthenticatedUserReplayService {
    private let client: GitHubIdentityClient
    private let receipts: AuthenticatedUserReplayReceiptRepository
    private let clock: @Sendable () -> Date

    init(
        client: GitHubIdentityClient,
        receipts: AuthenticatedUserReplayReceiptRepository,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.receipts = receipts
        self.clock = clock
    }

    func user(
        accountID: AccountID,
        credentialRevision: CredentialRevision
    ) async throws -> GitHubUserDTO {
        let identity = AuthenticatedUserReplayIdentity(
            accountID: accountID,
            credentialRevision: credentialRevision
        )
        let validators = try await receipts.validators(for: identity)
        try Task.checkCancellation()
        let result = try await client.fetchAuthenticatedUser(validators: validators)
        switch result {
        case let .modified(response):
            try await receipts.replace(response, for: identity, observedAt: clock())
            return response.value
        case let .notModified(ssoHeader):
            if let ssoHeader {
                throw AuthenticatedUserReplayReceiptRepositoryError.ssoRequirement(ssoHeader)
            }
            if let replay = try await receipts.validatedUser(for: identity, validatedAt: clock()) {
                return replay.value
            }
            return try await unconditionalUser(identity: identity)
        }
    }

    private func unconditionalUser(
        identity: AuthenticatedUserReplayIdentity
    ) async throws -> GitHubUserDTO {
        try Task.checkCancellation()
        let retry = try await client.fetchAuthenticatedUser(validators: nil)
        switch retry {
        case let .modified(response):
            try await receipts.replace(response, for: identity, observedAt: clock())
            return response.value
        case let .notModified(ssoHeader?):
            throw AuthenticatedUserReplayReceiptRepositoryError.ssoRequirement(ssoHeader)
        case .notModified:
            throw AuthenticatedUserReplayReceiptRepositoryError.invalidReceipt
        }
    }
}
