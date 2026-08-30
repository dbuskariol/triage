import Foundation
import GRDB
import XCTest
@testable import Triage

final class OrganizationInventoryRefreshServiceTests: XCTestCase {
    func testRawRepositorySnapshotETagCannotAuthorizeConditionalRequest() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        try await fixture.seedRawRepositorySnapshot(eTag: "\"raw-only\"")
        let session = ScriptedInventorySession(responses: [
            .http(statusCode: 200, body: fixture.repositoryPayload())
        ])

        let repositories = try await fixture.service(session: session).refreshRepositories(
            account: fixture.account,
            organization: fixture.organization
        )

        XCTAssertEqual(repositories.map(\.name), ["repo"])
        let sentValidators = await session.validators()
        XCTAssertEqual(sentValidators, [nil])
    }

    func testRepositoryNotModifiedUsesCurrentScopedValidatorAndPreservesInventory() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let session = ScriptedInventorySession(responses: [
            .http(
                statusCode: 200,
                body: fixture.repositoryPayload(),
                headers: ["ETag": "\"repository-v1\""]
            ),
            .http(statusCode: 304, body: Data()),
            .http(
                statusCode: 200,
                body: fixture.repositoryPayload(),
                headers: ["ETag": "\"repository-v1\""]
            )
        ])

        _ = try await fixture.service(session: session).refreshRepositories(
            account: fixture.account,
            organization: fixture.organization
        )
        let repositories = try await fixture.service(
            session: session,
            now: fixture.observedAt.addingTimeInterval(1)
        ).refreshRepositories(
            account: fixture.account,
            organization: fixture.organization
        )

        XCTAssertEqual(repositories.map(\.name), ["repo"])
        let persistedRepositories = try await fixture.repositories()
        XCTAssertEqual(persistedRepositories.map(\.name), ["repo"])
        let sentValidators = await session.validators()
        XCTAssertEqual(sentValidators, [nil, "\"repository-v1\"", nil])
    }

    func testRepositoryLastModifiedFallbackIsPersistedAndReused() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let lastModified = "Wed, 21 Oct 2015 07:28:00 GMT"
        let session = ScriptedInventorySession(responses: [
            .http(
                statusCode: 200,
                body: fixture.repositoryPayload(),
                headers: ["Last-Modified": lastModified]
            ),
            .http(statusCode: 304, body: Data()),
            .http(
                statusCode: 200,
                body: fixture.repositoryPayload(),
                headers: ["Last-Modified": lastModified]
            )
        ])

        _ = try await fixture.service(session: session).refreshRepositories(
            account: fixture.account,
            organization: fixture.organization
        )
        let repositories = try await fixture.service(
            session: session,
            now: fixture.observedAt.addingTimeInterval(1)
        ).refreshRepositories(
            account: fixture.account,
            organization: fixture.organization
        )

        XCTAssertEqual(repositories.map(\.name), ["repo"])
        let eTags = await session.validators()
        let lastModifiedValues = await session.lastModifiedValidators()
        XCTAssertEqual(eTags, [nil, nil, nil])
        XCTAssertEqual(lastModifiedValues, [nil, lastModified, nil])
        let persisted = try await fixture.conditionalValidator(feature: .repositories)
        XCTAssertNil(persisted?.eTag)
        XCTAssertEqual(persisted?.lastModified, lastModified)
    }

    func testRepositoryPersistsBothValidatorsButSendsOnlyETag() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let lastModified = "Wed, 21 Oct 2015 07:28:00 GMT"
        let session = ScriptedInventorySession(responses: [
            .http(
                statusCode: 200,
                body: fixture.repositoryPayload(),
                headers: ["ETag": "\"repository-v1\"", "Last-Modified": lastModified]
            ),
            .http(statusCode: 304, body: Data()),
            .http(
                statusCode: 200,
                body: fixture.repositoryPayload(),
                headers: ["ETag": "\"repository-v1\"", "Last-Modified": lastModified]
            )
        ])

        _ = try await fixture.service(session: session).refreshRepositories(
            account: fixture.account,
            organization: fixture.organization
        )
        _ = try await fixture.service(
            session: session,
            now: fixture.observedAt.addingTimeInterval(1)
        ).refreshRepositories(
            account: fixture.account,
            organization: fixture.organization
        )

        let eTags = await session.validators()
        let lastModifiedValues = await session.lastModifiedValidators()
        XCTAssertEqual(eTags, [nil, "\"repository-v1\"", nil])
        XCTAssertEqual(lastModifiedValues, [nil, nil, nil])
        let persisted = try await fixture.conditionalValidator(feature: .repositories)
        XCTAssertEqual(persisted?.eTag, "\"repository-v1\"")
        XCTAssertEqual(persisted?.lastModified, lastModified)
    }

    func testFullReconciliationDoesNotSendCurrentRepositoryValidator() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let lastModified = "Wed, 21 Oct 2015 07:28:00 GMT"
        let session = ScriptedInventorySession(responses: [
            .http(
                statusCode: 200,
                body: fixture.repositoryPayload(),
                headers: ["Last-Modified": lastModified]
            ),
            .http(statusCode: 200, body: fixture.repositoryPayload())
        ])

        _ = try await fixture.service(session: session).refreshRepositories(
            account: fixture.account,
            organization: fixture.organization
        )
        _ = try await fixture.service(
            session: session,
            now: fixture.observedAt.addingTimeInterval(1)
        ).refreshRepositories(
            account: fixture.account,
            organization: fixture.organization,
            reconciliationIntent: .fullReconciliation
        )

        let eTags = await session.validators()
        let lastModifiedValues = await session.lastModifiedValidators()
        let persisted = try await fixture.conditionalValidator(feature: .repositories)
        XCTAssertEqual(eTags, [nil, nil])
        XCTAssertEqual(lastModifiedValues, [nil, nil])
        XCTAssertNil(persisted)
    }

    func testModifiedRepositoryInventoryPersistsExactRawAuthorityCoverageAndObservation() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let lastModified = "Wed, 21 Oct 2015 07:28:00 GMT"
        let session = ScriptedInventorySession(responses: [
            .http(
                statusCode: 200,
                body: fixture.repositoryPayload(),
                headers: ["ETag": "\"repository-v1\"", "Last-Modified": lastModified]
            )
        ])

        _ = try await fixture.service(session: session).refreshRepositories(
            account: fixture.account,
            organization: fixture.organization
        )

        let snapshots = try await fixture.rawSnapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].endpoint, fixture.repositoryEndpoint)
        XCTAssertEqual(snapshots[0].eTag, "\"repository-v1\"")
        XCTAssertEqual(snapshots[0].lastModified, lastModified)
        let scope = try await fixture.synchronizationScope()
        XCTAssertEqual(snapshots[0].requestIdentity?.scope, scope)
        XCTAssertEqual(snapshots[0].requestIdentity?.feature, .repositories)
        XCTAssertEqual(snapshots[0].requestIdentity?.streamID, fixture.repositoryInventoryStreamID)
        XCTAssertEqual(snapshots[0].requestIdentity?.requestKey, "GET \(fixture.repositoryEndpoint)")

        let coverage = try await fixture.coverageRecords(feature: .repositories)
        XCTAssertEqual(coverage.count, 2)
        XCTAssertEqual(coverage.map(\.streamID), [
            fixture.repositoryInventoryStreamID,
            fixture.repositoryInventoryStreamID
        ])
        XCTAssertEqual(coverage.first(where: { $0.repositoryID == nil })?.status, .complete)
        XCTAssertEqual(
            coverage.first(where: { $0.repositoryID == RepositoryID(rawValue: "R_1")! })?.status,
            .complete
        )

        let history = try await fixture.repositoryAccessHistory(repositoryID: "R_1")
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].source, .endpoint(fixture.repositoryEndpoint))
        XCTAssertEqual(history[0].sourceNodeID, GitHubNodeID(rawValue: "R_1")!)
        XCTAssertEqual(history[0].rawSnapshotID, snapshots[0].id)
        XCTAssertEqual(history[0].result, .accessible)
        XCTAssertEqual(history[0].reason, .directResponse)
        XCTAssertEqual(history[0].authority, .incremental)
        XCTAssertEqual(history[0].confirmation, .confirmed)
    }

    func testRepositoryOmissionRetainsTopologyAndRecordsUnknownAccessInOneAuthorityStream() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let session = ScriptedInventorySession(responses: [
            .http(statusCode: 200, body: fixture.repositoryPayload(includingSecond: true)),
            .http(statusCode: 200, body: fixture.repositoryPayload())
        ])

        _ = try await fixture.service(session: session).refreshRepositories(
            account: fixture.account,
            organization: fixture.organization
        )
        _ = try await fixture.service(
            session: session,
            now: fixture.observedAt.addingTimeInterval(1)
        ).refreshRepositories(
            account: fixture.account,
            organization: fixture.organization,
            reconciliationIntent: .fullReconciliation
        )

        let repositoryRowCount = try await fixture.repositoryRowCount()
        let returnedAccess = try await fixture.repositoryAccessState(repositoryID: "R_1")
        let omittedAccess = try await fixture.repositoryAccessState(repositoryID: "R_2")
        let visibleRepositoryIDs = try await fixture.repositories().map(\.id)
        XCTAssertEqual(repositoryRowCount, 2)
        XCTAssertEqual(returnedAccess, .available)
        XCTAssertEqual(omittedAccess, .unknown)
        XCTAssertEqual(visibleRepositoryIDs, [RepositoryID(rawValue: "R_1")!])

        let coverage = try await fixture.coverageRecords(feature: .repositories)
        XCTAssertEqual(coverage.count, 3)
        XCTAssertEqual(
            coverage.first(where: { $0.repositoryID == RepositoryID(rawValue: "R_1")! })?.status,
            .complete
        )
        XCTAssertEqual(
            coverage.first(where: { $0.repositoryID == RepositoryID(rawValue: "R_2")! })?.status,
            .unknown
        )
        XCTAssertTrue(coverage.allSatisfy { $0.streamID == fixture.repositoryInventoryStreamID })

        let returnedHistory = try await fixture.repositoryAccessHistory(repositoryID: "R_1")
        XCTAssertEqual(returnedHistory.map(\.result), [.accessible, .accessible])
        XCTAssertEqual(returnedHistory.first?.authority, .fullReconciliation)
        let omittedHistory = try await fixture.repositoryAccessHistory(repositoryID: "R_2")
        XCTAssertEqual(omittedHistory.map(\.result), [.unknown, .accessible])
        XCTAssertEqual(omittedHistory.first?.reason, .inventoryOmission)
        XCTAssertEqual(omittedHistory.first?.authority, .fullReconciliation)
        XCTAssertEqual(omittedHistory.first?.confirmation, .provisional)
        XCTAssertNil(omittedHistory.first?.sourceNodeID)
        XCTAssertNil(omittedHistory.first?.rawSnapshotID)
    }

    func testRepositoryNotModifiedRetryFailurePreservesNormalizedAndAccessEvidence() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let session = ScriptedInventorySession(responses: [
            .http(
                statusCode: 200,
                body: fixture.repositoryPayload(),
                headers: ["ETag": "\"repository-v1\""]
            ),
            .http(statusCode: 304, body: Data()),
            .http(statusCode: 500, body: Data(#"{"message":"unavailable"}"#.utf8))
        ])

        _ = try await fixture.service(session: session).refreshRepositories(
            account: fixture.account,
            organization: fixture.organization
        )
        do {
            _ = try await fixture.service(
                session: session,
                now: fixture.observedAt.addingTimeInterval(1)
            ).refreshRepositories(
                account: fixture.account,
                organization: fixture.organization
            )
            XCTFail("A failed unconditional retry must remain explicit.")
        } catch let failure as GitHubFailure {
            XCTAssertEqual(failure.kind, .serverFailure)
        }

        let repositoryRowCount = try await fixture.repositoryRowCount()
        let accessState = try await fixture.repositoryAccessState(repositoryID: "R_1")
        let snapshotCount = try await fixture.rawSnapshots().count
        let historyCount = try await fixture.repositoryAccessHistory(repositoryID: "R_1").count
        let coverageStatus = try await fixture.coverage(feature: .repositories).status
        let sentValidators = await session.validators()
        XCTAssertEqual(repositoryRowCount, 1)
        XCTAssertEqual(accessState, .available)
        XCTAssertEqual(snapshotCount, 1)
        XCTAssertEqual(historyCount, 1)
        XCTAssertEqual(coverageStatus, .failed)
        XCTAssertEqual(sentValidators, [nil, "\"repository-v1\"", nil])
    }

    func testRepositoryNotModifiedPartialResultsFailsPartialWithoutChangingAuthority() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let session = ScriptedInventorySession(responses: [
            .http(
                statusCode: 200,
                body: fixture.repositoryPayload(),
                headers: ["ETag": "\"repository-v1\""]
            ),
            .http(
                statusCode: 304,
                body: Data(),
                headers: ["X-GitHub-SSO": "partial-results; organizations=2"]
            )
        ])

        _ = try await fixture.service(session: session).refreshRepositories(
            account: fixture.account,
            organization: fixture.organization
        )
        do {
            _ = try await fixture.service(
                session: session,
                now: fixture.observedAt.addingTimeInterval(1)
            ).refreshRepositories(
                account: fixture.account,
                organization: fixture.organization
            )
            XCTFail("Selected-organization partial results must not reuse cached authority.")
        } catch let error as GitHubRepositoryTeamClientError {
            XCTAssertEqual(error, .partialResults)
        }

        let accessState = try await fixture.repositoryAccessState(repositoryID: "R_1")
        let historyCount = try await fixture.repositoryAccessHistory(repositoryID: "R_1").count
        let coverageStatus = try await fixture.coverage(feature: .repositories).status
        let sentValidators = await session.validators()
        XCTAssertEqual(accessState, .available)
        XCTAssertEqual(historyCount, 1)
        XCTAssertEqual(coverageStatus, .partial)
        XCTAssertEqual(sentValidators, [nil, "\"repository-v1\""])
    }

    func testIdenticalRepositoryRefreshAtSameMillisecondIsIdempotent() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let session = ScriptedInventorySession(responses: [
            .http(statusCode: 200, body: fixture.repositoryPayload()),
            .http(statusCode: 200, body: fixture.repositoryPayload())
        ])
        let service = try fixture.service(session: session)

        _ = try await service.refreshRepositories(
            account: fixture.account,
            organization: fixture.organization
        )
        _ = try await service.refreshRepositories(
            account: fixture.account,
            organization: fixture.organization
        )

        let snapshotCount = try await fixture.rawSnapshots().count
        let history = try await fixture.repositoryAccessHistory(repositoryID: "R_1")
        let coverage = try await fixture.coverageRecords(feature: .repositories)
        XCTAssertEqual(snapshotCount, 1)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.result, .accessible)
        XCTAssertEqual(coverage.count, 2)
        XCTAssertTrue(coverage.allSatisfy { $0.status == .complete })
    }

    func testDifferentRepositoryRevisionAtSameMillisecondFailsClosedAndPreservesFirstAuthority() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let session = ScriptedInventorySession(responses: [
            .http(
                statusCode: 200,
                body: fixture.repositoryPayload(),
                headers: ["ETag": "\"repository-v1\""]
            ),
            .http(
                statusCode: 200,
                body: fixture.renamedRepositoryPayload(),
                headers: ["ETag": "\"repository-v2\""]
            )
        ])
        let service = try fixture.service(session: session)

        _ = try await service.refreshRepositories(
            account: fixture.account,
            organization: fixture.organization
        )
        let firstRepositories = try await fixture.repositories()
        let firstSnapshots = try await fixture.rawSnapshots()
        let firstHistory = try await fixture.repositoryAccessHistory(repositoryID: "R_1")
        let firstValidator = try await fixture.conditionalValidator(feature: .repositories)

        do {
            _ = try await service.refreshRepositories(
                account: fixture.account,
                organization: fixture.organization
            )
            XCTFail("A different source revision at the same canonical millisecond must fail closed.")
        } catch let error as SourceAccessObservationRepositoryError {
            XCTAssertEqual(error, .conflictingObservation)
        }

        let preservedRepositories = try await fixture.repositories()
        let preservedSnapshots = try await fixture.rawSnapshots()
        let preservedHistory = try await fixture.repositoryAccessHistory(repositoryID: "R_1")
        let preservedValidator = try await fixture.conditionalValidator(feature: .repositories)
        let preservedAccess = try await fixture.repositoryAccessState(repositoryID: "R_1")
        XCTAssertEqual(firstRepositories, preservedRepositories)
        XCTAssertEqual(preservedRepositories.map(\.name), ["repo"])
        XCTAssertEqual(firstSnapshots, preservedSnapshots)
        XCTAssertEqual(firstHistory, preservedHistory)
        XCTAssertEqual(firstValidator, preservedValidator)
        XCTAssertEqual(preservedValidator?.eTag, "\"repository-v1\"")
        XCTAssertEqual(preservedAccess, .available)
    }

    func testEmptyThenNonemptyRepositoryRevisionAtSameMillisecondFailsClosed() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let session = ScriptedInventorySession(responses: [
            .http(
                statusCode: 200,
                body: Data("[]".utf8),
                headers: ["ETag": "\"repository-empty\""]
            ),
            .http(
                statusCode: 200,
                body: fixture.repositoryPayload(),
                headers: ["ETag": "\"repository-v1\""]
            )
        ])
        let service = try fixture.service(session: session)

        _ = try await service.refreshRepositories(
            account: fixture.account,
            organization: fixture.organization
        )
        let firstSnapshots = try await fixture.rawSnapshots()
        let firstCoverage = try await fixture.coverageRecords(feature: .repositories)
        let firstValidator = try await fixture.conditionalValidator(feature: .repositories)
        let firstRepositories = try await fixture.repositories()
        XCTAssertTrue(firstRepositories.isEmpty)

        do {
            _ = try await service.refreshRepositories(
                account: fixture.account,
                organization: fixture.organization
            )
            XCTFail("A nonempty aggregate cannot replace an empty aggregate at the same millisecond.")
        } catch let error as SourceAccessObservationRepositoryError {
            XCTAssertEqual(error, .conflictingObservation)
        }

        let preservedRepositories = try await fixture.repositories()
        let preservedSnapshots = try await fixture.rawSnapshots()
        let preservedCoverage = try await fixture.coverageRecords(feature: .repositories)
        let preservedValidator = try await fixture.conditionalValidator(feature: .repositories)
        XCTAssertTrue(preservedRepositories.isEmpty)
        XCTAssertEqual(preservedSnapshots, firstSnapshots)
        XCTAssertEqual(firstCoverage.count, 1)
        XCTAssertEqual(firstCoverage.first?.status, .complete)
        XCTAssertEqual(preservedCoverage.count, 1)
        XCTAssertEqual(preservedCoverage.first?.status, .failed)
        XCTAssertEqual(
            preservedCoverage.first?.lastSuccessfulAt,
            firstCoverage.first?.lastSuccessfulAt
        )
        XCTAssertEqual(preservedValidator, firstValidator)
        XCTAssertEqual(firstValidator?.eTag, "\"repository-empty\"")
    }

    func testOlderEmptyRepositoryRevisionCannotReplaceNewerEmptyAuthority() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let session = ScriptedInventorySession(responses: [
            .http(
                statusCode: 200,
                body: Data("[]".utf8),
                headers: ["ETag": "\"repository-newer\""]
            ),
            .http(
                statusCode: 200,
                body: Data("[]".utf8),
                headers: ["ETag": "\"repository-older\""]
            )
        ])

        _ = try await fixture.service(
            session: session,
            now: fixture.observedAt.addingTimeInterval(1)
        ).refreshRepositories(
            account: fixture.account,
            organization: fixture.organization
        )
        let firstSnapshots = try await fixture.rawSnapshots()
        let firstCoverage = try await fixture.coverageRecords(feature: .repositories)
        let firstValidator = try await fixture.conditionalValidator(feature: .repositories)

        do {
            _ = try await fixture.service(
                session: session,
                now: fixture.observedAt
            ).refreshRepositories(
                account: fixture.account,
                organization: fixture.organization
            )
            XCTFail("An older empty aggregate cannot replace newer empty authority.")
        } catch let error as SourceAccessObservationRepositoryError {
            XCTAssertEqual(error, .staleObservation)
        }

        let preservedRepositories = try await fixture.repositories()
        let preservedSnapshots = try await fixture.rawSnapshots()
        let preservedCoverage = try await fixture.coverageRecords(feature: .repositories)
        let preservedValidator = try await fixture.conditionalValidator(feature: .repositories)
        XCTAssertTrue(preservedRepositories.isEmpty)
        XCTAssertEqual(preservedSnapshots, firstSnapshots)
        XCTAssertEqual(firstCoverage.count, 1)
        XCTAssertEqual(firstCoverage.first?.status, .complete)
        XCTAssertEqual(preservedCoverage.count, 1)
        XCTAssertEqual(preservedCoverage.first?.status, .failed)
        XCTAssertEqual(
            preservedCoverage.first?.lastSuccessfulAt,
            firstCoverage.first?.lastSuccessfulAt
        )
        XCTAssertEqual(preservedValidator, firstValidator)
        XCTAssertEqual(preservedValidator?.eTag, "\"repository-newer\"")
    }

    func testImmutableRepositoryIdentityCollisionRollsBackModifiedResponseTransaction() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let session = ScriptedInventorySession(responses: [
            .http(
                statusCode: 200,
                body: fixture.repositoryPayload(),
                headers: ["ETag": "\"repository-v1\""]
            ),
            .http(
                statusCode: 200,
                body: fixture.repositoryPayloadWithChangedNumericIdentity(),
                headers: ["ETag": "\"repository-v2\""]
            )
        ])

        _ = try await fixture.service(session: session).refreshRepositories(
            account: fixture.account,
            organization: fixture.organization
        )
        let firstIdentity = try await fixture.persistedRepositoryIdentity(nodeID: "R_1")
        let firstSnapshots = try await fixture.rawSnapshots()
        let firstHistory = try await fixture.repositoryAccessHistory(repositoryID: "R_1")
        let firstCoverage = try await fixture.coverageRecords(feature: .repositories)
        let firstValidator = try await fixture.conditionalValidator(feature: .repositories)

        do {
            _ = try await fixture.service(
                session: session,
                now: fixture.observedAt.addingTimeInterval(1)
            ).refreshRepositories(
                account: fixture.account,
                organization: fixture.organization
            )
            XCTFail("An immutable identity collision must abort the modified-response transaction.")
        } catch let error as RepositoryInventoryRepositoryError {
            XCTAssertEqual(error, .immutableIdentityConflict)
        }

        let preservedIdentity = try await fixture.persistedRepositoryIdentity(nodeID: "R_1")
        let preservedSnapshots = try await fixture.rawSnapshots()
        let preservedHistory = try await fixture.repositoryAccessHistory(repositoryID: "R_1")
        let preservedCoverage = try await fixture.coverageRecords(feature: .repositories)
        let preservedValidator = try await fixture.conditionalValidator(feature: .repositories)
        let preservedAccess = try await fixture.repositoryAccessState(repositoryID: "R_1")
        XCTAssertEqual(firstIdentity, preservedIdentity)
        XCTAssertEqual(preservedIdentity, ["R_1", "1", "R_1", "repo"])
        XCTAssertEqual(firstSnapshots, preservedSnapshots)
        XCTAssertEqual(firstHistory, preservedHistory)
        XCTAssertEqual(firstValidator, preservedValidator)
        XCTAssertEqual(preservedAccess, .available)
        XCTAssertEqual(firstCoverage.count, preservedCoverage.count)
        let firstLeafCoverage = firstCoverage.first { $0.repositoryID != nil }
        let preservedLeafCoverage = preservedCoverage.first { $0.repositoryID != nil }
        let firstRootCoverage = firstCoverage.first { $0.repositoryID == nil }
        let preservedRootCoverage = preservedCoverage.first { $0.repositoryID == nil }
        XCTAssertEqual(firstLeafCoverage, preservedLeafCoverage)
        XCTAssertEqual(preservedRootCoverage?.status, .failed)
        XCTAssertEqual(
            preservedRootCoverage?.lastSuccessfulAt,
            firstRootCoverage?.lastSuccessfulAt
        )
    }

    func testTwoPageRepositoryObservationsBindExactContainingPageInRootAuthorityStream() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let secondEndpoint =
            "/orgs/acme/repos?type=all&per_page=100&page=2"
        let nextLink = "<https://api.github.com\(secondEndpoint)>; rel=\"next\""
        let session = ScriptedInventorySession(responses: [
            .http(
                statusCode: 200,
                body: fixture.repositoryPayload(),
                headers: ["Link": nextLink, "ETag": "\"repository-root\""]
            ),
            .http(
                statusCode: 200,
                body: fixture.secondRepositoryPayload(),
                headers: ["ETag": "\"repository-page-2\""]
            )
        ])

        _ = try await fixture.service(session: session).refreshRepositories(
            account: fixture.account,
            organization: fixture.organization
        )

        let snapshots = try await fixture.rawSnapshots()
        let snapshotsByEndpoint = Dictionary(uniqueKeysWithValues: snapshots.map {
            ($0.endpoint, $0)
        })
        let firstHistory = try await fixture.repositoryAccessHistory(repositoryID: "R_1")
        let secondHistory = try await fixture.repositoryAccessHistory(repositoryID: "R_2")
        let coverage = try await fixture.coverageRecords(feature: .repositories)
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(firstHistory.count, 1)
        XCTAssertEqual(secondHistory.count, 1)
        XCTAssertEqual(firstHistory[0].source, .endpoint(fixture.repositoryEndpoint))
        XCTAssertEqual(firstHistory[0].rawSnapshotID, snapshotsByEndpoint[fixture.repositoryEndpoint]?.id)
        XCTAssertEqual(secondHistory[0].source, .endpoint(secondEndpoint))
        XCTAssertEqual(secondHistory[0].rawSnapshotID, snapshotsByEndpoint[secondEndpoint]?.id)
        XCTAssertEqual(firstHistory[0].sourceRevision, secondHistory[0].sourceRevision)
        XCTAssertEqual(firstHistory[0].streamID, fixture.repositoryInventoryStreamID)
        XCTAssertEqual(secondHistory[0].streamID, fixture.repositoryInventoryStreamID)
        XCTAssertTrue(snapshots.allSatisfy {
            $0.requestIdentity?.streamID == fixture.repositoryInventoryStreamID
        })
        XCTAssertTrue(coverage.allSatisfy {
            $0.streamID == fixture.repositoryInventoryStreamID
        })
    }

    func testRepositoryValidatorIsCurrentRevisionScopedAndRotatesWithoutReuse() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let session = ScriptedInventorySession(responses: [
            .http(
                statusCode: 200,
                body: fixture.repositoryPayload(),
                headers: ["ETag": "\"repository-v1\""]
            ),
            .http(
                statusCode: 200,
                body: fixture.repositoryPayload(),
                headers: ["ETag": "\"repository-v2\""]
            )
        ])
        let service = try fixture.service(session: session)

        _ = try await service.refreshRepositories(
            account: fixture.account,
            organization: fixture.organization
        )
        try await fixture.replaceCredentialRevision(with: "credential-2")
        _ = try await service.refreshRepositories(
            account: fixture.account,
            organization: fixture.organization
        )

        let sentValidators = await session.validators()
        XCTAssertEqual(sentValidators, [nil, nil])
        let persisted = try await fixture.vault.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT credential_revision, capability_revision, etag
                    FROM conditional_request_cache
                    """
            ).map { row in
                (
                    row["credential_revision"] as String,
                    row["capability_revision"] as String,
                    row["etag"] as String
                )
            }
        }
        XCTAssertEqual(persisted.map(\.0), ["credential-2"])
        XCTAssertEqual(persisted.map(\.1), ["capability-1"])
        XCTAssertEqual(persisted.map(\.2), ["\"repository-v2\""])
    }

    func testTeamNotModifiedUsesOnlyItsScopedValidatorAndPreservesMembership() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let lastModified = "Wed, 21 Oct 2015 07:28:00 GMT"
        let session = ScriptedInventorySession(responses: [
            .http(statusCode: 200, body: Data("[]".utf8)),
            .http(
                statusCode: 200,
                body: fixture.teamPayload(),
                headers: ["ETag": "\"teams-v1\"", "Last-Modified": lastModified]
            ),
            .http(statusCode: 200, body: fixture.activeMembershipPayload()),
            .http(statusCode: 200, body: Data("[]".utf8)),
            .http(statusCode: 304, body: Data()),
            .http(statusCode: 200, body: fixture.activeMembershipPayload())
        ])
        let service = try fixture.service(session: session)

        _ = try await service.refreshInventory(
            account: fixture.account,
            organization: fixture.organization
        )
        let second = try await service.refreshInventory(
            account: fixture.account,
            organization: fixture.organization
        )

        guard case let .success(teams, coverage) = second.teams else {
            return XCTFail("A scoped team 304 should reuse committed normalized inventory.")
        }
        XCTAssertEqual(teams.map(\.id), [TeamID(rawValue: "T_1")!])
        XCTAssertEqual(teams.first?.membershipState, "active")
        XCTAssertEqual(coverage.status, .complete)
        let sentValidators = await session.validators()
        let sentLastModified = await session.lastModifiedValidators()
        XCTAssertEqual(sentValidators, [nil, nil, nil, nil, "\"teams-v1\"", nil])
        XCTAssertEqual(sentLastModified, [nil, nil, nil, nil, nil, nil])
        let persisted = try await fixture.conditionalValidator(feature: .teams)
        XCTAssertEqual(persisted?.eTag, "\"teams-v1\"")
        XCTAssertEqual(persisted?.lastModified, lastModified)
    }

    func testRepositorySuccessSurvivesIndependentTeamFailure() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let session = ScriptedInventorySession(responses: [
            .http(statusCode: 200, body: fixture.repositoryPayload()),
            .http(
                statusCode: 403,
                body: Data(#"{"message":"forbidden"}"#.utf8),
                headers: ["X-GitHub-SSO": "partial-results; organizations=999"]
            )
        ])
        let service = try fixture.service(session: session)

        let result = try await service.refreshInventory(
            account: fixture.account,
            organization: fixture.organization
        )

        guard case let .success(summaries, repositoryCoverage) = result.repositories else {
            return XCTFail("Repository inventory should succeed.")
        }
        XCTAssertEqual(summaries.map(\.name), ["repo"])
        XCTAssertEqual(repositoryCoverage.status, .complete)
        let persistedRepositoryCoverage = try await fixture.coverage(feature: .repositories)
        XCTAssertEqual(repositoryCoverage, persistedRepositoryCoverage)

        guard case let .failure(classification, teamCoverage) = result.teams else {
            return XCTFail("Team inventory should return its own failure outcome.")
        }
        XCTAssertEqual(classification, .unavailableOrPermission)
        XCTAssertEqual(teamCoverage.status, .unavailable)
        let repositories = try await fixture.repositories()
        let paths = await session.paths()
        XCTAssertEqual(repositories.map(\.name), ["repo"])
        XCTAssertEqual(paths, ["/orgs/acme/repos", "/orgs/acme/teams"])
    }

    func testRepositoryFailureStillAttemptsSuccessfulTeamsWithoutFabricatingRepositories() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let session = ScriptedInventorySession(responses: [
            .http(statusCode: 500, body: Data(#"{"message":"unavailable"}"#.utf8)),
            .http(statusCode: 200, body: Data("[]".utf8))
        ])
        let service = try fixture.service(session: session)

        let result = try await service.refreshInventory(
            account: fixture.account,
            organization: fixture.organization
        )

        guard case let .failure(classification, coverage) = result.repositories else {
            return XCTFail("Repository failure must remain explicit.")
        }
        XCTAssertEqual(classification, .failed)
        XCTAssertEqual(coverage.status, .failed)
        let repositories = try await fixture.repositories()
        XCTAssertTrue(repositories.isEmpty)

        guard case let .success(teams, teamCoverage) = result.teams else {
            return XCTFail("Teams should still be attempted after repository failure.")
        }
        XCTAssertTrue(teams.isEmpty)
        XCTAssertEqual(teamCoverage.status, .complete)
        let paths = await session.paths()
        XCTAssertEqual(paths, ["/orgs/acme/repos", "/orgs/acme/teams"])
    }

    func testRepositorySSOFailureReturnsScopedTransientRecoveryAndStillCommitsTeams() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let recoveryURL = URL(string: "https://github.com/orgs/acme/sso-inventory-recovery")!
        let session = ScriptedInventorySession(responses: [
            .http(
                statusCode: 403,
                body: Data(#"{"message":"SSO required"}"#.utf8),
                headers: ["X-GitHub-SSO": "required; url=\(recoveryURL.absoluteString)"]
            ),
            .http(statusCode: 200, body: Data("[]".utf8))
        ])

        let result = try await fixture.service(session: session).refreshInventory(
            account: fixture.account,
            organization: fixture.organization
        )

        guard case let .failure(.ssoRequired(header), repositoryCoverage) = result.repositories else {
            return XCTFail("Repository SSO must retain its selected-organization recovery header in memory.")
        }
        XCTAssertEqual(header, .authorizationRequired(recoveryURL))
        XCTAssertEqual(repositoryCoverage.status, .requiresSSO)
        XCTAssertNil(repositoryCoverage.intervalStart)
        XCTAssertNil(repositoryCoverage.intervalEnd)
        XCTAssertFalse(repositoryCoverage.failureDetail?.contains(recoveryURL.absoluteString) == true)
        guard case let .success(teams, teamCoverage) = result.teams else {
            return XCTFail("An independent team refresh should still succeed.")
        }
        XCTAssertTrue(teams.isEmpty)
        XCTAssertEqual(teamCoverage.status, .complete)
    }

    func testUnknownTeamMembershipRetainsPriorMembershipAndReturnsPartialOutcome() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        try await fixture.seedActiveTeamMembership()
        let session = ScriptedInventorySession(responses: [
            .http(statusCode: 200, body: Data("[]".utf8)),
            .http(statusCode: 200, body: fixture.changedTeamPayload()),
            .http(statusCode: 404, body: Data(#"{"message":"hidden"}"#.utf8))
        ])
        let service = try fixture.service(session: session)

        let result = try await service.refreshInventory(
            account: fixture.account,
            organization: fixture.organization
        )

        guard case let .failure(classification, coverage) = result.teams else {
            return XCTFail("Hidden team membership must not be treated as authoritative non-membership.")
        }
        XCTAssertEqual(classification, .partial)
        XCTAssertEqual(coverage.status, .partial)
        let teams = try await fixture.teams()
        XCTAssertEqual(teams.map(\.id), [TeamID(rawValue: "T_1")!])
        XCTAssertEqual(teams.map(\.name), ["Triage"])
        XCTAssertEqual(teams.first?.membershipState, "active")
    }

    func testCancellationDuringTeamRefreshPropagatesAfterRepositoryCommit() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let session = ScriptedInventorySession(responses: [
            .http(statusCode: 200, body: fixture.repositoryPayload()),
            .cancellation
        ])
        let service = try fixture.service(session: session)

        do {
            _ = try await service.refreshInventory(
                account: fixture.account,
                organization: fixture.organization
            )
            XCTFail("Cancellation must propagate instead of becoming a stream failure outcome.")
        } catch is CancellationError {
            // Expected.
        }

        let repositories = try await fixture.repositories()
        let repositoryCoverage = try await fixture.coverage(feature: .repositories)
        let paths = await session.paths()
        XCTAssertEqual(repositories.map(\.name), ["repo"])
        XCTAssertEqual(repositoryCoverage.status, .complete)
        XCTAssertEqual(paths, ["/orgs/acme/repos", "/orgs/acme/teams"])
    }

    func testRepositoryCancellationDoesNotStartTeams() async throws {
        let fixture = try await OrganizationInventoryFixture()
        defer { fixture.remove() }
        let session = ScriptedInventorySession(responses: [
            .httpAndCancel(statusCode: 200, body: fixture.repositoryPayload())
        ])
        let service = try fixture.service(session: session)

        do {
            _ = try await service.refreshInventory(
                account: fixture.account,
                organization: fixture.organization
            )
            XCTFail("Cancellation must propagate.")
        } catch is CancellationError {
            // Expected.
        }

        let paths = await session.paths()
        let repositories = try await fixture.repositories()
        let coverage = try await fixture.coverage(feature: .repositories)
        XCTAssertEqual(paths, ["/orgs/acme/repos"])
        XCTAssertTrue(repositories.isEmpty)
        XCTAssertEqual(coverage.status, .partial)
        XCTAssertNil(coverage.intervalStart)
        XCTAssertNil(coverage.intervalEnd)
    }
}

private extension OrganizationInventoryRefreshService {
    func refreshRepositories(
        account: GitHubAccount,
        organization: GitHubOrganization
    ) async throws -> [RepositorySummary] {
        try await refreshRepositories(
            account: account,
            organization: organization,
            reconciliationIntent: .incremental
        )
    }

    func refreshInventory(
        account: GitHubAccount,
        organization: GitHubOrganization
    ) async throws -> OrganizationInventoryRefreshResult {
        try await refreshInventory(
            account: account,
            organization: organization,
            reconciliationIntent: .incremental
        )
    }
}

private final class OrganizationInventoryFixture: @unchecked Sendable {
    let root: URL
    let registry: VaultRegistry
    let vaultKey: VaultKey
    let vault: AccountVault
    let account: GitHubAccount
    let organization: GitHubOrganization
    let observedAt = Date(timeIntervalSinceReferenceDate: 10_000)

    var repositoryEndpoint: String {
        "/orgs/\(organization.login)/repos?type=all&per_page=100"
    }

    var repositoryInventoryStreamID: SyncStreamID {
        SyncStreamID(rawValue: "inventory-repositories-\(organization.id.rawValue)")!
    }

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".triage-organization-inventory-\(UUID().uuidString)", isDirectory: true)
        registry = try VaultRegistry(rootDirectory: root)
        vaultKey = try VaultKey.generate()
        let accountID = AccountID.make()
        vault = try await registry.open(accountID: accountID, vaultKey: vaultKey)
        account = GitHubAccount(
            id: accountID,
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
        let accountRepository = AccountRepository(vault: vault)
        try await accountRepository.save(
            account,
            credentialRevision: CredentialRevision(rawValue: "credential-1")!
        )
        try await accountRepository.save(
            organization,
            access: OrganizationAccess(
                accountID: account.id,
                organizationID: organization.id,
                state: .available,
                capabilityRevision: CapabilityRevision(rawValue: "capability-1")!,
                capabilities: [],
                checkedAt: observedAt
            )
        )
    }

    func service(
        session: ScriptedInventorySession,
        now: Date? = nil
    ) throws -> OrganizationInventoryRefreshService {
        let client = GitHubRepositoryTeamClient(
            client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: session),
                credential: SecretValue("test-token")
            )
        )
        return OrganizationInventoryRefreshService(
            vaultRegistry: registry,
            vaultKeyReader: { _ in self.vaultKey },
            repositoryTeamClientFactory: { _, _, _ in client },
            clock: { now ?? self.observedAt }
        )
    }

    func conditionalValidator(feature: CoverageFeature) async throws -> ConditionalRequestValidator? {
        let streamID = SyncStreamID(
            rawValue: "inventory-\(feature.rawValue)-\(organization.id.rawValue)"
        )!
        let requestKey: String
        switch feature {
        case .repositories:
            requestKey = "GET /orgs/\(organization.login)/repos?type=all&per_page=100"
        case .teams:
            requestKey = "GET /orgs/\(organization.login)/teams?per_page=100"
        default:
            throw OrganizationInventoryFixtureError.unsupportedFeature
        }
        return try await ConditionalRequestCacheRepository(vault: vault).validator(
            for: ConditionalRequestIdentity(
                scope: SynchronizationScope(
                    accountID: account.id,
                    organizationID: organization.id,
                    credentialRevision: CredentialRevision(rawValue: "credential-1")!,
                    capabilityRevision: CapabilityRevision(rawValue: "capability-1")!
                ),
                feature: feature,
                streamID: streamID,
                requestKey: requestKey
            )
        )
    }

    func repositories() async throws -> [RepositorySummary] {
        try await RepositoryInventoryRepository(vault: vault).repositories(
            accountID: account.id,
            organization: organization
        )
    }

    func synchronizationScope() async throws -> SynchronizationScope {
        try await AccountRepository(vault: vault).synchronizationScope(
            for: account.id,
            organizationID: organization.id
        )
    }

    func rawSnapshots() async throws -> [RawAPISnapshot] {
        try await RawAPISnapshotRepository(vault: vault).snapshots(for: account.id)
    }

    func coverageRecords(feature: CoverageFeature) async throws -> [CoverageRecord] {
        try await CoverageRepository(vault: vault).records(
            for: account.id,
            organizationID: organization.id
        ).filter { $0.feature == feature }
    }

    func repositoryAccessHistory(repositoryID rawValue: String) async throws -> [SourceAccessObservation] {
        let repositoryID = RepositoryID(rawValue: rawValue)!
        return try await SourceAccessObservationRepository(vault: vault).history(
            for: .repository(repositoryID),
            feature: .repositories,
            streamID: repositoryInventoryStreamID,
            scope: try await synchronizationScope()
        )
    }

    func repositoryRowCount() async throws -> Int {
        try await vault.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM repositories WHERE organization_id = ?",
                arguments: [organization.id.rawValue]
            ) ?? 0
        }
    }

    func repositoryAccessState(repositoryID rawValue: String) async throws -> RepositoryAccessState? {
        try await vault.read { database in
            let value = try String.fetchOne(
                database,
                sql: """
                    SELECT access_state FROM account_repository_access
                    WHERE account_id = ? AND repository_id = ?
                    """,
                arguments: [account.id.rawValue, rawValue]
            )
            return value.flatMap(RepositoryAccessState.init(rawValue:))
        }
    }

    func persistedRepositoryIdentity(nodeID: String) async throws -> [String]? {
        try await vault.read { database in
            try Row.fetchOne(
                database,
                sql: """
                    SELECT id, github_repository_id, github_node_id, name
                    FROM repositories
                    WHERE github_node_id = ? AND organization_id = ?
                    """,
                arguments: [nodeID, organization.id.rawValue]
            ).map { row in
                [
                    row["id"] as String,
                    row["github_repository_id"] as String,
                    row["github_node_id"] as String,
                    row["name"] as String
                ]
            }
        }
    }

    func teams() async throws -> [TeamInventorySummary] {
        try await TeamInventoryRepository(vault: vault).teams(
            accountID: account.id,
            organization: organization
        )
    }

    func coverage(feature: CoverageFeature) async throws -> CoverageRecord {
        guard let coverage = try await CoverageRepository(vault: vault).records(
            for: account.id,
            organizationID: organization.id
        ).first(where: { $0.feature == feature }) else {
            throw OrganizationInventoryFixtureError.missingCoverage
        }
        return coverage
    }

    func seedActiveTeamMembership() async throws {
        let response = GitHubResponse(
            value: GitHubTeamMembershipDTO(state: "active", role: "member"),
            payload: Data(#"{"state":"active","role":"member"}"#.utf8),
            etag: nil,
            lastModified: nil,
            ssoHeader: nil
        )
        _ = try await TeamInventoryRepository(vault: vault).replace(
            teams: [team()],
            memberships: [
                TeamMembershipObservation(
                    teamID: TeamID(rawValue: "T_1")!,
                    membership: .member(response)
                )
            ],
            accountID: account.id,
            organization: organization,
            observedAt: observedAt
        )
    }

    func replaceCredentialRevision(with rawValue: String) async throws {
        try await AccountRepository(vault: vault).save(
            account,
            credentialRevision: CredentialRevision(rawValue: rawValue)!
        )
    }

    func seedRawRepositorySnapshot(eTag: String) async throws {
        try await RawAPISnapshotRepository(vault: vault).save(
            RawAPISnapshot(
                id: RawAPISnapshotID.make(),
                accountID: account.id,
                githubNodeID: nil,
                endpoint: "/orgs/\(organization.login)/repos?type=all&per_page=100",
                eTag: eTag,
                parserVersion: 1,
                observedAt: observedAt,
                payload: repositoryPayload()
            )
        )
    }

    func repositoryPayload() -> Data {
        Data(
            #"[{"id":1,"node_id":"R_1","name":"repo","private":true,"archived":false,"has_discussions":true,"html_url":"https://github.com/acme/repo","updated_at":"2026-01-01T00:00:00Z","owner":{"login":"acme"}}]"#.utf8
        )
    }

    func repositoryPayload(includingSecond: Bool) -> Data {
        guard includingSecond else { return repositoryPayload() }
        return Data(
            #"[{"id":1,"node_id":"R_1","name":"repo","private":true,"archived":false,"has_discussions":true,"html_url":"https://github.com/acme/repo","updated_at":"2026-01-01T00:00:00Z","owner":{"login":"acme"}},{"id":2,"node_id":"R_2","name":"second","private":true,"archived":false,"has_discussions":false,"html_url":"https://github.com/acme/second","updated_at":"2026-01-02T00:00:00Z","owner":{"login":"acme"}}]"#.utf8
        )
    }

    func renamedRepositoryPayload() -> Data {
        Data(
            #"[{"id":1,"node_id":"R_1","name":"renamed","private":true,"archived":false,"has_discussions":true,"html_url":"https://github.com/acme/renamed","updated_at":"2026-01-02T00:00:00Z","owner":{"login":"acme"}}]"#.utf8
        )
    }

    func repositoryPayloadWithChangedNumericIdentity() -> Data {
        Data(
            #"[{"id":2,"node_id":"R_1","name":"repo","private":true,"archived":false,"has_discussions":true,"html_url":"https://github.com/acme/repo","updated_at":"2026-01-02T00:00:00Z","owner":{"login":"acme"}}]"#.utf8
        )
    }

    func secondRepositoryPayload() -> Data {
        Data(
            #"[{"id":2,"node_id":"R_2","name":"second","private":true,"archived":false,"has_discussions":false,"html_url":"https://github.com/acme/second","updated_at":"2026-01-02T00:00:00Z","owner":{"login":"acme"}}]"#.utf8
        )
    }

    func teamPayload() -> Data {
        Data(#"[{"id":1,"node_id":"T_1","name":"Triage","slug":"triage","privacy":"closed"}]"#.utf8)
    }

    func changedTeamPayload() -> Data {
        Data(#"[{"id":2,"node_id":"T_2","name":"Replacement","slug":"replacement","privacy":"closed"}]"#.utf8)
    }

    func activeMembershipPayload() -> Data {
        Data(#"{"state":"active","role":"member"}"#.utf8)
    }

    func team() -> GitHubTeamDTO {
        GitHubTeamDTO(id: 1, nodeID: "T_1", name: "Triage", slug: "triage", privacy: "closed")
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum OrganizationInventoryFixtureError: Error {
    case missingCoverage
    case unsupportedFeature
}

private actor ScriptedInventorySession: HTTPSession {
    enum Response: Sendable {
        case http(statusCode: Int, body: Data, headers: [String: String] = [:])
        case httpAndCancel(statusCode: Int, body: Data, headers: [String: String] = [:])
        case cancellation
    }

    private var responses: [Response]
    private var requestedPaths = [String]()
    private var requestedValidators = [String?]()
    private var requestedLastModifiedValidators = [String?]()

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestedPaths.append(request.url!.path)
        requestedValidators.append(request.value(forHTTPHeaderField: "If-None-Match"))
        requestedLastModifiedValidators.append(
            request.value(forHTTPHeaderField: "If-Modified-Since")
        )
        guard !responses.isEmpty else {
            throw GitHubTransportError.unexpectedResponse
        }
        switch responses.removeFirst() {
        case let .http(statusCode, body, headers):
            return (
                body,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: headers
                )!
            )
        case let .httpAndCancel(statusCode, body, headers):
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return (
                body,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: headers
                )!
            )
        case .cancellation:
            throw CancellationError()
        }
    }

    func paths() -> [String] {
        requestedPaths
    }

    func validators() -> [String?] {
        requestedValidators
    }

    func lastModifiedValidators() -> [String?] {
        requestedLastModifiedValidators
    }
}
