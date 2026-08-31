import XCTest
@testable import Triage

final class CoverageRepositoryTests: XCTestCase {
    func testTransactionScopedCoverageSaveRollsBackSiblingSourceWritesOnValidationFailure() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let sourceSnapshot = RawAPISnapshot(
            id: RawAPISnapshotID.make(),
            accountID: fixture.accountID,
            githubNodeID: nil,
            endpoint: "/orgs/acme/repos?type=all&per_page=100",
            eTag: "inventory-v1",
            parserVersion: 1,
            observedAt: fixture.date,
            payload: Data("[]".utf8)
        )
        let valid = fixture.record(status: .complete, lastSuccessfulAt: fixture.date, failureDetail: nil)
        let invalid = CoverageRecord(
            accountID: AccountID.make(),
            organizationID: valid.organizationID,
            repositoryID: valid.repositoryID,
            feature: valid.feature,
            streamID: valid.streamID,
            intervalStart: valid.intervalStart,
            intervalEnd: valid.intervalEnd,
            credentialRevision: valid.credentialRevision,
            capabilityRevision: valid.capabilityRevision,
            status: valid.status,
            lastSuccessfulAt: valid.lastSuccessfulAt,
            failureDetail: valid.failureDetail
        )

        do {
            try await fixture.vault.writeTransaction { database in
                try RawAPISnapshotRepository.save(sourceSnapshot, in: database)
                try CoverageRepository.save(
                    invalid,
                    attemptedAt: fixture.date,
                    expectedAccountID: fixture.accountID,
                    in: database
                )
            }
            XCTFail("Expected atomic coverage validation to fail.")
        } catch {
            XCTAssertEqual(error as? CoverageRepositoryError, .accountScopeMismatch)
        }

        let rawCount = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")
        }
        XCTAssertEqual(rawCount, 0)
    }

    func testSaveReplacesCoverageStateAndRestoresItFromTheVault() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let repository = CoverageRepository(vault: fixture.vault)
        let partial = fixture.record(status: .partial, lastSuccessfulAt: nil, failureDetail: "Interrupted.")
        let complete = fixture.record(status: .complete, lastSuccessfulAt: fixture.date, failureDetail: nil)

        try await repository.save(partial, attemptedAt: fixture.date)
        try await repository.save(complete, attemptedAt: fixture.date.addingTimeInterval(1))

        let records = try await repository.records(
            for: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(records, [complete])
        let count = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM coverage_records")
        }
        XCTAssertEqual(count, 1)
    }

    func testRemovingLegacyUnboundedRecordPreservesBoundedCoverageForTheStream() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = CoverageRepository(vault: fixture.vault)
        let unbounded = fixture.record(
            status: .partial,
            lastSuccessfulAt: nil,
            failureDetail: "Legacy attempt."
        )
        let bounded = CoverageRecord(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            repositoryID: nil,
            feature: .issues,
            streamID: fixture.streamID,
            intervalStart: fixture.date,
            intervalEnd: fixture.date.addingTimeInterval(3_600),
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision,
            status: .complete,
            lastSuccessfulAt: fixture.date.addingTimeInterval(3_600),
            failureDetail: nil
        )
        try await repository.save(unbounded, attemptedAt: fixture.date)
        try await repository.save(bounded, attemptedAt: fixture.date.addingTimeInterval(3_600))

        try await repository.removeUnboundedRecord(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            feature: .issues,
            streamID: fixture.streamID
        )

        let records = try await repository.records(
            for: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(records, [bounded])
    }

    func testCoverageIsStrictlyBoundToItsVaultAccount() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let repository = CoverageRepository(vault: fixture.vault)
        var record = fixture.record(status: .complete, lastSuccessfulAt: fixture.date, failureDetail: nil)
        record = CoverageRecord(
            accountID: AccountID.make(),
            organizationID: record.organizationID,
            repositoryID: record.repositoryID,
            feature: record.feature,
            streamID: record.streamID,
            intervalStart: record.intervalStart,
            intervalEnd: record.intervalEnd,
            credentialRevision: record.credentialRevision,
            capabilityRevision: record.capabilityRevision,
            status: record.status,
            lastSuccessfulAt: record.lastSuccessfulAt,
            failureDetail: record.failureDetail
        )

        do {
            try await repository.save(record)
            XCTFail("Expected an account scope mismatch.")
        } catch {
            XCTAssertEqual(error as? CoverageRepositoryError, .accountScopeMismatch)
        }

        do {
            _ = try await repository.records(for: record.accountID, organizationID: fixture.organizationID)
            XCTFail("Expected an account scope mismatch.")
        } catch {
            XCTAssertEqual(error as? CoverageRepositoryError, .accountScopeMismatch)
        }
    }

    func testStreamCannotBeRetargetedToADifferentFeature() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let repository = CoverageRepository(vault: fixture.vault)
        let record = fixture.record(status: .complete, lastSuccessfulAt: fixture.date, failureDetail: nil)
        try await repository.save(record)
        let conflictingRecord = CoverageRecord(
            accountID: record.accountID,
            organizationID: record.organizationID,
            repositoryID: record.repositoryID,
            feature: .pullRequests,
            streamID: record.streamID,
            intervalStart: record.intervalStart,
            intervalEnd: record.intervalEnd,
            credentialRevision: record.credentialRevision,
            capabilityRevision: record.capabilityRevision,
            status: .complete,
            lastSuccessfulAt: record.lastSuccessfulAt,
            failureDetail: nil
        )

        do {
            try await repository.save(conflictingRecord)
            XCTFail("Expected a stream scope mismatch.")
        } catch {
            XCTAssertEqual(error as? CoverageRepositoryError, .streamScopeMismatch)
        }
        let records = try await repository.records(
            for: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(records, [record])
    }

    func testFailedCoveragePreservesPriorSuccessfulWatermark() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let repository = CoverageRepository(vault: fixture.vault)
        let intervalStart = fixture.date
        let intervalEnd = fixture.date.addingTimeInterval(3_600)
        let successful = CoverageRecord(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            repositoryID: nil,
            feature: .issues,
            streamID: fixture.streamID,
            intervalStart: intervalStart,
            intervalEnd: intervalEnd,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision,
            status: .complete,
            lastSuccessfulAt: intervalEnd,
            failureDetail: nil
        )
        let failed = CoverageRecord(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            repositoryID: nil,
            feature: .issues,
            streamID: fixture.streamID,
            intervalStart: intervalStart,
            intervalEnd: intervalEnd,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision,
            status: .failed,
            lastSuccessfulAt: nil,
            failureDetail: "GitHub request failed."
        )

        try await repository.save(successful, attemptedAt: intervalEnd)
        try await repository.save(failed, attemptedAt: intervalEnd.addingTimeInterval(60))

        let records = try await repository.records(
            for: fixture.accountID,
            organizationID: fixture.organizationID
        )
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.lastSuccessfulAt, intervalEnd)
        let storedStream = try await SyncStreamRepository(vault: fixture.vault).stream(
            withID: fixture.streamID,
            accountID: fixture.accountID
        )
        let stream = try XCTUnwrap(storedStream)
        XCTAssertEqual(stream.highWater, intervalEnd)
        XCTAssertEqual(stream.lastSuccessfulAt, intervalEnd)
        XCTAssertEqual(stream.status, .failed)
    }

    func testFirstIncompleteCoverageDoesNotCreateAHighWater() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let end = fixture.date.addingTimeInterval(3_600)
        let partial = CoverageRecord(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            repositoryID: nil,
            feature: .issues,
            streamID: fixture.streamID,
            intervalStart: fixture.date,
            intervalEnd: end,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision,
            status: .partial,
            lastSuccessfulAt: nil,
            failureDetail: "Pagination remains incomplete."
        )

        try await CoverageRepository(vault: fixture.vault).save(partial, attemptedAt: end)

        let stream = try await SyncStreamRepository(vault: fixture.vault).stream(
            withID: fixture.streamID,
            accountID: fixture.accountID
        )
        XCTAssertNil(stream?.highWater)
        XCTAssertEqual(stream?.status, .partial)
    }

    func testCurrentRevisionCoverageReadFailsClosedAtItsBound() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await CoverageRepository(vault: fixture.vault).save(
            fixture.record(status: .complete, lastSuccessfulAt: fixture.date, failureDetail: nil)
        )
        let scope = SynchronizationScope(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision
        )

        do {
            _ = try await fixture.vault.read { database in
                try CoverageRepository.currentRecords(
                    for: scope,
                    in: database,
                    maximumCount: 0
                )
            }
            XCTFail("Current coverage must not materialize beyond its explicit bound.")
        } catch {
            XCTAssertEqual(error as? CoverageRepositoryError, .tooManyRecords)
        }
    }

    func testScopedFailureCoverageMatrixPersistsExactIdentityForEachFailureClass() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = CoverageRepository(vault: fixture.vault)
        let scope = SynchronizationScope(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision
        )
        let cases: [(name: String, error: any Error, expectedStatus: CoverageStatus)] = [
            ("permission", GitHubFailure(kind: .notFound, statusCode: 404), .unavailable),
            (
                "sso",
                OrganizationRefreshError.ssoRequirement(
                    .authorizationRequired(URL(string: "https://github.com/orgs/github/sso")!)
                ),
                .requiresSSO
            ),
            (
                "approval",
                GitHubFailure(
                    kind: .forbidden,
                    statusCode: 403,
                    accessRestriction: .organizationApprovalRequired
                ),
                .requiresApproval
            ),
            ("rate", GitHubFailure(kind: .rateLimited, statusCode: 429), .failed),
            ("malformed", GitHubRepositoryTeamClientError.invalidRepository, .failed),
            ("incomplete", GitHubRepositoryTeamClientError.partialResults, .partial)
        ]
        var expected = [String: CoverageRecord]()

        for entry in cases {
            let status = OrganizationInventoryRefreshService.coverageStatus(for: entry.error)
            XCTAssertEqual(status, entry.expectedStatus, "Unexpected coverage for \(entry.name).")
            let streamID = SyncStreamID(rawValue: "coverage-matrix-\(entry.name)")!
            let record = CoverageRecord(
                accountID: scope.accountID,
                organizationID: scope.organizationID,
                repositoryID: nil,
                feature: .repositories,
                streamID: streamID,
                intervalStart: fixture.date,
                intervalEnd: fixture.date.addingTimeInterval(60),
                credentialRevision: scope.credentialRevision,
                capabilityRevision: scope.capabilityRevision,
                status: status,
                lastSuccessfulAt: nil,
                failureDetail: "fixture-\(entry.name)"
            )
            try await repository.save(record, attemptedAt: fixture.date)
            expected[streamID.rawValue] = record
        }

        let persisted = try await repository.records(
            for: scope.accountID,
            organizationID: scope.organizationID
        )
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: persisted.map { ($0.streamID.rawValue, $0) }),
            expected
        )
    }

    private final class Fixture: @unchecked Sendable {
        let directory: URL
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: "github")!
        let streamID = SyncStreamID(rawValue: "issues-discovery")!
        let credentialRevision = CredentialRevision(rawValue: "credential-1")!
        let capabilityRevision = CapabilityRevision(rawValue: "capability-1")!
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let vault: AccountVault

        init() async throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            vault = try await VaultRegistry(rootDirectory: directory).open(
                accountID: accountID,
                vaultKey: try VaultKey.generate()
            )
            let account = GitHubAccount(
                id: accountID,
                githubUserID: 1,
                nodeID: GitHubNodeID(rawValue: "MDQ6VXNlcjE=")!,
                login: "octocat",
                authenticationKind: .oauth,
                credentialID: CredentialID.make(),
                credentialStatus: .active,
                createdAt: date,
                lastValidatedAt: date
            )
            let organization = GitHubOrganization(
                id: organizationID,
                githubOrganizationID: 2,
                nodeID: GitHubNodeID(rawValue: "MDEyOk9yZ2FuaXphdGlvbjE=")!,
                login: "github"
            )
            let access = OrganizationAccess(
                accountID: accountID,
                organizationID: organizationID,
                state: .available,
                capabilityRevision: capabilityRevision,
                capabilities: [],
                checkedAt: date
            )
            let repository = AccountRepository(vault: vault)
            try await repository.save(account, credentialRevision: credentialRevision)
            try await repository.save(organization, access: access, selectedAt: date)
        }

        func record(
            status: CoverageStatus,
            lastSuccessfulAt: Date?,
            failureDetail: String?
        ) -> CoverageRecord {
            CoverageRecord(
                accountID: accountID,
                organizationID: organizationID,
                repositoryID: nil,
                feature: .issues,
                streamID: streamID,
                intervalStart: nil,
                intervalEnd: nil,
                credentialRevision: credentialRevision,
                capabilityRevision: capabilityRevision,
                status: status,
                lastSuccessfulAt: lastSuccessfulAt,
                failureDetail: failureDetail
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
