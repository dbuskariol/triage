import CryptoKit
import Foundation
import GRDB
import XCTest
@testable import Triage

final class RepositoryInventoryReplayReceiptRepositoryTests: XCTestCase {
    func testEmptyInventoryReceiptAuthorizesExact304AndAdvancesRootFreshnessOnly() async throws {
        let fixture = try await RepositoryReplayFixture()
        defer { fixture.remove() }
        let authority = try await fixture.install(repositoriesByPage: [[]])
        let repository = RepositoryInventoryReplayReceiptRepository(vault: fixture.vault)

        try await repository.replaceModifiedResponseReceipt(
            authority.input,
            organization: fixture.organization
        )
        let before = try await fixture.receiptAnchors()
        let validatedAt = fixture.observedAt.addingTimeInterval(60)
        let replay = try await repository.validatedNotModifiedReceipt(
            for: authority.validator!,
            organization: fixture.organization,
            validatedAt: validatedAt
        )
        let after = try await fixture.receiptAnchors()

        XCTAssertEqual(replay?.summaries, [])
        XCTAssertEqual(replay?.coverage.status, .complete)
        XCTAssertEqual(replay?.coverage.lastSuccessfulAt, fixture.canonical(validatedAt))
        XCTAssertEqual(replay?.receipt.normalizedRepositoryCount, 0)
        XCTAssertEqual(replay?.receipt.lastValidatedAt, fixture.canonical(validatedAt))
        XCTAssertEqual(before?.rawSourceRevision, after?.rawSourceRevision)
        XCTAssertEqual(before?.rawObservedAtMilliseconds, after?.rawObservedAtMilliseconds)
        XCTAssertEqual(before?.normalizedCommittedAtMilliseconds, after?.normalizedCommittedAtMilliseconds)
        XCTAssertNotEqual(before?.lastValidatedAtMilliseconds, after?.lastValidatedAtMilliseconds)
        let coverage = try await fixture.repositoryCoverage()
        XCTAssertEqual(coverage.count, 1)
        XCTAssertNil(coverage[0].repositoryID)
        XCTAssertEqual(coverage[0].lastSuccessfulAt, fixture.canonical(validatedAt))
    }

    func testSinglePageReceiptIsIdempotentAndBindsSemanticRepositoryState() async throws {
        let fixture = try await RepositoryReplayFixture()
        defer { fixture.remove() }
        let value = fixture.repository(id: 1, nodeID: "R_1", name: "private-repo")
        let authority = try await fixture.install(repositoriesByPage: [[value]])
        let repository = RepositoryInventoryReplayReceiptRepository(vault: fixture.vault)

        try await repository.replaceModifiedResponseReceipt(
            authority.input,
            organization: fixture.organization
        )
        try await repository.replaceModifiedResponseReceipt(
            authority.input,
            organization: fixture.organization
        )

        let counts = try await fixture.receiptCounts()
        XCTAssertEqual(counts.receipts, 1)
        XCTAssertEqual(counts.pages, 1)
        let validatedAt = fixture.observedAt.addingTimeInterval(1)
        let replay = try await repository.validatedNotModifiedReceipt(
            for: authority.validator!,
            organization: fixture.organization,
            validatedAt: validatedAt
        )
        XCTAssertEqual(replay?.summaries.map(\.id), [RepositoryID(rawValue: "R_1")!])
        XCTAssertEqual(replay?.summaries.first?.hasDiscussions, true)
        XCTAssertEqual(replay?.summaries.first?.hasDiscussionsKnown, true)
        XCTAssertEqual(replay?.coverage.lastSuccessfulAt, fixture.canonical(validatedAt))
        let leaf = try await fixture.repositoryCoverage(
            repositoryID: RepositoryID(rawValue: "R_1")!
        )
        XCTAssertEqual(leaf.count, 1)
        XCTAssertEqual(leaf[0].status, .complete)
        XCTAssertEqual(leaf[0].lastSuccessfulAt, fixture.canonical(validatedAt))
    }

    func test304RefreshesAvailableLeavesButPreservesOmittedUnknownFreshness() async throws {
        let fixture = try await RepositoryReplayFixture()
        defer { fixture.remove() }
        let omittedID = RepositoryID(rawValue: "R_OMITTED")!
        let availableID = RepositoryID(rawValue: "R_AVAILABLE")!
        let oldObservedAt = fixture.observedAt.addingTimeInterval(-60)
        _ = try await fixture.install(
            repositoriesByPage: [[
                fixture.repository(id: 1, nodeID: omittedID.rawValue, name: "omitted")
            ]],
            observedAt: oldObservedAt
        )
        let authority = try await fixture.install(
            repositoriesByPage: [[
                fixture.repository(id: 2, nodeID: availableID.rawValue, name: "available")
            ]]
        )
        try await fixture.saveCoverage(
            repositoryID: omittedID,
            status: .unknown,
            observedAt: fixture.observedAt
        )
        let omittedBeforeRecords = try await fixture.repositoryCoverage(repositoryID: omittedID)
        let omittedBefore = try XCTUnwrap(omittedBeforeRecords.first)
        let repository = RepositoryInventoryReplayReceiptRepository(vault: fixture.vault)
        try await repository.replaceModifiedResponseReceipt(
            authority.input,
            organization: fixture.organization
        )
        let validatedAt = fixture.observedAt.addingTimeInterval(60)

        let replay = try await repository.validatedNotModifiedReceipt(
            for: authority.validator!,
            organization: fixture.organization,
            validatedAt: validatedAt
        )

        XCTAssertEqual(replay?.summaries.map(\.id), [availableID])
        XCTAssertEqual(replay?.coverage.lastSuccessfulAt, fixture.canonical(validatedAt))
        let availableAfterRecords = try await fixture.repositoryCoverage(repositoryID: availableID)
        let omittedAfterRecords = try await fixture.repositoryCoverage(repositoryID: omittedID)
        let availableAfter = try XCTUnwrap(availableAfterRecords.first)
        let omittedAfter = try XCTUnwrap(omittedAfterRecords.first)
        XCTAssertEqual(availableAfter.status, .complete)
        XCTAssertEqual(availableAfter.lastSuccessfulAt, fixture.canonical(validatedAt))
        XCTAssertEqual(omittedAfter, omittedBefore)
        XCTAssertEqual(omittedAfter.status, .unknown)
        XCTAssertEqual(omittedAfter.lastSuccessfulAt, fixture.canonical(oldObservedAt))
    }

    func testMultiPageReceiptRequiresContiguousTopologyAndExactContainingRawPages() async throws {
        let fixture = try await RepositoryReplayFixture()
        defer { fixture.remove() }
        let first = fixture.repository(id: 1, nodeID: "R_1", name: "first")
        let second = fixture.repository(id: 2, nodeID: "R_2", name: "second")
        let authority = try await fixture.install(repositoriesByPage: [[first], [second]])
        let repository = RepositoryInventoryReplayReceiptRepository(vault: fixture.vault)

        try await repository.replaceModifiedResponseReceipt(
            authority.input,
            organization: fixture.organization
        )
        let replay = try await repository.validatedNotModifiedReceipt(
            for: authority.validator!,
            organization: fixture.organization,
            validatedAt: fixture.observedAt.addingTimeInterval(1)
        )

        XCTAssertEqual(replay?.summaries.map(\.id), [
            RepositoryID(rawValue: "R_1")!, RepositoryID(rawValue: "R_2")!
        ])
        XCTAssertEqual(replay?.receipt.pageCount, 2)
        let stored = try await fixture.storedPages()
        XCTAssertEqual(stored.map(\.pageIndex), [1, 2])
        XCTAssertEqual(stored[0].nextEndpoint, stored[1].endpoint)
        XCTAssertNil(stored[1].nextEndpoint)
        XCTAssertNotEqual(stored[0].rawPayloadDigest, stored[1].rawPayloadDigest)
        XCTAssertNotEqual(stored[0].repositoryIDDigest, stored[1].repositoryIDDigest)
    }

    func testCompactionPreservesEveryReceiptBoundRawPage() async throws {
        let fixture = try await RepositoryReplayFixture()
        defer { fixture.remove() }
        let first = fixture.repository(id: 1, nodeID: "R_1", name: "first")
        let second = fixture.repository(id: 2, nodeID: "R_2", name: "second")
        let authority = try await fixture.install(repositoriesByPage: [[first], [second]])
        let repository = RepositoryInventoryReplayReceiptRepository(vault: fixture.vault)
        try await repository.replaceModifiedResponseReceipt(
            authority.input,
            organization: fixture.organization
        )
        let boundSnapshotIDs = Set(authority.input.pages.map(\.rawSnapshotID))
        _ = try await fixture.install(
            repositoriesByPage: [[first], [second]],
            observedAt: fixture.observedAt.addingTimeInterval(60)
        )

        _ = try await RawAPISnapshotRepository(vault: fixture.vault).compact(
            accountID: fixture.account.id,
            retainingMostRecentPerSource: 1,
            before: fixture.observedAt.addingTimeInterval(120)
        )

        let remaining = try await RawAPISnapshotRepository(vault: fixture.vault).snapshots(
            for: fixture.account.id
        )
        let remainingIDs = Set(remaining.map(\.id))
        XCTAssertTrue(boundSnapshotIDs.isSubset(of: remainingIDs))
    }

    func testRetiringOnePostAccountReceiptReleasesOnlyItsRawPageForCompaction() async throws {
        let fixture = try await RepositoryReplayFixture()
        defer { fixture.remove() }
        let rawRepository = RawAPISnapshotRepository(vault: fixture.vault)
        let oldAccount = RawAPISnapshot(
            id: RawAPISnapshotID(rawValue: "post-account-receipt-old")!,
            accountID: fixture.account.id,
            githubNodeID: nil,
            endpoint: "/user/orgs?per_page=100",
            eTag: "\"account-old\"",
            parserVersion: 1,
            observedAt: fixture.observedAt.addingTimeInterval(-120),
            payload: Data("[]".utf8)
        )
        let newAccount = RawAPISnapshot(
            id: RawAPISnapshotID(rawValue: "post-account-receipt-new")!,
            accountID: fixture.account.id,
            githubNodeID: nil,
            endpoint: oldAccount.endpoint,
            eTag: "\"account-new\"",
            parserVersion: 1,
            observedAt: fixture.observedAt.addingTimeInterval(-60),
            payload: Data("[]".utf8)
        )
        let oldMetadata = RawAPISnapshot(
            id: RawAPISnapshotID(rawValue: "organization-metadata-receipt-old")!,
            accountID: fixture.account.id,
            githubNodeID: nil,
            endpoint: "/orgs/acme",
            eTag: "\"metadata-old\"",
            parserVersion: 1,
            observedAt: fixture.observedAt.addingTimeInterval(-120),
            payload: Data("{}".utf8)
        )
        let newMetadata = RawAPISnapshot(
            id: RawAPISnapshotID(rawValue: "organization-metadata-receipt-new")!,
            accountID: fixture.account.id,
            githubNodeID: nil,
            endpoint: oldMetadata.endpoint,
            eTag: "\"metadata-new\"",
            parserVersion: 1,
            observedAt: fixture.observedAt.addingTimeInterval(-60),
            payload: Data("{}".utf8)
        )
        for snapshot in [oldAccount, newAccount, oldMetadata, newMetadata] {
            try await rawRepository.save(snapshot)
        }

        try await fixture.vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO account_organization_inventory_replay_receipts (
                        id, account_id, credential_revision, request_key, etag, last_modified,
                        parser_version, source_revision, normalized_digest, page_count,
                        organization_count, observed_at_ms, committed_at_ms, validated_at_ms, receipt_version
                    ) VALUES ('account-receipt', ?, ?, 'GET /user/orgs?per_page=100', '"account-old"', NULL,
                              1, 'account-source', ?, 1, 0, 9_880_000, 9_880_000, 9_880_000, 1)
                    """,
                arguments: [
                    fixture.account.id.rawValue,
                    fixture.credentialRevision.rawValue,
                    Data(repeating: 0xA1, count: 32)
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO account_organization_inventory_replay_receipt_pages (
                        receipt_id, page_ordinal, raw_snapshot_id, request_key, raw_payload_digest,
                        organization_ids_digest, is_terminal
                    ) VALUES ('account-receipt', 1, ?, 'GET /user/orgs?per_page=100', ?, ?, 1)
                    """,
                arguments: [
                    oldAccount.id.rawValue,
                    Data(repeating: 0xA2, count: 32),
                    Data(repeating: 0xA3, count: 32)
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO sync_streams (
                        id, account_id, organization_id, feature, high_water_ms,
                        last_successful_at_ms, last_attempt_at_ms, state, failure_detail
                    ) VALUES ('organization-metadata-receipt-stream', ?, ?, 'organizationMetadata',
                              NULL, NULL, NULL, 'idle', NULL)
                    """,
                arguments: [fixture.account.id.rawValue, fixture.organization.id.rawValue]
            )
            try database.execute(
                sql: """
                    INSERT INTO organization_metadata_replay_receipts (
                        id, account_id, organization_id, feature, stream_id, credential_revision,
                        capability_revision, request_key, etag, last_modified, raw_snapshot_id,
                        raw_payload_digest, normalized_digest, parser_version, source_revision,
                        observed_at_ms, committed_at_ms, validated_at_ms, receipt_version
                    ) VALUES ('metadata-receipt', ?, ?, 'organizationMetadata',
                              'organization-metadata-receipt-stream', ?, ?, 'GET /orgs/acme',
                              '"metadata-old"', NULL, ?, ?, ?, 1, 'metadata-source',
                              9_880_000, 9_880_000, 9_880_000, 1)
                    """,
                arguments: [
                    fixture.account.id.rawValue,
                    fixture.organization.id.rawValue,
                    fixture.credentialRevision.rawValue,
                    fixture.capabilityRevision.rawValue,
                    oldMetadata.id.rawValue,
                    Data(repeating: 0xB1, count: 32),
                    Data(repeating: 0xB2, count: 32)
                ]
            )
        }

        let compactedWhilePinned = try await rawRepository.compact(
            accountID: fixture.account.id,
            retainingMostRecentPerSource: 1,
            before: fixture.observedAt
        )
        XCTAssertEqual(compactedWhilePinned, 0)

        try await fixture.vault.write { database in
            try database.execute(
                sql: "DELETE FROM account_organization_inventory_replay_receipts WHERE id = 'account-receipt'"
            )
        }
        let compactedAfterRetirement = try await rawRepository.compact(
            accountID: fixture.account.id,
            retainingMostRecentPerSource: 1,
            before: fixture.observedAt
        )
        XCTAssertEqual(compactedAfterRetirement, 1)
        let remaining = try await rawRepository.snapshots(for: fixture.account.id)
        let remainingIDs = Set(remaining.map(\.id))
        XCTAssertFalse(remainingIDs.contains(oldAccount.id))
        XCTAssertTrue(remainingIDs.contains(newAccount.id))
        XCTAssertTrue(remainingIDs.contains(oldMetadata.id))
        XCTAssertTrue(remainingIDs.contains(newMetadata.id))
    }

    func testGapDuplicateAndCrossScopePageInputsFailBeforeReceiptMutation() async throws {
        let fixture = try await RepositoryReplayFixture()
        defer { fixture.remove() }
        let first = fixture.repository(id: 1, nodeID: "R_1", name: "first")
        let second = fixture.repository(id: 2, nodeID: "R_2", name: "second")
        let authority = try await fixture.install(repositoriesByPage: [[first], [second]])
        let repository = RepositoryInventoryReplayReceiptRepository(vault: fixture.vault)
        let invalidPages = [
            authority.input.pages[0],
            RepositoryInventoryReplayReceiptPage(
                pageIndex: 3,
                rawSnapshotID: authority.input.pages[1].rawSnapshotID,
                endpoint: authority.input.pages[1].endpoint,
                linkHeader: authority.input.pages[1].linkHeader,
                nextEndpoint: authority.input.pages[1].nextEndpoint
            )
        ]
        let invalid = RepositoryInventoryReplayReceiptInput(
            identity: authority.input.identity,
            validator: authority.input.validator,
            rawSourceRevision: authority.input.rawSourceRevision,
            pages: invalidPages,
            normalizedCommittedAt: authority.input.normalizedCommittedAt
        )

        await XCTAssertThrowsErrorAsync {
            try await repository.replaceModifiedResponseReceipt(
                invalid,
                organization: fixture.organization
            )
        } verify: { error in
            XCTAssertEqual(
                error as? RepositoryInventoryReplayReceiptRepositoryError,
                .invalidPageInventory
            )
        }
        let counts = try await fixture.receiptCounts()
        XCTAssertEqual(counts.receipts, 0)
    }

    func testRawTamperAndNormalizationFailureCannotCreateReceipt() async throws {
        let fixture = try await RepositoryReplayFixture()
        defer { fixture.remove() }
        let value = fixture.repository(id: 1, nodeID: "R_1", name: "private-repo")
        let authority = try await fixture.install(repositoriesByPage: [[value]])
        let repository = RepositoryInventoryReplayReceiptRepository(vault: fixture.vault)
        try await NormalizationFailureRepository(vault: fixture.vault).record(
            NormalizationFailure(
                id: UUID(),
                accountID: fixture.account.id,
                rawSnapshotID: authority.input.pages[0].rawSnapshotID,
                githubNodeID: nil,
                endpoint: authority.input.pages[0].endpoint,
                parserVersion: 1,
                occurredAt: fixture.observedAt,
                redactedDiagnostic: "repository payload rejected"
            )
        )

        await XCTAssertThrowsErrorAsync {
            try await repository.replaceModifiedResponseReceipt(
                authority.input,
                organization: fixture.organization
            )
        } verify: { error in
            XCTAssertEqual(
                error as? RepositoryInventoryReplayReceiptRepositoryError,
                .normalizationFailure
            )
        }
        let counts = try await fixture.receiptCounts()
        XCTAssertEqual(counts.receipts, 0)
    }

    func test304ReturnsNilForMissingOrRetiredRevisionButThrowsForPersistedCorruption() async throws {
        let fixture = try await RepositoryReplayFixture()
        defer { fixture.remove() }
        let value = fixture.repository(id: 1, nodeID: "R_1", name: "private-repo")
        let authority = try await fixture.install(repositoriesByPage: [[value]])
        let repository = RepositoryInventoryReplayReceiptRepository(vault: fixture.vault)

        let missing = try await repository.validatedNotModifiedReceipt(
            for: authority.validator!,
            organization: fixture.organization,
            validatedAt: fixture.observedAt.addingTimeInterval(1)
        )
        XCTAssertNil(missing)
        try await repository.replaceModifiedResponseReceipt(
            authority.input,
            organization: fixture.organization
        )
        try await fixture.vault.write { database in
            try database.execute(
                sql: "UPDATE repository_inventory_replay_receipts SET normalized_digest = zeroblob(32)"
            )
        }

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.validatedNotModifiedReceipt(
                for: authority.validator!,
                organization: fixture.organization,
                validatedAt: fixture.observedAt.addingTimeInterval(1)
            )
        } verify: { error in
            XCTAssertEqual(
                error as? RepositoryInventoryReplayReceiptRepositoryError,
                .invalidNormalizedState
            )
        }
    }

    func test304RejectsNormalizedLinkCoverageAndValidatorTampering() async throws {
        try await assert304TamperRejected(
            mutation: "UPDATE repositories SET name = 'tampered'",
            expected: .invalidNormalizedState
        )
        try await assert304TamperRejected(
            mutation: "UPDATE repository_inventory_replay_receipt_pages SET link_header = '<https://api.github.com/orgs/acme/repos?type=all&per_page=100&page=3>; rel=\"next\"'",
            expected: .invalidPaginationTopology,
            multipage: true
        )
        try await assert304TamperRejected(
            mutation: "DELETE FROM coverage_records WHERE repository_id IS NOT NULL",
            expected: .incompleteCoverage
        )
        try await assert304TamperRejected(
            mutation: "UPDATE conditional_request_cache SET etag = '\"different\"'",
            expected: .invalidValidator
        )
    }

    func testOlderOrFutureRelativeValidationFailsClosedAndPreservesReceipt() async throws {
        let fixture = try await RepositoryReplayFixture()
        defer { fixture.remove() }
        let value = fixture.repository(id: 1, nodeID: "R_1", name: "private-repo")
        let authority = try await fixture.install(repositoriesByPage: [[value]])
        let repository = RepositoryInventoryReplayReceiptRepository(vault: fixture.vault)
        try await repository.replaceModifiedResponseReceipt(
            authority.input,
            organization: fixture.organization
        )
        let before = try await fixture.receiptAnchors()

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.validatedNotModifiedReceipt(
                for: authority.validator!,
                organization: fixture.organization,
                validatedAt: fixture.observedAt.addingTimeInterval(-1)
            )
        } verify: { error in
            XCTAssertEqual(
                error as? RepositoryInventoryReplayReceiptRepositoryError,
                .staleValidation
            )
        }
        let after = try await fixture.receiptAnchors()
        XCTAssertEqual(after, before)
    }

    func testValidatorlessModifiedAuthorityRetiresPriorReceiptAfterFullValidation() async throws {
        let fixture = try await RepositoryReplayFixture()
        defer { fixture.remove() }
        let value = fixture.repository(id: 1, nodeID: "R_1", name: "private-repo")
        let first = try await fixture.install(repositoriesByPage: [[value]])
        let repository = RepositoryInventoryReplayReceiptRepository(vault: fixture.vault)
        try await repository.replaceModifiedResponseReceipt(
            first.input,
            organization: fixture.organization
        )
        let validatorless = try await fixture.install(
            repositoriesByPage: [[value]],
            observedAt: fixture.observedAt.addingTimeInterval(60),
            eTag: nil,
            lastModified: nil
        )

        try await repository.replaceModifiedResponseReceipt(
            validatorless.input,
            organization: fixture.organization
        )

        let counts = try await fixture.receiptCounts()
        XCTAssertEqual(counts.receipts, 0)
        XCTAssertEqual(counts.pages, 0)
    }

    func testCancellationBeforeValidationDoesNotReplaceReceipt() async throws {
        let fixture = try await RepositoryReplayFixture()
        defer { fixture.remove() }
        let value = fixture.repository(id: 1, nodeID: "R_1", name: "private-repo")
        let authority = try await fixture.install(repositoriesByPage: [[value]])
        let repository = RepositoryInventoryReplayReceiptRepository(vault: fixture.vault)
        try await repository.replaceModifiedResponseReceipt(
            authority.input,
            organization: fixture.organization
        )
        let before = try await fixture.receiptAnchors()

        let cancellationObserved = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await repository.replaceModifiedResponseReceipt(
                    authority.input,
                    organization: fixture.organization
                )
                return false
            } catch {
                return error is CancellationError
            }
        }.value

        XCTAssertTrue(cancellationObserved)
        let after = try await fixture.receiptAnchors()
        XCTAssertEqual(after, before)
    }

    private func assert304TamperRejected(
        mutation: String,
        expected: RepositoryInventoryReplayReceiptRepositoryError,
        multipage: Bool = false
    ) async throws {
        let fixture = try await RepositoryReplayFixture()
        defer { fixture.remove() }
        let first = fixture.repository(id: 1, nodeID: "R_1", name: "first")
        let pages = multipage
            ? [[first], [fixture.repository(id: 2, nodeID: "R_2", name: "second")]]
            : [[first]]
        let authority = try await fixture.install(repositoriesByPage: pages)
        let repository = RepositoryInventoryReplayReceiptRepository(vault: fixture.vault)
        try await repository.replaceModifiedResponseReceipt(
            authority.input,
            organization: fixture.organization
        )
        try await fixture.vault.write { database in
            try database.execute(sql: mutation)
        }

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.validatedNotModifiedReceipt(
                for: authority.validator!,
                organization: fixture.organization,
                validatedAt: fixture.observedAt.addingTimeInterval(1)
            )
        } verify: { error in
            XCTAssertEqual(error as? RepositoryInventoryReplayReceiptRepositoryError, expected)
        }
    }
}

private final class RepositoryReplayFixture: @unchecked Sendable {
    struct Authority: Sendable {
        let input: RepositoryInventoryReplayReceiptInput
        let validator: ConditionalRequestValidator?
    }

    struct ReceiptAnchors: Equatable, Sendable {
        let rawSourceRevision: String
        let rawObservedAtMilliseconds: Int64
        let normalizedCommittedAtMilliseconds: Int64
        let lastValidatedAtMilliseconds: Int64
    }

    struct StoredPage: Equatable, Sendable {
        let pageIndex: Int
        let endpoint: String
        let nextEndpoint: String?
        let rawPayloadDigest: Data
        let repositoryIDDigest: Data
    }

    let root: URL
    let vault: AccountVault
    let account: GitHubAccount
    let organization: GitHubOrganization
    let credentialRevision = CredentialRevision(rawValue: "credential-1")!
    let capabilityRevision = CapabilityRevision(rawValue: "capability-1")!
    let observedAt = Date(timeIntervalSince1970: 10_000)

    var streamID: SyncStreamID {
        SyncStreamID(rawValue: "inventory-repositories-\(organization.id.rawValue)")!
    }

    var scope: SynchronizationScope {
        SynchronizationScope(
            accountID: account.id,
            organizationID: organization.id,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision
        )
    }

    var rootEndpoint: String {
        "/orgs/\(organization.login)/repos?type=all&per_page=100"
    }

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".triage-repository-replay-\(UUID().uuidString)", isDirectory: true)
        account = GitHubAccount(
            id: AccountID.make(),
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_1")!,
            login: "octocat",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: observedAt,
            lastValidatedAt: observedAt
        )
        organization = GitHubOrganization(
            id: OrganizationID(rawValue: "acme")!,
            githubOrganizationID: 2,
            nodeID: GitHubNodeID(rawValue: "O_2")!,
            login: "acme"
        )
        vault = try await VaultRegistry(rootDirectory: root).open(
            accountID: account.id,
            vaultKey: try VaultKey.generate()
        )
        let accounts = AccountRepository(vault: vault)
        try await accounts.save(account, credentialRevision: credentialRevision)
        try await accounts.save(
            organization,
            access: OrganizationAccess(
                accountID: account.id,
                organizationID: organization.id,
                state: .available,
                capabilityRevision: capabilityRevision,
                capabilities: [],
                checkedAt: observedAt
            )
        )
    }

    func install(
        repositoriesByPage: [[GitHubRepositoryDTO]],
        observedAt: Date? = nil,
        eTag: String? = "\"repository-v1\"",
        lastModified: String? = nil
    ) async throws -> Authority {
        let observedAt = observedAt ?? self.observedAt
        let identity = ConditionalRequestIdentity(
            scope: scope,
            feature: .repositories,
            streamID: streamID,
            requestKey: "GET \(rootEndpoint)"
        )
        let validator = (eTag != nil || lastModified != nil) ? ConditionalRequestValidator(
            identity: identity,
            eTag: eTag,
            lastModified: lastModified,
            observedAt: observedAt
        ) : nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var receiptPages = [RepositoryInventoryReplayReceiptPage]()
        var rawPages = [(endpoint: String, payload: Data)]()
        for (offset, repositories) in repositoriesByPage.enumerated() {
            let pageIndex = offset + 1
            let endpoint = self.endpoint(page: pageIndex)
            let nextEndpoint = repositoriesByPage.indices.contains(offset + 1)
                ? self.endpoint(page: pageIndex + 1)
                : nil
            let linkHeader = nextEndpoint.map {
                "<https://api.github.com\($0)>; rel=\"next\""
            }
            let payload = try encoder.encode(repositories)
            let snapshot = snapshot(
                endpoint: endpoint,
                payload: payload,
                observedAt: observedAt,
                eTag: pageIndex == 1 ? eTag : nil,
                lastModified: pageIndex == 1 ? lastModified : nil
            )
            try await RawAPISnapshotRepository(vault: vault).save(snapshot)
            receiptPages.append(
                RepositoryInventoryReplayReceiptPage(
                    pageIndex: pageIndex,
                    rawSnapshotID: snapshot.id,
                    endpoint: endpoint,
                    linkHeader: linkHeader,
                    nextEndpoint: nextEndpoint
                )
            )
            rawPages.append((endpoint, payload))
        }
        let flattened = repositoriesByPage.flatMap { $0 }
        _ = try await RepositoryInventoryRepository(vault: vault).reconcile(
            flattened,
            accountID: account.id,
            organization: organization,
            observedAt: observedAt,
            reconciliationIntent: .incremental
        )
        let coverage = CoverageRepository(vault: vault)
        try await coverage.save(
            coverageRecord(repositoryID: nil, status: .complete, observedAt: observedAt),
            attemptedAt: observedAt
        )
        for repository in flattened {
            try await coverage.save(
                coverageRecord(
                    repositoryID: RepositoryID(rawValue: repository.nodeID)!,
                    status: .complete,
                    observedAt: observedAt
                ),
                attemptedAt: observedAt
            )
        }
        if let validator {
            try await ConditionalRequestCacheRepository(vault: vault).save(validator)
        } else {
            try await ConditionalRequestCacheRepository(vault: vault).remove(for: identity)
        }
        return Authority(
            input: RepositoryInventoryReplayReceiptInput(
                identity: identity,
                validator: validator,
                rawSourceRevision: rawSourceRevision(rawPages),
                pages: receiptPages,
                normalizedCommittedAt: observedAt
            ),
            validator: validator
        )
    }

    func repository(id: UInt64, nodeID: String, name: String) -> GitHubRepositoryDTO {
        GitHubRepositoryDTO(
            id: id,
            nodeID: nodeID,
            name: name,
            isPrivate: true,
            isArchived: false,
            hasDiscussions: true,
            htmlURL: URL(string: "https://github.com/acme/\(name)")!,
            updatedAt: observedAt,
            owner: .init(login: "acme")
        )
    }

    func receiptAnchors() async throws -> ReceiptAnchors? {
        try await vault.read { database in
            try Row.fetchOne(
                database,
                sql: """
                    SELECT raw_source_revision, raw_observed_at_ms,
                           normalized_committed_at_ms, last_validated_at_ms
                    FROM repository_inventory_replay_receipts
                    """
            ).map { row in
                ReceiptAnchors(
                    rawSourceRevision: row["raw_source_revision"],
                    rawObservedAtMilliseconds: row["raw_observed_at_ms"],
                    normalizedCommittedAtMilliseconds: row["normalized_committed_at_ms"],
                    lastValidatedAtMilliseconds: row["last_validated_at_ms"]
                )
            }
        }
    }

    func receiptCounts() async throws -> (receipts: Int, pages: Int) {
        try await vault.read { database in
            (
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM repository_inventory_replay_receipts"
                ) ?? 0,
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM repository_inventory_replay_receipt_pages"
                ) ?? 0
            )
        }
    }

    func storedPages() async throws -> [StoredPage] {
        try await vault.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT page_index, endpoint, next_endpoint,
                           raw_payload_digest, repository_id_digest
                    FROM repository_inventory_replay_receipt_pages ORDER BY page_index
                    """
            ).map { row in
                StoredPage(
                    pageIndex: row["page_index"],
                    endpoint: row["endpoint"],
                    nextEndpoint: row["next_endpoint"],
                    rawPayloadDigest: row["raw_payload_digest"],
                    repositoryIDDigest: row["repository_id_digest"]
                )
            }
        }
    }

    func repositoryCoverage(repositoryID: RepositoryID? = nil) async throws -> [CoverageRecord] {
        try await CoverageRepository(vault: vault).records(
            for: account.id,
            organizationID: organization.id
        ).filter {
            $0.feature == .repositories
                && $0.streamID == streamID
                && $0.repositoryID == repositoryID
                && $0.credentialRevision == credentialRevision
                && $0.capabilityRevision == capabilityRevision
        }
    }

    func saveCoverage(
        repositoryID: RepositoryID,
        status: CoverageStatus,
        observedAt: Date
    ) async throws {
        try await CoverageRepository(vault: vault).save(
            coverageRecord(
                repositoryID: repositoryID,
                status: status,
                observedAt: observedAt
            ),
            attemptedAt: observedAt
        )
    }

    func canonical(_ date: Date) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds(date)) / 1_000)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func coverageRecord(
        repositoryID: RepositoryID?,
        status: CoverageStatus,
        observedAt: Date
    ) -> CoverageRecord {
        CoverageRecord(
            accountID: account.id,
            organizationID: organization.id,
            repositoryID: repositoryID,
            feature: .repositories,
            streamID: streamID,
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision,
            status: status,
            lastSuccessfulAt: status == .complete ? observedAt : nil,
            failureDetail: nil
        )
    }

    private func endpoint(page: Int) -> String {
        page == 1 ? rootEndpoint : rootEndpoint + "&page=\(page)"
    }

    private func snapshot(
        endpoint: String,
        payload: Data,
        observedAt: Date,
        eTag: String?,
        lastModified: String?
    ) -> RawAPISnapshot {
        let pageIdentity = ConditionalRequestIdentity(
            scope: scope,
            feature: .repositories,
            streamID: streamID,
            requestKey: "GET \(endpoint)"
        )
        let id = snapshotID(
            endpoint: endpoint,
            payload: payload,
            observedAt: observedAt,
            eTag: eTag,
            lastModified: lastModified
        )
        return RawAPISnapshot(
            id: id,
            accountID: account.id,
            githubNodeID: nil,
            endpoint: endpoint,
            eTag: eTag,
            lastModified: lastModified,
            parserVersion: 1,
            observedAt: observedAt,
            payload: payload,
            requestIdentity: pageIdentity
        )
    }

    private func snapshotID(
        endpoint: String,
        payload: Data,
        observedAt: Date,
        eTag: String?,
        lastModified: String?
    ) -> RawAPISnapshotID {
        let components = [
            Data("repository-page-v1".utf8),
            Data(account.id.rawValue.utf8),
            Data(organization.id.rawValue.utf8),
            Data(credentialRevision.rawValue.utf8),
            Data(capabilityRevision.rawValue.utf8),
            Data(endpoint.utf8),
            Data((eTag ?? "<nil>").utf8),
            Data((lastModified ?? "<nil>").utf8),
            Data(String(milliseconds(observedAt)).utf8),
            payload
        ]
        return RawAPISnapshotID(rawValue: "repository-page:\(digest(components))")!
    }

    private func rawSourceRevision(_ pages: [(endpoint: String, payload: Data)]) -> String {
        var components = [Data("repository-inventory-v1".utf8)]
        for page in pages {
            components.append(Data(page.endpoint.utf8))
            components.append(page.payload)
        }
        return "repository-inventory-v1:\(digest(components))"
    }

    private func digest(_ components: [Data]) -> String {
        var hasher = SHA256()
        for component in components {
            var length = UInt64(component.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
            hasher.update(data: component)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {
        verify(error)
    }
}
