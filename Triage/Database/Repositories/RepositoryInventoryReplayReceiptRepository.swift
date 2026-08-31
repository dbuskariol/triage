import CryptoKit
import Foundation
import GRDB

enum RepositoryInventoryReplayReceiptRepositoryError: Error, Equatable, Sendable {
    case accountScopeMismatch
    case organizationScopeMismatch
    case authorityScopeMismatch
    case streamScopeMismatch
    case invalidRequestKey
    case invalidValidator
    case invalidPageInventory
    case invalidPaginationTopology
    case invalidRawSnapshot
    case normalizationFailure
    case invalidNormalizedState
    case incompleteCoverage
    case staleObservation
    case conflictingObservation
    case staleValidation
    case invalidPersistedData
}

struct RepositoryInventoryReplayReceiptPage: Equatable, Sendable {
    let pageIndex: Int
    let rawSnapshotID: RawAPISnapshotID
    let endpoint: String
    let linkHeader: String?
    let nextEndpoint: String?
}

struct RepositoryInventoryReplayReceiptInput: Sendable {
    let identity: ConditionalRequestIdentity
    let validator: ConditionalRequestValidator?
    let rawSourceRevision: String
    let pages: [RepositoryInventoryReplayReceiptPage]
    let normalizedCommittedAt: Date
}

struct RepositoryInventoryReplayReceipt: Equatable, Sendable {
    let identity: ConditionalRequestIdentity
    let validator: ConditionalRequestValidator
    let rawSourceRevision: String
    let rawObservedAt: Date
    let normalizedCommittedAt: Date
    let lastValidatedAt: Date
    let parserVersion: Int
    let pageCount: Int
    let normalizedRepositoryCount: Int
    let normalizedDigest: Data
}

struct RepositoryInventoryNotModifiedReplayResult: Equatable, Sendable {
    let summaries: [RepositorySummary]
    let coverage: CoverageRecord
    let receipt: RepositoryInventoryReplayReceipt
}

actor RepositoryInventoryReplayReceiptRepository {
    static let parserVersion = 1
    static let maximumPages = 100
    static let maximumObjectsPerPage = 100
    static let maximumRepositoryCount = maximumPages * maximumObjectsPerPage
    static let maximumRawPageBytes = 2 * 1_024 * 1_024

    private let vault: AccountVault

    init(vault: AccountVault) {
        self.vault = vault
    }

    /// Shared grammar for GitHub owner and organization logins accepted by
    /// the repository-backed replay receipts.
    static func validGitHubLogin(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 39 && value.unicodeScalars.allSatisfy {
            $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "-")
        }
    }

    func replaceModifiedResponseReceipt(
        _ input: RepositoryInventoryReplayReceiptInput,
        organization: GitHubOrganization
    ) async throws {
        try await vault.writeTransaction { database in
            try Self.replaceModifiedResponseReceipt(
                input,
                organization: organization,
                expectedAccountID: vault.accountID,
                in: database
            )
        }
    }

    func validatedNotModifiedReceipt(
        for validator: ConditionalRequestValidator,
        organization: GitHubOrganization,
        validatedAt: Date
    ) async throws -> RepositoryInventoryNotModifiedReplayResult? {
        try await vault.writeTransaction { database in
            try Self.validatedNotModifiedReceipt(
                for: validator,
                organization: organization,
                validatedAt: validatedAt,
                expectedAccountID: vault.accountID,
                in: database
            )
        }
    }

    func retire(
        for identity: ConditionalRequestIdentity,
        organization: GitHubOrganization
    ) async throws {
        try await vault.writeTransaction { database in
            try Self.retire(
                for: identity,
                organization: organization,
                expectedAccountID: vault.accountID,
                in: database
            )
        }
    }

    nonisolated static func replaceModifiedResponseReceipt(
        _ input: RepositoryInventoryReplayReceiptInput,
        organization: GitHubOrganization,
        expectedAccountID: AccountID,
        in database: Database
    ) throws {
        try Task.checkCancellation()
        try validateAuthority(
            input.identity,
            organization: organization,
            expectedAccountID: expectedAccountID,
            in: database
        )
        if let validator = input.validator {
            guard validator.identity == input.identity,
                  validValidator(validator)
            else {
                throw RepositoryInventoryReplayReceiptRepositoryError.invalidValidator
            }
        }
        guard validSourceRevision(input.rawSourceRevision),
              let normalizedCommittedAtMilliseconds = milliseconds(input.normalizedCommittedAt)
        else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidPageInventory
        }

        let validatedPages = try validatePages(
            input.pages,
            identity: input.identity,
            organization: organization,
            validator: input.validator,
            in: database
        )
        guard normalizedCommittedAtMilliseconds >= validatedPages.rawObservedAtMilliseconds else {
            throw RepositoryInventoryReplayReceiptRepositoryError.staleObservation
        }
        let computedRawSourceRevision = rawSourceRevision(for: validatedPages.pages)
        guard computedRawSourceRevision == input.rawSourceRevision else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidPageInventory
        }

        let normalizedState = try normalizedState(
            identity: input.identity,
            organization: organization,
            in: database
        )
        guard normalizedState.availableRepositoryIDs == validatedPages.repositoryIDs else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidNormalizedState
        }
        let coverage = try validatedCoverage(
            identity: input.identity,
            organization: organization,
            normalizedState: normalizedState,
            rawObservedAtMilliseconds: validatedPages.rawObservedAtMilliseconds,
            noLaterThanMilliseconds: normalizedCommittedAtMilliseconds,
            in: database
        )
        guard coverage.status == .complete else {
            throw RepositoryInventoryReplayReceiptRepositoryError.incompleteCoverage
        }

        let existing = try existingReceiptAnchor(for: input.identity, in: database)
        if let existing {
            guard validatedPages.rawObservedAtMilliseconds >= existing.rawObservedAtMilliseconds else {
                throw RepositoryInventoryReplayReceiptRepositoryError.staleObservation
            }
            if validatedPages.rawObservedAtMilliseconds == existing.rawObservedAtMilliseconds,
               existing.rawSourceRevision != input.rawSourceRevision {
                throw RepositoryInventoryReplayReceiptRepositoryError.conflictingObservation
            }
        }
        try Task.checkCancellation()

        // A successful validatorless 200 retires the prior conditional authority,
        // but only after the replacement normalized state and raw pages validate.
        guard let validator = input.validator else {
            try deleteLogicalReceipt(for: input.identity, in: database)
            return
        }
        guard let validatorObservedAtMilliseconds = milliseconds(validator.observedAt),
              validatorObservedAtMilliseconds == validatedPages.rawObservedAtMilliseconds
        else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidValidator
        }
        let receiptID = replayReceiptID(for: input.identity)
        try deleteLogicalReceipt(for: input.identity, in: database)
        try database.execute(
            sql: """
                INSERT INTO repository_inventory_replay_receipts (
                    id, account_id, organization_id, feature, stream_id, request_key,
                    credential_revision, capability_revision, raw_source_revision,
                    etag, last_modified, raw_observed_at_ms, normalized_committed_at_ms,
                    last_validated_at_ms, parser_version, page_count,
                    normalized_repository_count, normalized_digest
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                receiptID,
                input.identity.scope.accountID.rawValue,
                input.identity.scope.organizationID.rawValue,
                CoverageFeature.repositories.rawValue,
                input.identity.streamID.rawValue,
                input.identity.requestKey,
                input.identity.scope.credentialRevision.rawValue,
                input.identity.scope.capabilityRevision.rawValue,
                input.rawSourceRevision,
                validator.eTag,
                validator.lastModified,
                validatedPages.rawObservedAtMilliseconds,
                normalizedCommittedAtMilliseconds,
                normalizedCommittedAtMilliseconds,
                parserVersion,
                validatedPages.pages.count,
                normalizedState.summaries.count,
                normalizedState.digest
            ]
        )
        for page in validatedPages.pages {
            try Task.checkCancellation()
            try database.execute(
                sql: """
                    INSERT INTO repository_inventory_replay_receipt_pages (
                        receipt_id, page_index, endpoint, request_key, link_header,
                        next_endpoint, raw_snapshot_id, object_count,
                        raw_payload_digest, repository_id_digest
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    receiptID,
                    page.input.pageIndex,
                    page.input.endpoint,
                    "GET \(page.input.endpoint)",
                    page.input.linkHeader,
                    page.input.nextEndpoint,
                    page.input.rawSnapshotID.rawValue,
                    page.repositoryIDs.count,
                    page.rawPayloadDigest,
                    page.repositoryIDDigest
                ]
            )
        }
    }

    nonisolated static func validatedNotModifiedReceipt(
        for validator: ConditionalRequestValidator,
        organization: GitHubOrganization,
        validatedAt: Date,
        expectedAccountID: AccountID,
        in database: Database
    ) throws -> RepositoryInventoryNotModifiedReplayResult? {
        try Task.checkCancellation()
        try validateAuthority(
            validator.identity,
            organization: organization,
            expectedAccountID: expectedAccountID,
            in: database
        )
        guard validValidator(validator),
              let validatedAtMilliseconds = milliseconds(validatedAt)
        else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidValidator
        }
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT id, account_id, organization_id, feature, stream_id, request_key,
                       credential_revision, capability_revision, raw_source_revision,
                       etag, last_modified, raw_observed_at_ms, normalized_committed_at_ms,
                       last_validated_at_ms, parser_version, page_count,
                       normalized_repository_count, normalized_digest
                FROM repository_inventory_replay_receipts
                WHERE account_id = ? AND organization_id = ? AND feature = ?
                  AND stream_id = ? AND request_key = ?
                """,
            arguments: logicalArguments(for: validator.identity)
        ) else {
            return nil
        }
        guard (row["credential_revision"] as String?)
                == validator.identity.scope.credentialRevision.rawValue,
              (row["capability_revision"] as String?)
                == validator.identity.scope.capabilityRevision.rawValue
        else {
            return nil
        }
        let stored = try receipt(from: row, expectedIdentity: validator.identity)
        guard stored.validator.eTag == validator.eTag,
              stored.validator.lastModified == validator.lastModified
        else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidValidator
        }
        guard let rawObservedAtMilliseconds = milliseconds(stored.rawObservedAt),
              let normalizedCommittedAtMilliseconds = milliseconds(stored.normalizedCommittedAt),
              let lastValidatedAtMilliseconds = milliseconds(stored.lastValidatedAt),
              validatedAtMilliseconds >= normalizedCommittedAtMilliseconds,
              validatedAtMilliseconds >= lastValidatedAtMilliseconds
        else {
            throw RepositoryInventoryReplayReceiptRepositoryError.staleValidation
        }

        guard let currentValidator = try ConditionalRequestCacheRepository.validator(
            for: validator.identity,
            expectedAccountID: expectedAccountID,
            in: database
        ), currentValidator.identity == validator.identity,
           currentValidator.eTag == validator.eTag,
           currentValidator.lastModified == validator.lastModified
        else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidValidator
        }
        let persistedPages = try persistedPages(
            receiptID: replayReceiptID(for: validator.identity),
            expectedCount: stored.pageCount,
            in: database
        )
        let validatedPages = try validatePages(
            persistedPages,
            identity: validator.identity,
            organization: organization,
            validator: ConditionalRequestValidator(
                identity: validator.identity,
                eTag: validator.eTag,
                lastModified: validator.lastModified,
                observedAt: stored.rawObservedAt
            ),
            in: database
        )
        guard validatedPages.rawObservedAtMilliseconds == rawObservedAtMilliseconds,
              rawSourceRevision(for: validatedPages.pages) == stored.rawSourceRevision
        else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidPersistedData
        }
        for (offset, page) in validatedPages.pages.enumerated() {
            guard page.rawPayloadDigest == persistedPages[offset].expectedRawPayloadDigest,
                  page.repositoryIDDigest == persistedPages[offset].expectedRepositoryIDDigest
            else {
                throw RepositoryInventoryReplayReceiptRepositoryError.invalidPersistedData
            }
        }

        let normalizedState = try normalizedState(
            identity: validator.identity,
            organization: organization,
            in: database
        )
        guard normalizedState.availableRepositoryIDs == validatedPages.repositoryIDs,
              normalizedState.summaries.count == stored.normalizedRepositoryCount,
              normalizedState.digest == stored.normalizedDigest
        else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidNormalizedState
        }
        _ = try validatedCoverage(
            identity: validator.identity,
            organization: organization,
            normalizedState: normalizedState,
            rawObservedAtMilliseconds: rawObservedAtMilliseconds,
            noLaterThanMilliseconds: validatedAtMilliseconds,
            in: database
        )
        let canonicalValidatedAt = date(from: validatedAtMilliseconds)
        let refreshedCoverage = replayCoverageRecord(
            repositoryID: nil,
            identity: validator.identity,
            validatedAt: canonicalValidatedAt
        )
        try CoverageRepository.save(
            refreshedCoverage,
            attemptedAt: canonicalValidatedAt,
            expectedAccountID: expectedAccountID,
            in: database
        )
        for repositoryID in normalizedState.availableRepositoryIDs.sorted(by: {
            $0.rawValue < $1.rawValue
        }) {
            try Task.checkCancellation()
            try CoverageRepository.save(
                replayCoverageRecord(
                    repositoryID: repositoryID,
                    identity: validator.identity,
                    validatedAt: canonicalValidatedAt
                ),
                attemptedAt: canonicalValidatedAt,
                expectedAccountID: expectedAccountID,
                in: database
            )
        }
        try Task.checkCancellation()
        try database.execute(
            sql: """
                UPDATE repository_inventory_replay_receipts
                SET last_validated_at_ms = ?
                WHERE id = ? AND last_validated_at_ms = ?
                """,
            arguments: [
                validatedAtMilliseconds,
                replayReceiptID(for: validator.identity),
                lastValidatedAtMilliseconds
            ]
        )
        guard database.changesCount == 1 else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidPersistedData
        }
        return RepositoryInventoryNotModifiedReplayResult(
            summaries: normalizedState.summaries,
            coverage: refreshedCoverage,
            receipt: RepositoryInventoryReplayReceipt(
                identity: stored.identity,
                validator: stored.validator,
                rawSourceRevision: stored.rawSourceRevision,
                rawObservedAt: stored.rawObservedAt,
                normalizedCommittedAt: stored.normalizedCommittedAt,
                lastValidatedAt: canonicalValidatedAt,
                parserVersion: stored.parserVersion,
                pageCount: stored.pageCount,
                normalizedRepositoryCount: stored.normalizedRepositoryCount,
                normalizedDigest: stored.normalizedDigest
            )
        )
    }

    nonisolated static func retire(
        for identity: ConditionalRequestIdentity,
        organization: GitHubOrganization,
        expectedAccountID: AccountID,
        in database: Database
    ) throws {
        try validateAuthority(
            identity,
            organization: organization,
            expectedAccountID: expectedAccountID,
            in: database
        )
        try deleteLogicalReceipt(for: identity, in: database)
    }
}

private extension RepositoryInventoryReplayReceiptRepository {
    struct PersistedPageInput: Sendable {
        let page: RepositoryInventoryReplayReceiptPage
        let expectedObjectCount: Int?
        let expectedRawPayloadDigest: Data?
        let expectedRepositoryIDDigest: Data?
    }

    struct ValidatedPage: Sendable {
        let input: RepositoryInventoryReplayReceiptPage
        let snapshot: RawAPISnapshot
        let repositoryIDs: [RepositoryID]
        let numericRepositoryIDs: [UInt64]
        let rawPayloadDigest: Data
        let repositoryIDDigest: Data
    }

    struct ValidatedPages: Sendable {
        let pages: [ValidatedPage]
        let repositoryIDs: Set<RepositoryID>
        let rawObservedAtMilliseconds: Int64
    }

    struct NormalizedState: Sendable {
        let summaries: [RepositorySummary]
        let availableRepositoryIDs: Set<RepositoryID>
        let digest: Data
    }

    struct ExistingReceiptAnchor: Sendable {
        let rawSourceRevision: String
        let rawObservedAtMilliseconds: Int64
    }

    static func validateAuthority(
        _ identity: ConditionalRequestIdentity,
        organization: GitHubOrganization,
        expectedAccountID: AccountID,
        in database: Database
    ) throws {
        guard identity.scope.accountID == expectedAccountID else {
            throw RepositoryInventoryReplayReceiptRepositoryError.accountScopeMismatch
        }
        guard identity.scope.organizationID == organization.id,
              identity.feature == .repositories,
              identity.streamID == repositoryStreamID(for: organization.id)
        else {
            throw RepositoryInventoryReplayReceiptRepositoryError.authorityScopeMismatch
        }
        let rootEndpoint = repositoryEndpoint(organizationLogin: organization.login, page: 1)
        guard identity.requestKey == "GET \(rootEndpoint)" else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidRequestKey
        }
        let authority = try Row.fetchOne(
            database,
            sql: """
                SELECT organizations.github_organization_id, organizations.login,
                       accounts.credential_revision,
                       account_organizations.capability_revision
                FROM account_organizations
                JOIN accounts ON accounts.id = account_organizations.account_id
                JOIN organizations ON organizations.id = account_organizations.organization_id
                WHERE account_organizations.account_id = ?
                  AND account_organizations.organization_id = ?
                """,
            arguments: [expectedAccountID.rawValue, organization.id.rawValue]
        )
        guard let authority,
              (authority["github_organization_id"] as String?)
                == String(organization.githubOrganizationID),
              let persistedLogin: String = authority["login"],
              persistedLogin.caseInsensitiveCompare(organization.login) == .orderedSame,
              (authority["credential_revision"] as String?)
                == identity.scope.credentialRevision.rawValue,
              (authority["capability_revision"] as String?)
                == identity.scope.capabilityRevision.rawValue
        else {
            throw RepositoryInventoryReplayReceiptRepositoryError.organizationScopeMismatch
        }
        let streamCount = try Int.fetchOne(
            database,
            sql: """
                SELECT COUNT(*) FROM sync_streams
                WHERE id = ? AND account_id = ? AND organization_id = ? AND feature = ?
                """,
            arguments: [
                identity.streamID.rawValue,
                expectedAccountID.rawValue,
                organization.id.rawValue,
                CoverageFeature.repositories.rawValue
            ]
        ) ?? 0
        guard streamCount == 1 else {
            throw RepositoryInventoryReplayReceiptRepositoryError.streamScopeMismatch
        }
    }

    static func validatePages(
        _ pages: [RepositoryInventoryReplayReceiptPage],
        identity: ConditionalRequestIdentity,
        organization: GitHubOrganization,
        validator: ConditionalRequestValidator?,
        in database: Database
    ) throws -> ValidatedPages {
        try validatePages(
            pages.map {
                PersistedPageInput(
                    page: $0,
                    expectedObjectCount: nil,
                    expectedRawPayloadDigest: nil,
                    expectedRepositoryIDDigest: nil
                )
            },
            identity: identity,
            organization: organization,
            validator: validator,
            in: database
        )
    }

    static func validatePages(
        _ persistedPages: [PersistedPageInput],
        identity: ConditionalRequestIdentity,
        organization: GitHubOrganization,
        validator: ConditionalRequestValidator?,
        in database: Database
    ) throws -> ValidatedPages {
        guard !persistedPages.isEmpty, persistedPages.count <= maximumPages else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidPageInventory
        }
        let pages = persistedPages.map(\.page)
        guard Set(pages.map(\.rawSnapshotID)).count == pages.count,
              Set(pages.map(\.endpoint)).count == pages.count,
              pages.enumerated().allSatisfy({ $0.element.pageIndex == $0.offset + 1 })
        else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidPageInventory
        }
        var validated = [ValidatedPage]()
        var repositoryIDs = Set<RepositoryID>()
        var numericRepositoryIDs = Set<UInt64>()
        var rawObservedAtMilliseconds: Int64?
        for (offset, persistedPage) in persistedPages.enumerated() {
            try Task.checkCancellation()
            let input = persistedPage.page
            let expectedPage = offset + 1
            try validateTopology(
                input,
                followingPage: pages.indices.contains(offset + 1) ? pages[offset + 1] : nil,
                organizationLogin: organization.login
            )
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT id, account_id, github_node_id, endpoint, etag, last_modified,
                           authority_organization_id, authority_feature, authority_stream_id,
                           authority_request_key, authority_credential_revision,
                           authority_capability_revision, parser_version, observed_at_ms, payload
                    FROM raw_api_snapshots WHERE id = ?
                    """,
                arguments: [input.rawSnapshotID.rawValue]
            ) else {
                throw RepositoryInventoryReplayReceiptRepositoryError.invalidRawSnapshot
            }
            let snapshot: RawAPISnapshot
            do {
                snapshot = try RawAPISnapshotRepository.snapshot(from: row)
            } catch {
                throw RepositoryInventoryReplayReceiptRepositoryError.invalidRawSnapshot
            }
            let pageIdentity = ConditionalRequestIdentity(
                scope: identity.scope,
                feature: .repositories,
                streamID: identity.streamID,
                requestKey: "GET \(input.endpoint)"
            )
            guard snapshot.id == input.rawSnapshotID,
                  snapshot.accountID == identity.scope.accountID,
                  snapshot.githubNodeID == nil,
                  snapshot.endpoint == input.endpoint,
                  snapshot.parserVersion == parserVersion,
                  snapshot.payload.count <= maximumRawPageBytes,
                  snapshot.requestIdentity == pageIdentity,
                  let observedAtMilliseconds = milliseconds(snapshot.observedAt),
                  expectedSnapshotID(snapshot, identity: identity) == snapshot.id
            else {
                throw RepositoryInventoryReplayReceiptRepositoryError.invalidRawSnapshot
            }
            if let existingRawObservedAtMilliseconds = rawObservedAtMilliseconds {
                guard observedAtMilliseconds == existingRawObservedAtMilliseconds else {
                    throw RepositoryInventoryReplayReceiptRepositoryError.invalidRawSnapshot
                }
            } else {
                rawObservedAtMilliseconds = observedAtMilliseconds
            }
            if expectedPage == 1 {
                if let validator {
                    guard snapshot.eTag == validator.eTag,
                          snapshot.lastModified == validator.lastModified
                    else {
                        throw RepositoryInventoryReplayReceiptRepositoryError.invalidValidator
                    }
                } else {
                    guard snapshot.eTag == nil, snapshot.lastModified == nil else {
                        throw RepositoryInventoryReplayReceiptRepositoryError.invalidValidator
                    }
                }
            }
            let failureCount = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM normalization_failures WHERE raw_snapshot_id = ?",
                arguments: [snapshot.id.rawValue]
            ) ?? 0
            guard failureCount == 0 else {
                throw RepositoryInventoryReplayReceiptRepositoryError.normalizationFailure
            }
            let decoded = try decodeRepositories(snapshot.payload, organization: organization)
            guard decoded.count <= maximumObjectsPerPage else {
                throw RepositoryInventoryReplayReceiptRepositoryError.invalidPageInventory
            }
            if let expectedObjectCount = persistedPage.expectedObjectCount,
               expectedObjectCount != decoded.count {
                throw RepositoryInventoryReplayReceiptRepositoryError.invalidPersistedData
            }
            let decodedRepositoryIDs = try decoded.map { repository -> RepositoryID in
                guard let repositoryID = RepositoryID(rawValue: repository.nodeID) else {
                    throw RepositoryInventoryReplayReceiptRepositoryError.invalidPageInventory
                }
                guard repositoryIDs.insert(repositoryID).inserted,
                      numericRepositoryIDs.insert(repository.id).inserted
                else {
                    throw RepositoryInventoryReplayReceiptRepositoryError.invalidPageInventory
                }
                return repositoryID
            }
            let payloadDigest = digest(
                domain: "triage.repository-inventory.raw-page.v1",
                components: [snapshot.payload]
            )
            let repositoryDigest = repositoryIDDigest(decoded)
            if let expected = persistedPage.expectedRawPayloadDigest,
               expected != payloadDigest {
                throw RepositoryInventoryReplayReceiptRepositoryError.invalidPersistedData
            }
            if let expected = persistedPage.expectedRepositoryIDDigest,
               expected != repositoryDigest {
                throw RepositoryInventoryReplayReceiptRepositoryError.invalidPersistedData
            }
            validated.append(
                ValidatedPage(
                    input: input,
                    snapshot: snapshot,
                    repositoryIDs: decodedRepositoryIDs,
                    numericRepositoryIDs: decoded.map(\.id),
                    rawPayloadDigest: payloadDigest,
                    repositoryIDDigest: repositoryDigest
                )
            )
        }
        guard repositoryIDs.count <= maximumRepositoryCount,
              let rawObservedAtMilliseconds
        else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidPageInventory
        }
        return ValidatedPages(
            pages: validated,
            repositoryIDs: repositoryIDs,
            rawObservedAtMilliseconds: rawObservedAtMilliseconds
        )
    }

    static func validateTopology(
        _ page: RepositoryInventoryReplayReceiptPage,
        followingPage: RepositoryInventoryReplayReceiptPage?,
        organizationLogin: String
    ) throws {
        guard page.endpoint.count <= 2_048,
              page.linkHeader.map({ !$0.isEmpty && $0.count <= 8_192 }) ?? true,
              page.nextEndpoint.map({ !$0.isEmpty && $0.count <= 2_048 }) ?? true
        else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidPaginationTopology
        }
        guard isRepositoryEndpoint(
            page.endpoint,
            organizationLogin: organizationLogin,
            expectedPage: page.pageIndex
        ) else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidPaginationTopology
        }
        let parsedLink: GitHubLinkHeader?
        if let linkHeader = page.linkHeader {
            guard let parsed = GitHubLinkHeader(linkHeader), parsed.isWellFormed else {
                throw RepositoryInventoryReplayReceiptRepositoryError.invalidPaginationTopology
            }
            parsedLink = parsed
        } else {
            parsedLink = nil
        }
        let parsedNextEndpoint = parsedLink?.nextPageURL.map(endpoint(from:))
        if let nextPageURL = parsedLink?.nextPageURL {
            guard nextPageURL.scheme?.caseInsensitiveCompare("https") == .orderedSame,
                  nextPageURL.host?.caseInsensitiveCompare("api.github.com") == .orderedSame,
                  nextPageURL.port == nil,
                  nextPageURL.user == nil,
                  nextPageURL.password == nil,
                  nextPageURL.fragment == nil
            else {
                throw RepositoryInventoryReplayReceiptRepositoryError.invalidPaginationTopology
            }
        }
        guard parsedNextEndpoint == page.nextEndpoint else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidPaginationTopology
        }
        if let followingPage {
            guard page.nextEndpoint == followingPage.endpoint,
                  isRepositoryEndpoint(
                    followingPage.endpoint,
                    organizationLogin: organizationLogin,
                    expectedPage: page.pageIndex + 1
                  )
            else {
                throw RepositoryInventoryReplayReceiptRepositoryError.invalidPaginationTopology
            }
        } else if page.nextEndpoint != nil {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidPaginationTopology
        }
    }

    static func normalizedState(
        identity: ConditionalRequestIdentity,
        organization: GitHubOrganization,
        in database: Database
    ) throws -> NormalizedState {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT repositories.id, repositories.organization_id,
                       repositories.github_repository_id, repositories.github_node_id,
                       repositories.owner_login, repositories.name,
                       repositories.is_private, repositories.is_archived,
                       repositories.has_discussions, repositories.has_discussions_known,
                       repositories.html_url, account_repository_access.access_state
                FROM repositories
                LEFT JOIN account_repository_access
                  ON account_repository_access.repository_id = repositories.id
                 AND account_repository_access.account_id = ?
                WHERE repositories.organization_id = ?
                ORDER BY repositories.id
                LIMIT ?
                """,
            arguments: [
                identity.scope.accountID.rawValue,
                organization.id.rawValue,
                maximumRepositoryCount + 1
            ]
        )
        guard rows.count <= maximumRepositoryCount else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidNormalizedState
        }
        var summaries = [RepositorySummary]()
        var availableIDs = Set<RepositoryID>()
        var material = Data()
        appendLengthPrefixed(Data("triage.repository-inventory.normalized.v1".utf8), to: &material)
        for row in rows {
            try Task.checkCancellation()
            guard let repositoryID = RepositoryID(rawValue: row["id"]),
                  (row["organization_id"] as String?) == organization.id.rawValue,
                  let githubRepositoryIDValue: String = row["github_repository_id"],
                  let githubRepositoryID = UInt64(githubRepositoryIDValue),
                  githubRepositoryID > 0,
                  String(githubRepositoryID) == githubRepositoryIDValue,
                  let nodeID = GitHubNodeID(rawValue: row["github_node_id"]),
                  repositoryID.rawValue == nodeID.rawValue,
                  let ownerLogin: String = row["owner_login"],
                  ownerLogin.caseInsensitiveCompare(organization.login) == .orderedSame,
                  validGitHubLogin(ownerLogin),
                  let name: String = row["name"],
                  validRepositoryName(name),
                  let isPrivate: Bool = row["is_private"],
                  let isArchived: Bool = row["is_archived"],
                  let hasDiscussions: Bool = row["has_discussions"],
                  let hasDiscussionsKnown: Bool = row["has_discussions_known"],
                  let urlValue: String = row["html_url"],
                  let url = URL(string: urlValue),
                  validRepositoryURL(url, owner: ownerLogin, name: name),
                  let accessValue: String = row["access_state"],
                  let accessState = RepositoryAccessState(rawValue: accessValue)
            else {
                throw RepositoryInventoryReplayReceiptRepositoryError.invalidNormalizedState
            }
            guard accessState == .available || accessState == .unknown else {
                throw RepositoryInventoryReplayReceiptRepositoryError.invalidNormalizedState
            }
            guard accessState == .available else { continue }
            guard availableIDs.insert(repositoryID).inserted else {
                throw RepositoryInventoryReplayReceiptRepositoryError.invalidNormalizedState
            }
            appendLengthPrefixed(Data(repositoryID.rawValue.utf8), to: &material)
            appendLengthPrefixed(Data(githubRepositoryIDValue.utf8), to: &material)
            appendLengthPrefixed(Data(nodeID.rawValue.utf8), to: &material)
            appendLengthPrefixed(Data(ownerLogin.utf8), to: &material)
            appendLengthPrefixed(Data(name.utf8), to: &material)
            appendLengthPrefixed(Data([isPrivate ? 1 : 0]), to: &material)
            appendLengthPrefixed(Data([isArchived ? 1 : 0]), to: &material)
            appendLengthPrefixed(Data([hasDiscussions ? 1 : 0]), to: &material)
            appendLengthPrefixed(Data([hasDiscussionsKnown ? 1 : 0]), to: &material)
            appendLengthPrefixed(Data(urlValue.utf8), to: &material)
            summaries.append(
                RepositorySummary(
                    id: repositoryID,
                    nodeID: nodeID,
                    ownerLogin: ownerLogin,
                    name: name,
                    isPrivate: isPrivate,
                    isArchived: isArchived,
                    hasDiscussions: hasDiscussions,
                    hasDiscussionsKnown: hasDiscussionsKnown,
                    url: url
                )
            )
        }
        guard summaries.count <= maximumRepositoryCount else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidNormalizedState
        }
        return NormalizedState(
            summaries: summaries,
            availableRepositoryIDs: availableIDs,
            digest: Data(SHA256.hash(data: material))
        )
    }

    static func validatedCoverage(
        identity: ConditionalRequestIdentity,
        organization: GitHubOrganization,
        normalizedState: NormalizedState,
        rawObservedAtMilliseconds: Int64,
        noLaterThanMilliseconds: Int64,
        in database: Database
    ) throws -> CoverageRecord {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT account_id, organization_id, repository_id, feature, stream_id,
                       interval_start_ms, interval_end_ms, credential_revision,
                       capability_revision, status, last_successful_at_ms, failure_detail
                FROM coverage_records
                WHERE account_id = ? AND organization_id = ? AND feature = ?
                  AND stream_id = ? AND credential_revision = ? AND capability_revision = ?
                  AND interval_start_ms IS NULL AND interval_end_ms IS NULL
                ORDER BY repository_id
                LIMIT ?
                """,
            arguments: [
                identity.scope.accountID.rawValue,
                organization.id.rawValue,
                CoverageFeature.repositories.rawValue,
                identity.streamID.rawValue,
                identity.scope.credentialRevision.rawValue,
                identity.scope.capabilityRevision.rawValue,
                maximumRepositoryCount + 2
            ]
        )
        guard rows.count <= maximumRepositoryCount + 1 else {
            throw RepositoryInventoryReplayReceiptRepositoryError.incompleteCoverage
        }
        var root: CoverageRecord?
        var leaves = [RepositoryID: CoverageRecord]()
        for row in rows {
            let record = try coverageRecord(from: row)
            if let repositoryID = record.repositoryID {
                guard leaves.updateValue(record, forKey: repositoryID) == nil else {
                    throw RepositoryInventoryReplayReceiptRepositoryError.incompleteCoverage
                }
            } else {
                guard root == nil else {
                    throw RepositoryInventoryReplayReceiptRepositoryError.incompleteCoverage
                }
                root = record
            }
        }
        guard let root,
              root.status == .complete,
              root.failureDetail == nil,
              let rootSuccessfulAt = root.lastSuccessfulAt,
              let rootSuccessfulAtMilliseconds = milliseconds(rootSuccessfulAt),
              rootSuccessfulAtMilliseconds >= rawObservedAtMilliseconds,
              rootSuccessfulAtMilliseconds <= noLaterThanMilliseconds
        else {
            throw RepositoryInventoryReplayReceiptRepositoryError.incompleteCoverage
        }
        for repositoryID in normalizedState.availableRepositoryIDs {
            guard let leaf = leaves[repositoryID],
                  leaf.status == .complete,
                  leaf.failureDetail == nil,
                  let successfulAt = leaf.lastSuccessfulAt,
                  let successfulAtMilliseconds = milliseconds(successfulAt),
                  successfulAtMilliseconds >= rawObservedAtMilliseconds,
                  successfulAtMilliseconds <= noLaterThanMilliseconds
            else {
                throw RepositoryInventoryReplayReceiptRepositoryError.incompleteCoverage
            }
        }
        return root
    }

    static func coverageRecord(from row: Row) throws -> CoverageRecord {
        guard let accountID = AccountID(rawValue: row["account_id"]),
              let organizationID = OrganizationID(rawValue: row["organization_id"]),
              let feature = CoverageFeature(rawValue: row["feature"]),
              let streamID = SyncStreamID(rawValue: row["stream_id"]),
              let credentialRevision = CredentialRevision(rawValue: row["credential_revision"]),
              let capabilityRevision = CapabilityRevision(rawValue: row["capability_revision"]),
              let status = CoverageStatus(rawValue: row["status"])
        else {
            throw RepositoryInventoryReplayReceiptRepositoryError.incompleteCoverage
        }
        let rawRepositoryID: String? = row["repository_id"]
        let repositoryID = rawRepositoryID.flatMap(RepositoryID.init(rawValue:))
        guard rawRepositoryID == nil || repositoryID != nil else {
            throw RepositoryInventoryReplayReceiptRepositoryError.incompleteCoverage
        }
        let intervalStartMilliseconds: Int64? = row["interval_start_ms"]
        let intervalEndMilliseconds: Int64? = row["interval_end_ms"]
        let lastSuccessfulAtMilliseconds: Int64? = row["last_successful_at_ms"]
        guard intervalStartMilliseconds == nil, intervalEndMilliseconds == nil else {
            throw RepositoryInventoryReplayReceiptRepositoryError.incompleteCoverage
        }
        return CoverageRecord(
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: repositoryID,
            feature: feature,
            streamID: streamID,
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision,
            status: status,
            lastSuccessfulAt: lastSuccessfulAtMilliseconds.map(date(from:)),
            failureDetail: row["failure_detail"]
        )
    }

    static func replayCoverageRecord(
        repositoryID: RepositoryID?,
        identity: ConditionalRequestIdentity,
        validatedAt: Date
    ) -> CoverageRecord {
        CoverageRecord(
            accountID: identity.scope.accountID,
            organizationID: identity.scope.organizationID,
            repositoryID: repositoryID,
            feature: .repositories,
            streamID: identity.streamID,
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: identity.scope.credentialRevision,
            capabilityRevision: identity.scope.capabilityRevision,
            status: .complete,
            lastSuccessfulAt: validatedAt,
            failureDetail: nil
        )
    }

    static func persistedPages(
        receiptID: String,
        expectedCount: Int,
        in database: Database
    ) throws -> [PersistedPageInput] {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT page_index, endpoint, request_key, link_header, next_endpoint,
                       raw_snapshot_id, object_count, raw_payload_digest, repository_id_digest
                FROM repository_inventory_replay_receipt_pages
                WHERE receipt_id = ? ORDER BY page_index
                """,
            arguments: [receiptID]
        )
        guard rows.count == expectedCount else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidPersistedData
        }
        return try rows.enumerated().map { offset, row in
            guard let pageIndex: Int = row["page_index"], pageIndex == offset + 1,
                  let endpoint: String = row["endpoint"],
                  let requestKey: String = row["request_key"],
                  requestKey == "GET \(endpoint)",
                  let rawSnapshotID = RawAPISnapshotID(rawValue: row["raw_snapshot_id"]),
                  let objectCount: Int = row["object_count"],
                  (0...maximumObjectsPerPage).contains(objectCount),
                  let rawPayloadDigest: Data = row["raw_payload_digest"],
                  rawPayloadDigest.count == SHA256.Digest.byteCount,
                  let repositoryIDDigest: Data = row["repository_id_digest"],
                  repositoryIDDigest.count == SHA256.Digest.byteCount
            else {
                throw RepositoryInventoryReplayReceiptRepositoryError.invalidPersistedData
            }
            let linkHeader: String? = row["link_header"]
            let nextEndpoint: String? = row["next_endpoint"]
            let page = RepositoryInventoryReplayReceiptPage(
                pageIndex: pageIndex,
                rawSnapshotID: rawSnapshotID,
                endpoint: endpoint,
                linkHeader: linkHeader,
                nextEndpoint: nextEndpoint
            )
            return PersistedPageInput(
                page: page,
                expectedObjectCount: objectCount,
                expectedRawPayloadDigest: rawPayloadDigest,
                expectedRepositoryIDDigest: repositoryIDDigest
            )
        }
    }

    static func receipt(
        from row: Row,
        expectedIdentity: ConditionalRequestIdentity
    ) throws -> RepositoryInventoryReplayReceipt {
        guard let receiptID: String = row["id"],
              receiptID == replayReceiptID(for: expectedIdentity),
              (row["account_id"] as String?) == expectedIdentity.scope.accountID.rawValue,
              (row["organization_id"] as String?) == expectedIdentity.scope.organizationID.rawValue,
              (row["feature"] as String?) == CoverageFeature.repositories.rawValue,
              (row["stream_id"] as String?) == expectedIdentity.streamID.rawValue,
              (row["request_key"] as String?) == expectedIdentity.requestKey,
              (row["credential_revision"] as String?)
                == expectedIdentity.scope.credentialRevision.rawValue,
              (row["capability_revision"] as String?)
                == expectedIdentity.scope.capabilityRevision.rawValue,
              let rawSourceRevision: String = row["raw_source_revision"],
              validSourceRevision(rawSourceRevision),
              let rawObservedAtMilliseconds: Int64 = row["raw_observed_at_ms"],
              let normalizedCommittedAtMilliseconds: Int64 = row["normalized_committed_at_ms"],
              let lastValidatedAtMilliseconds: Int64 = row["last_validated_at_ms"],
              rawObservedAtMilliseconds >= 0,
              normalizedCommittedAtMilliseconds >= rawObservedAtMilliseconds,
              lastValidatedAtMilliseconds >= normalizedCommittedAtMilliseconds,
              let parserVersion: Int = row["parser_version"],
              parserVersion == self.parserVersion,
              let pageCount: Int = row["page_count"],
              (1...maximumPages).contains(pageCount),
              let normalizedRepositoryCount: Int = row["normalized_repository_count"],
              (0...maximumRepositoryCount).contains(normalizedRepositoryCount),
              let normalizedDigest: Data = row["normalized_digest"],
              normalizedDigest.count == SHA256.Digest.byteCount
        else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidPersistedData
        }
        let eTag: String? = row["etag"]
        let lastModified: String? = row["last_modified"]
        let validator = ConditionalRequestValidator(
            identity: expectedIdentity,
            eTag: eTag,
            lastModified: lastModified,
            observedAt: date(from: rawObservedAtMilliseconds)
        )
        guard validValidator(validator) else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidPersistedData
        }
        return RepositoryInventoryReplayReceipt(
            identity: expectedIdentity,
            validator: validator,
            rawSourceRevision: rawSourceRevision,
            rawObservedAt: date(from: rawObservedAtMilliseconds),
            normalizedCommittedAt: date(from: normalizedCommittedAtMilliseconds),
            lastValidatedAt: date(from: lastValidatedAtMilliseconds),
            parserVersion: parserVersion,
            pageCount: pageCount,
            normalizedRepositoryCount: normalizedRepositoryCount,
            normalizedDigest: normalizedDigest
        )
    }

    static func existingReceiptAnchor(
        for identity: ConditionalRequestIdentity,
        in database: Database
    ) throws -> ExistingReceiptAnchor? {
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT raw_source_revision, raw_observed_at_ms
                FROM repository_inventory_replay_receipts
                WHERE account_id = ? AND organization_id = ? AND feature = ?
                  AND stream_id = ? AND request_key = ?
                """,
            arguments: logicalArguments(for: identity)
        ) else {
            return nil
        }
        guard let rawSourceRevision: String = row["raw_source_revision"],
              validSourceRevision(rawSourceRevision),
              let rawObservedAtMilliseconds: Int64 = row["raw_observed_at_ms"],
              rawObservedAtMilliseconds >= 0
        else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidPersistedData
        }
        return ExistingReceiptAnchor(
            rawSourceRevision: rawSourceRevision,
            rawObservedAtMilliseconds: rawObservedAtMilliseconds
        )
    }

    static func deleteLogicalReceipt(
        for identity: ConditionalRequestIdentity,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                DELETE FROM repository_inventory_replay_receipts
                WHERE account_id = ? AND organization_id = ? AND feature = ?
                  AND stream_id = ? AND request_key = ?
                """,
            arguments: logicalArguments(for: identity)
        )
    }

    static func decodeRepositories(
        _ payload: Data,
        organization: GitHubOrganization
    ) throws -> [GitHubRepositoryDTO] {
        guard payload.count <= maximumRawPageBytes else {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidPageInventory
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let repositories: [GitHubRepositoryDTO]
        do {
            repositories = try decoder.decode([GitHubRepositoryDTO].self, from: payload)
        } catch {
            throw RepositoryInventoryReplayReceiptRepositoryError.invalidPageInventory
        }
        for repository in repositories {
            guard repository.id > 0,
                  GitHubNodeID(rawValue: repository.nodeID) != nil,
                  validRepositoryName(repository.name),
                  validGitHubLogin(repository.owner.login),
                  repository.owner.login.caseInsensitiveCompare(organization.login) == .orderedSame,
                  validRepositoryURL(
                    repository.htmlURL,
                    owner: repository.owner.login,
                    name: repository.name
                  )
            else {
                throw RepositoryInventoryReplayReceiptRepositoryError.invalidPageInventory
            }
        }
        return repositories
    }

    static func isRepositoryEndpoint(
        _ endpoint: String,
        organizationLogin: String,
        expectedPage: Int
    ) -> Bool {
        if expectedPage == 1 {
            return endpoint == repositoryEndpoint(organizationLogin: organizationLogin, page: 1)
        }
        guard let components = URLComponents(string: "https://api.github.com\(endpoint)"),
              components.scheme == "https",
              components.host == "api.github.com",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              components.percentEncodedPath == "/orgs/\(organizationLogin)/repos"
        else {
            return false
        }
        let items = components.queryItems ?? []
        let typeValues = items.filter { $0.name == "type" }.map(\.value)
        let perPageValues = items.filter { $0.name == "per_page" }.map(\.value)
        let pageValues = items.filter { $0.name == "page" }.map(\.value)
        return items.count == 3
            && typeValues == ["all"]
            && perPageValues == ["100"]
            && pageValues == [String(expectedPage)]
            && (2...maximumPages).contains(expectedPage)
    }

    static func repositoryEndpoint(organizationLogin: String, page: Int) -> String {
        let root = "/orgs/\(organizationLogin)/repos?type=all&per_page=100"
        return page == 1 ? root : root + "&page=\(page)"
    }

    static func endpoint(from url: URL) -> String {
        url.path + (url.query.map { "?\($0)" } ?? "")
    }

    static func repositoryStreamID(for organizationID: OrganizationID) -> SyncStreamID {
        SyncStreamID(rawValue: "inventory-repositories-\(organizationID.rawValue)")!
    }

    static func rawSourceRevision(for pages: [ValidatedPage]) -> String {
        var hasher = SHA256()
        updateDigest(with: Data("repository-inventory-v1".utf8), hasher: &hasher)
        for page in pages {
            updateDigest(with: Data(page.input.endpoint.utf8), hasher: &hasher)
            updateDigest(with: page.snapshot.payload, hasher: &hasher)
        }
        return "repository-inventory-v1:" + hex(hasher.finalize())
    }

    static func expectedSnapshotID(
        _ snapshot: RawAPISnapshot,
        identity: ConditionalRequestIdentity
    ) -> RawAPISnapshotID? {
        let components = [
            Data("repository-page-v1".utf8),
            Data(identity.scope.accountID.rawValue.utf8),
            Data(identity.scope.organizationID.rawValue.utf8),
            Data(identity.scope.credentialRevision.rawValue.utf8),
            Data(identity.scope.capabilityRevision.rawValue.utf8),
            Data(snapshot.endpoint.utf8),
            Data((snapshot.eTag ?? "<nil>").utf8),
            Data((snapshot.lastModified ?? "<nil>").utf8),
            Data(String(milliseconds(snapshot.observedAt) ?? Int64.min).utf8),
            snapshot.payload
        ]
        return RawAPISnapshotID(rawValue: "repository-page:\(hexDigest(components))")
    }

    static func repositoryIDDigest(_ repositories: [GitHubRepositoryDTO]) -> Data {
        var material = Data()
        appendLengthPrefixed(Data("triage.repository-inventory.page-identities.v1".utf8), to: &material)
        for repository in repositories {
            appendLengthPrefixed(Data(String(repository.id).utf8), to: &material)
            appendLengthPrefixed(Data(repository.nodeID.utf8), to: &material)
        }
        return Data(SHA256.hash(data: material))
    }

    static func digest(domain: String, components: [Data]) -> Data {
        var material = Data()
        appendLengthPrefixed(Data(domain.utf8), to: &material)
        for component in components {
            appendLengthPrefixed(component, to: &material)
        }
        return Data(SHA256.hash(data: material))
    }

    static func hexDigest(_ components: [Data]) -> String {
        var hasher = SHA256()
        for component in components {
            updateDigest(with: component, hasher: &hasher)
        }
        return hex(hasher.finalize())
    }

    static func updateDigest(with data: Data, hasher: inout SHA256) {
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
        hasher.update(data: data)
    }

    static func appendLengthPrefixed(_ value: Data, to data: inout Data) {
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func replayReceiptID(for identity: ConditionalRequestIdentity) -> String {
        let digest = hexDigest([
            Data("repository-inventory-replay-receipt-v1".utf8),
            Data(identity.scope.accountID.rawValue.utf8),
            Data(identity.scope.organizationID.rawValue.utf8),
            Data(identity.feature.rawValue.utf8),
            Data(identity.streamID.rawValue.utf8),
            Data(identity.requestKey.utf8)
        ])
        return "repository-replay:\(digest)"
    }

    static func logicalArguments(for identity: ConditionalRequestIdentity) -> StatementArguments {
        StatementArguments([
            identity.scope.accountID.rawValue,
            identity.scope.organizationID.rawValue,
            CoverageFeature.repositories.rawValue,
            identity.streamID.rawValue,
            identity.requestKey
        ])
    }

    static func validValidator(_ validator: ConditionalRequestValidator) -> Bool {
        (validator.eTag != nil || validator.lastModified != nil)
            && validHeader(validator.eTag)
            && validHeader(validator.lastModified)
            && milliseconds(validator.observedAt) != nil
    }

    static func validHeader(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty
            && value.count <= 2_048
            && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }

    static func validSourceRevision(_ value: String) -> Bool {
        let prefix = "repository-inventory-v1:"
        let suffix = value.dropFirst(prefix.count)
        return value.hasPrefix(prefix)
            && suffix.count == 64
            && suffix.allSatisfy {
                ("0"..."9").contains(String($0)) || ("a"..."f").contains(String($0))
            }
    }

    static func validRepositoryName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && !value.contains("/") && !value.contains(where: \.isWhitespace)
    }

    static func validRepositoryURL(_ url: URL, owner: String, name: String) -> Bool {
        guard url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else {
            return false
        }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
        return components.count == 2
            && components[0].caseInsensitiveCompare(owner) == .orderedSame
            && components[1] == name
    }

    static func milliseconds(_ date: Date) -> Int64? {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite,
              value > Double(Int64.min),
              value < Double(Int64.max)
        else {
            return nil
        }
        return Int64(value.rounded())
    }

    static func date(from milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }
}
