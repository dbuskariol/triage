import Foundation
import GRDB
import XCTest
@testable import Triage

final class TimelineEventRepositoryTests: XCTestCase {
    func testValidatedRawPagePromotionRollsBackWhenCheckpointIsInvalid() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let repository = TimelineEventRepository(vault: fixture.vault)
        let page = GitHubPage<GitHubTimelineEventDTO>(
            values: [],
            payload: Data("[]".utf8),
            nextPageURL: nil,
            etag: "page-etag",
            lastModified: nil,
            ssoHeader: nil
        )
        let snapshotID = try await repository.saveRawPage(
            page,
            candidate: fixture.candidate,
            pageIndex: 1,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt
        )
        let invalidNextPage = URL(
            string: "https://api.github.com/repos/github/other/issues/1/timeline?page=2"
        )!

        do {
            try await repository.commitValidatedRawPage(
                snapshotID,
                candidate: fixture.candidate,
                pageIndex: 1,
                nextPageURL: invalidNextPage,
                accountID: fixture.accountID,
                organizationID: fixture.organizationID,
                attemptedAt: fixture.observedAt
            )
            XCTFail("Expected invalid checkpoint rollback.")
        } catch let error as TimelineCandidateRepositoryError {
            XCTAssertEqual(error, .invalidCheckpoint)
        }

        let state = try await fixture.vault.read { database in
            (
                try String.fetchOne(database, sql: "SELECT endpoint FROM raw_api_snapshots WHERE id = ?", arguments: [snapshotID.rawValue]),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sync_shards"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sync_streams")
            )
        }
        XCTAssertTrue(try XCTUnwrap(state.0).contains("pending:001"))
        XCTAssertEqual(state.1, 0)
        XCTAssertEqual(state.2, 0)
    }

    func testNormalizedReplacementAndCompletionShareOneTransaction() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let repository = TimelineEventRepository(vault: fixture.vault)
        try await repository.replace(
            [fixture.event(id: "old-event", payload: #"{"event":"assigned"}"#)],
            candidate: fixture.candidate,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt
        )
        let page = GitHubPage<GitHubTimelineEventDTO>(
            values: [],
            payload: Data("[]".utf8),
            nextPageURL: nil,
            etag: nil,
            lastModified: nil,
            ssoHeader: nil
        )
        let snapshotID = try await repository.saveRawPage(
            page,
            candidate: fixture.candidate,
            pageIndex: 1,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt
        )
        try await repository.commitValidatedRawPage(
            snapshotID,
            candidate: fixture.candidate,
            pageIndex: 1,
            nextPageURL: nil,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            attemptedAt: fixture.observedAt
        )
        try await fixture.vault.write { database in
            try database.execute(sql: """
                CREATE TRIGGER reject_timeline_completion
                BEFORE UPDATE ON sync_shards
                WHEN NEW.state = 'completed'
                BEGIN
                    SELECT RAISE(ABORT, 'injected completion failure');
                END
                """)
        }

        do {
            try await repository.replaceAndComplete(
                [fixture.event(id: "new-event", payload: #"{"event":"mentioned"}"#)],
                candidate: fixture.candidate,
                accountID: fixture.accountID,
                organizationID: fixture.organizationID,
                observedAt: fixture.observedAt.addingTimeInterval(1)
            )
            XCTFail("Expected injected completion failure.")
        } catch is DatabaseError {
        }
        let rolledBack = try await fixture.vault.read { database in
            (
                try String.fetchAll(database, sql: "SELECT github_event_id FROM timeline_events"),
                try String.fetchOne(database, sql: "SELECT state FROM sync_shards"),
                try String.fetchOne(database, sql: "SELECT state FROM sync_streams")
            )
        }
        XCTAssertEqual(rolledBack.0, ["old-event"])
        XCTAssertEqual(rolledBack.1, SyncShardState.running.rawValue)
        XCTAssertEqual(rolledBack.2, CoverageStatus.partial.rawValue)

        try await fixture.vault.write { database in
            try database.execute(sql: "DROP TRIGGER reject_timeline_completion")
        }
        try await repository.replaceAndComplete(
            [fixture.event(id: "new-event", payload: #"{"event":"mentioned"}"#)],
            candidate: fixture.candidate,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt.addingTimeInterval(1)
        )
        let completed = try await fixture.vault.read { database in
            (
                try String.fetchAll(database, sql: "SELECT github_event_id FROM timeline_events"),
                try String.fetchOne(database, sql: "SELECT state FROM sync_shards"),
                try String.fetchOne(database, sql: "SELECT state FROM sync_streams")
            )
        }
        XCTAssertEqual(completed.0, ["new-event"])
        XCTAssertEqual(completed.1, SyncShardState.completed.rawValue)
        XCTAssertEqual(completed.2, CoverageStatus.complete.rawValue)
    }

    func testOutcomeClassificationPreservesScopedSSOApprovalPolicyAndRetryTime() throws {
        let observedAt = Date(timeIntervalSince1970: 1_767_225_600)
        let authorizationURL = try XCTUnwrap(URL(string: "https://github.com/orgs/github/sso"))

        XCTAssertEqual(
            GitHubTimelineRefreshService.status(
                for: GitHubFailure(
                    kind: .forbidden,
                    statusCode: 403,
                    ssoHeader: .authorizationRequired(authorizationURL)
                ),
                githubOrganizationID: 2,
                observedAt: observedAt
            ),
            .ssoRequired(.authorizationRequired(authorizationURL))
        )
        XCTAssertEqual(
            GitHubTimelineRefreshService.status(
                for: GitHubFailure(
                    kind: .forbidden,
                    statusCode: 403,
                    accessRestriction: .oauthApplicationApprovalRequired
                ),
                githubOrganizationID: 2,
                observedAt: observedAt
            ),
            .approvalRequired
        )
        XCTAssertEqual(
            GitHubTimelineRefreshService.status(
                for: GitHubFailure(
                    kind: .forbidden,
                    statusCode: 403,
                    accessRestriction: .organizationPolicyBlocked
                ),
                githubOrganizationID: 2,
                observedAt: observedAt
            ),
            .unavailableOrPermission
        )
        XCTAssertEqual(
            GitHubTimelineRefreshService.status(
                for: GitHubFailure(
                    kind: .secondaryRateLimited,
                    statusCode: 403,
                    retryAfter: 120
                ),
                githubOrganizationID: 2,
                observedAt: observedAt
            ),
            .rateLimited(retryAt: observedAt.addingTimeInterval(120))
        )
    }

    func testCoverageAssessmentKeepsRepositoryScopeIndependentAndConservative() throws {
        let repositoryOne = RepositoryID(rawValue: "repo-1")!
        let repositoryTwo = RepositoryID(rawValue: "repo-2")!
        let result = GitHubTimelineRefreshResult(
            outcomes: [
                GitHubTimelineRefreshOutcome(
                    nodeID: GitHubNodeID(rawValue: "I_1")!,
                    repositoryID: repositoryOne,
                    number: 1,
                    status: .refreshed
                ),
                GitHubTimelineRefreshOutcome(
                    nodeID: GitHubNodeID(rawValue: "I_2")!,
                    repositoryID: repositoryTwo,
                    number: 2,
                    status: .failed
                )
            ],
            hasRemainingCandidates: false,
            hasBudgetContinuation: false
        )

        XCTAssertEqual(result.coverageAssessment.status, .failed)
        XCTAssertEqual(result.coverageAssessment(for: repositoryOne).status, .complete)
        XCTAssertEqual(result.coverageAssessment(for: repositoryTwo).status, .failed)
        XCTAssertEqual(
            result.coverageAssessment(for: RepositoryID(rawValue: "repo-with-no-candidates")!).status,
            .complete
        )

        let boundedResult = GitHubTimelineRefreshResult(
            outcomes: result.outcomes,
            hasRemainingCandidates: true,
            hasBudgetContinuation: false
        )
        XCTAssertEqual(boundedResult.coverageAssessment(for: repositoryOne).status, .partial)
        XCTAssertEqual(
            boundedResult.coverageAssessment(for: RepositoryID(rawValue: "repo-with-no-candidates")!).status,
            .partial
        )
    }

    func testAggregatePageBudgetDefersAtCheckpointWithoutFetchingNextPage() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let secondPage = URL(
            string: "https://api.github.com/repos/github/triage/issues/1/timeline?page=2"
        )!
        let service = GitHubTimelineRefreshService(
            client: GitHubTimelineClient(client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: TimelineRefreshSession(responses: [
                    "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (
                        Data(#"[{"id":"new-event","event":"mentioned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8),
                        ["Link": "<\(secondPage)>; rel=\"next\""]
                    )
                ])),
                credential: SecretValue("token")
            )),
            candidateRepository: TimelineCandidateRepository(vault: fixture.vault),
            eventRepository: TimelineEventRepository(vault: fixture.vault),
            normalizationFailureRepository: NormalizationFailureRepository(vault: fixture.vault),
            conditionalRequestCacheRepository: ConditionalRequestCacheRepository(vault: fixture.vault)
        )

        let result = try await service.refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            budget: TimelineRefreshBudget(maximumPages: 1, maximumDecodedBytes: 1_024),
            observedAt: fixture.observedAt
        )

        XCTAssertEqual(result.outcomes.map(\.status), [.deferredByBudget])
        XCTAssertTrue(result.hasBudgetContinuation)
        XCTAssertTrue(result.hasContinuation)
        XCTAssertEqual(result.coverageAssessment.status, .partial)
        let state = try await fixture.vault.read { database in
            (
                try String.fetchOne(database, sql: "SELECT page_cursor FROM sync_shards"),
                try String.fetchOne(database, sql: "SELECT state FROM sync_streams"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM timeline_events")
            )
        }
        XCTAssertEqual(state.0, secondPage.absoluteString)
        XCTAssertEqual(state.1, CoverageStatus.partial.rawValue)
        XCTAssertEqual(state.2, 1)
        XCTAssertEqual(state.3, 0)
    }

    func testScopedPartialResultsPreservePriorTimelineAndRetainPendingRawResponse() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let eventRepository = TimelineEventRepository(vault: fixture.vault)
        try await eventRepository.replace(
            [fixture.event(id: "old-event", payload: #"{"event":"assigned"}"#)],
            candidate: fixture.candidate,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt
        )
        let service = GitHubTimelineRefreshService(
            client: GitHubTimelineClient(client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: TimelineRefreshSession(responses: [
                    "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (
                        Data(#"[{"id":"new-event","event":"mentioned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8),
                        ["X-GitHub-SSO": "partial-results; organizations=2"]
                    )
                ])),
                credential: SecretValue("token")
            )),
            candidateRepository: TimelineCandidateRepository(vault: fixture.vault),
            eventRepository: eventRepository,
            normalizationFailureRepository: NormalizationFailureRepository(vault: fixture.vault),
            conditionalRequestCacheRepository: ConditionalRequestCacheRepository(vault: fixture.vault)
        )

        let result = try await service.refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt
        )

        XCTAssertEqual(result.outcomes.map(\.status), [.ssoRequired(.partialResults([2]))])
        let state = try await fixture.vault.read { database in
            (
                try String.fetchAll(
                    database,
                    sql: "SELECT github_event_id FROM timeline_events ORDER BY github_event_id"
                ),
                try String.fetchOne(database, sql: "SELECT endpoint FROM raw_api_snapshots"),
                try String.fetchOne(database, sql: "SELECT state FROM sync_streams")
            )
        }
        XCTAssertEqual(state.0, ["old-event"])
        XCTAssertTrue(try XCTUnwrap(state.1).contains("pending:001"))
        XCTAssertEqual(state.2, CoverageStatus.partial.rawValue)
    }

    func testCrossPageDuplicateDoesNotPoisonCorrectedRetry() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let secondPage = URL(
            string: "https://api.github.com/repos/github/triage/issues/1/timeline?page=2"
        )!
        let eventRepository = TimelineEventRepository(vault: fixture.vault)
        let duplicatePayload = Data(
            #"[{"id":"duplicate","event":"mentioned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8
        )
        let service = GitHubTimelineRefreshService(
            client: GitHubTimelineClient(client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: TimelineRefreshSession(responses: [
                    "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (
                        duplicatePayload,
                        ["Link": "<\(secondPage)>; rel=\"next\""]
                    ),
                    "/repos/github/triage/issues/1/timeline?page=2": (duplicatePayload, [:])
                ])),
                credential: SecretValue("token")
            )),
            candidateRepository: TimelineCandidateRepository(vault: fixture.vault),
            eventRepository: eventRepository,
            normalizationFailureRepository: NormalizationFailureRepository(vault: fixture.vault),
            conditionalRequestCacheRepository: ConditionalRequestCacheRepository(vault: fixture.vault)
        )

        let failed = try await service.refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt
        )
        XCTAssertEqual(failed.outcomes.map(\.status), [.failed])
        let failures = try await NormalizationFailureRepository(vault: fixture.vault)
            .failures(for: fixture.accountID)
        XCTAssertTrue(failures.isEmpty)

        let recoveredService = GitHubTimelineRefreshService(
            client: GitHubTimelineClient(client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: TimelineRefreshSession(responses: [
                    "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (
                        duplicatePayload,
                        ["Link": "<\(secondPage)>; rel=\"next\""]
                    ),
                    "/repos/github/triage/issues/1/timeline?page=2": (
                        Data(#"[{"id":"corrected","event":"mentioned","created_at":"2026-01-02T00:00:00Z"}]"#.utf8),
                        [:]
                    )
                ])),
                credential: SecretValue("token")
            )),
            candidateRepository: TimelineCandidateRepository(vault: fixture.vault),
            eventRepository: eventRepository,
            normalizationFailureRepository: NormalizationFailureRepository(vault: fixture.vault),
            conditionalRequestCacheRepository: ConditionalRequestCacheRepository(vault: fixture.vault)
        )
        let recovered = try await recoveredService.refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt.addingTimeInterval(1)
        )

        XCTAssertEqual(recovered.outcomes.map(\.status), [.refreshed])
        let eventIDs = try await fixture.vault.read { database in
            try String.fetchAll(database, sql: "SELECT github_event_id FROM timeline_events ORDER BY github_event_id")
        }
        XCTAssertEqual(eventIDs, ["corrected", "duplicate"])
    }

    func testPageLevelNotModifiedIsFollowedByUnconditionalAuthoritativeTraversal() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        try await CoverageRepository(vault: fixture.vault).save(
            CoverageRecord(
                accountID: fixture.scope.accountID,
                organizationID: fixture.scope.organizationID,
                repositoryID: fixture.repositoryID,
                feature: .timelines,
                streamID: fixture.timelineStreamID,
                intervalStart: nil,
                intervalEnd: nil,
                credentialRevision: fixture.scope.credentialRevision,
                capabilityRevision: fixture.scope.capabilityRevision,
                status: .partial,
                lastSuccessfulAt: nil,
                failureDetail: nil
            ),
            attemptedAt: fixture.observedAt
        )
        try await ConditionalRequestCacheRepository(vault: fixture.vault).save(
            ConditionalRequestValidator(
                identity: fixture.conditionalRequestIdentity,
                eTag: "old-etag",
                lastModified: nil,
                observedAt: fixture.observedAt
            )
        )
        let session = ConditionalTimelineSession()
        let service = GitHubTimelineRefreshService(
            client: GitHubTimelineClient(client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: session),
                credential: SecretValue("token")
            )),
            candidateRepository: TimelineCandidateRepository(vault: fixture.vault),
            eventRepository: TimelineEventRepository(vault: fixture.vault),
            normalizationFailureRepository: NormalizationFailureRepository(vault: fixture.vault),
            conditionalRequestCacheRepository: ConditionalRequestCacheRepository(vault: fixture.vault)
        )

        let result = try await service.refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt
        )

        XCTAssertEqual(result.outcomes.map(\.status), [.refreshed])
        let receivedValidators = await session.receivedValidators()
        XCTAssertEqual(receivedValidators, ["old-etag", nil])
        let eventIDs = try await fixture.vault.read { database in
            try String.fetchAll(database, sql: "SELECT github_event_id FROM timeline_events")
        }
        XCTAssertEqual(eventIDs, ["authoritative-event"])
    }

    func testLastModifiedNotModifiedRetriesUnconditionallyAndPersistsFreshValidatorPair() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        try await CoverageRepository(vault: fixture.vault).save(
            CoverageRecord(
                accountID: fixture.scope.accountID,
                organizationID: fixture.scope.organizationID,
                repositoryID: fixture.repositoryID,
                feature: .timelines,
                streamID: fixture.timelineStreamID,
                intervalStart: nil,
                intervalEnd: nil,
                credentialRevision: fixture.scope.credentialRevision,
                capabilityRevision: fixture.scope.capabilityRevision,
                status: .partial,
                lastSuccessfulAt: nil,
                failureDetail: nil
            ),
            attemptedAt: fixture.observedAt
        )
        let oldLastModified = "Wed, 21 Oct 2015 07:28:00 GMT"
        let conditionalRequests = ConditionalRequestCacheRepository(vault: fixture.vault)
        try await conditionalRequests.save(
            ConditionalRequestValidator(
                identity: fixture.conditionalRequestIdentity,
                eTag: nil,
                lastModified: oldLastModified,
                observedAt: fixture.observedAt
            )
        )
        let session = ConditionalTimelineSession()
        let service = GitHubTimelineRefreshService(
            client: GitHubTimelineClient(client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: session),
                credential: SecretValue("token")
            )),
            candidateRepository: TimelineCandidateRepository(vault: fixture.vault),
            eventRepository: TimelineEventRepository(vault: fixture.vault),
            normalizationFailureRepository: NormalizationFailureRepository(vault: fixture.vault),
            conditionalRequestCacheRepository: conditionalRequests
        )

        let result = try await service.refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt.addingTimeInterval(1)
        )

        XCTAssertEqual(result.outcomes.map(\.status), [.refreshed])
        let receivedETags = await session.receivedValidators()
        let receivedLastModified = await session.receivedLastModifiedValidators()
        XCTAssertEqual(receivedETags, [nil, nil])
        XCTAssertEqual(receivedLastModified, [oldLastModified, nil])
        let persisted = try await conditionalRequests.validator(
            for: fixture.conditionalRequestIdentity
        )
        XCTAssertEqual(persisted?.eTag, "new-etag")
        XCTAssertEqual(persisted?.lastModified, "Thu, 22 Oct 2015 07:28:00 GMT")
    }

    func testFreshTimelineWithoutETagAtomicallyRemovesPriorValidator() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        try await CoverageRepository(vault: fixture.vault).save(
            CoverageRecord(
                accountID: fixture.scope.accountID,
                organizationID: fixture.scope.organizationID,
                repositoryID: fixture.repositoryID,
                feature: .timelines,
                streamID: fixture.timelineStreamID,
                intervalStart: nil,
                intervalEnd: nil,
                credentialRevision: fixture.scope.credentialRevision,
                capabilityRevision: fixture.scope.capabilityRevision,
                status: .partial,
                lastSuccessfulAt: nil,
                failureDetail: nil
            ),
            attemptedAt: fixture.observedAt
        )
        let conditionalRequests = ConditionalRequestCacheRepository(vault: fixture.vault)
        try await conditionalRequests.save(
            ConditionalRequestValidator(
                identity: fixture.conditionalRequestIdentity,
                eTag: "old-etag",
                lastModified: nil,
                observedAt: fixture.observedAt
            )
        )
        let service = GitHubTimelineRefreshService(
            client: GitHubTimelineClient(client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: TimelineRefreshSession(responses: [
                    "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (
                        Data(#"[{"id":"fresh-event","event":"mentioned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8),
                        [:]
                    )
                ])),
                credential: SecretValue("token")
            )),
            candidateRepository: TimelineCandidateRepository(vault: fixture.vault),
            eventRepository: TimelineEventRepository(vault: fixture.vault),
            normalizationFailureRepository: NormalizationFailureRepository(vault: fixture.vault),
            conditionalRequestCacheRepository: conditionalRequests
        )

        let result = try await service.refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt.addingTimeInterval(1)
        )

        XCTAssertEqual(result.outcomes.map(\.status), [.refreshed])
        let retainedValidator = try await conditionalRequests.validator(
            for: fixture.conditionalRequestIdentity
        )
        XCTAssertNil(retainedValidator)
        let eventIDs = try await fixture.vault.read { database in
            try String.fetchAll(database, sql: "SELECT github_event_id FROM timeline_events")
        }
        XCTAssertEqual(eventIDs, ["fresh-event"])
    }

    func testUndecodableTransportPayloadIsRetainedWithRedactedFailure() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let eventRepository = TimelineEventRepository(vault: fixture.vault)
        try await eventRepository.replace(
            [fixture.event(id: "old-event", payload: #"{"event":"assigned"}"#)],
            candidate: fixture.candidate,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt
        )
        let privatePayload = Data(#"[{"token":"ghp_privateMalformedTimeline""#.utf8)
        let service = GitHubTimelineRefreshService(
            client: GitHubTimelineClient(client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: TimelineRefreshSession(responses: [
                    "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (
                        privatePayload,
                        ["ETag": "malformed-etag"]
                    )
                ])),
                credential: SecretValue("token")
            )),
            candidateRepository: TimelineCandidateRepository(vault: fixture.vault),
            eventRepository: eventRepository,
            normalizationFailureRepository: NormalizationFailureRepository(vault: fixture.vault),
            conditionalRequestCacheRepository: ConditionalRequestCacheRepository(vault: fixture.vault)
        )

        let result = try await service.refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt
        )

        XCTAssertEqual(result.outcomes.map(\.status), [.failed])
        let persisted = try await fixture.vault.read { database in
            (
                try String.fetchAll(database, sql: "SELECT github_event_id FROM timeline_events"),
                try String.fetchOne(database, sql: "SELECT endpoint FROM raw_api_snapshots"),
                try Data.fetchOne(database, sql: "SELECT payload FROM raw_api_snapshots"),
                try String.fetchOne(database, sql: "SELECT state FROM sync_streams")
            )
        }
        XCTAssertEqual(persisted.0, ["old-event"])
        XCTAssertTrue(try XCTUnwrap(persisted.1).contains("pending:001"))
        XCTAssertEqual(persisted.2, privatePayload)
        XCTAssertEqual(persisted.3, CoverageStatus.partial.rawValue)

        let failures = try await NormalizationFailureRepository(vault: fixture.vault)
            .failures(for: fixture.accountID)
        let failure = try XCTUnwrap(failures.first)
        XCTAssertEqual(failure.githubNodeID, fixture.nodeID)
        XCTAssertEqual(failure.endpoint, "GET /repos/github/triage/issues/1/timeline")
        XCTAssertFalse(failure.redactedDiagnostic.contains("ghp_privateMalformedTimeline"))
        XCTAssertFalse(failure.redactedDiagnostic.contains("malformed-etag"))
    }

    func testMalformedLaterPagePreservesExistingTimelineEvents() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let eventRepository = TimelineEventRepository(vault: fixture.vault)
        try await eventRepository.replace(
            [fixture.event(id: "old-event", payload: #"{"event":"assigned"}"#)],
            candidate: fixture.candidate,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt
        )
        let secondPage = URL(
            string: "https://api.github.com/repos/github/triage/issues/1/timeline?page=2"
        )!
        let restClient = GitHubRESTClient(
            transport: try GitHubRESTTransport(session: TimelineRefreshSession(responses: [
                "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (
                    Data(#"[{"id":"new-event","event":"mentioned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8),
                    ["Link": "<\(secondPage)>; rel=\"next\""]
                ),
                "/repos/github/triage/issues/1/timeline?page=2": (
                    Data(#"[{"id":"new-final","event":"mentioned","token":"ghp_rawTimelineSecret"}]"#.utf8),
                    [:]
                )
            ])),
            credential: SecretValue("token")
        )
        let service = GitHubTimelineRefreshService(
            client: GitHubTimelineClient(client: restClient),
            candidateRepository: TimelineCandidateRepository(vault: fixture.vault),
            eventRepository: eventRepository,
            normalizationFailureRepository: NormalizationFailureRepository(vault: fixture.vault),
            conditionalRequestCacheRepository: ConditionalRequestCacheRepository(vault: fixture.vault)
        )

        let result = try await service.refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt
        )

        XCTAssertEqual(result.refreshedTimelineNodeIDs, [])
        XCTAssertEqual(result.incompleteTimelineNodeIDs, [fixture.nodeID])
        let persistedEventIDs = try await fixture.vault.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT github_event_id FROM timeline_events WHERE subject_node_id = ?",
                arguments: [fixture.nodeID.rawValue]
            )
        }
        XCTAssertEqual(persistedEventIDs, ["old-event"])
        let rawSnapshots = try await RawAPISnapshotRepository(vault: fixture.vault).snapshots(
            for: fixture.accountID
        )
        let retainedRawSnapshot = try XCTUnwrap(
            rawSnapshots.first { $0.payload.contains(Data("ghp_rawTimelineSecret".utf8)) }
        )
        let failures = try await NormalizationFailureRepository(vault: fixture.vault).failures(
            for: fixture.accountID
        )
        let failure = try XCTUnwrap(failures.first)
        XCTAssertEqual(failure.rawSnapshotID, retainedRawSnapshot.id)
        XCTAssertEqual(failure.githubNodeID, fixture.nodeID)
        XCTAssertEqual(failure.endpoint, "GET /repos/github/triage/issues/1/timeline")
        XCTAssertEqual(retainedRawSnapshot.accountID, fixture.accountID)
        XCTAssertEqual(retainedRawSnapshot.githubNodeID, fixture.nodeID)
        XCTAssertTrue(retainedRawSnapshot.endpoint.contains("/repos/github/triage/issues/1/timeline"))
        XCTAssertFalse(failure.redactedDiagnostic.contains("ghp_rawTimelineSecret"))
        XCTAssertFalse(failure.redactedDiagnostic.contains("new-final"))
        XCTAssertFalse(failure.redactedDiagnostic.contains("https://"))

        let recoveredService = GitHubTimelineRefreshService(
            client: GitHubTimelineClient(client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: TimelineRefreshSession(responses: [
                    "/repos/github/triage/issues/1/timeline?page=2": (
                        Data(#"[{"id":"new-final","event":"mentioned","created_at":"2026-01-02T00:00:00Z"}]"#.utf8),
                        [:]
                    )
                ])),
                credential: SecretValue("token")
            )),
            candidateRepository: TimelineCandidateRepository(vault: fixture.vault),
            eventRepository: eventRepository,
            normalizationFailureRepository: NormalizationFailureRepository(vault: fixture.vault),
            conditionalRequestCacheRepository: ConditionalRequestCacheRepository(vault: fixture.vault)
        )
        let recovered = try await recoveredService.refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt
        )
        XCTAssertEqual(recovered.refreshedTimelineNodeIDs, [fixture.nodeID])
        let recoveredEventIDs = try await fixture.vault.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT github_event_id FROM timeline_events ORDER BY github_event_id"
            )
        }
        XCTAssertEqual(recoveredEventIDs, ["new-event", "new-final"])
        let retainedFailureSnapshot = try await RawAPISnapshotRepository(vault: fixture.vault).snapshots(
            for: fixture.accountID
        )
        XCTAssertTrue(
            retainedFailureSnapshot.contains { $0.id == retainedRawSnapshot.id && $0.payload.contains(Data("ghp_rawTimelineSecret".utf8)) }
        )
    }

    func testCrossRepositoryLinkPreservesTimelineAndLeavesCoverageIncomplete() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let eventRepository = TimelineEventRepository(vault: fixture.vault)
        try await eventRepository.replace(
            [fixture.event(id: "old-event", payload: #"{"event":"assigned"}"#)],
            candidate: fixture.candidate,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt
        )
        let restClient = GitHubRESTClient(
            transport: try GitHubRESTTransport(session: TimelineRefreshSession(responses: [
                "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (
                    Data(#"[{"id":"new-event","event":"mentioned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8),
                    [
                        "Link": "<https://api.github.com/repos/github/other/issues/1/timeline?page=2>; rel=\"next\""
                    ]
                )
            ])),
            credential: SecretValue("token")
        )
        let service = GitHubTimelineRefreshService(
            client: GitHubTimelineClient(client: restClient),
            candidateRepository: TimelineCandidateRepository(vault: fixture.vault),
            eventRepository: eventRepository,
            normalizationFailureRepository: NormalizationFailureRepository(vault: fixture.vault),
            conditionalRequestCacheRepository: ConditionalRequestCacheRepository(vault: fixture.vault)
        )

        let result = try await service.refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt
        )

        XCTAssertEqual(result.incompleteTimelineNodeIDs, [fixture.nodeID])
        let state = try await fixture.vault.read { database in
            (
                try String.fetchOne(database, sql: "SELECT github_event_id FROM timeline_events"),
                try String.fetchOne(database, sql: "SELECT state FROM sync_streams")
            )
        }
        XCTAssertEqual(state.0, "old-event")
        XCTAssertEqual(state.1, CoverageStatus.partial.rawValue)
    }

    func testDecodedByteBudgetDeferralStillRetainsFetchedRawProvenance() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let payload = Data(
            #"[{"id":"new-event","event":"mentioned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8
        )
        let service = GitHubTimelineRefreshService(
            client: GitHubTimelineClient(client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: TimelineRefreshSession(responses: [
                    "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (payload, [:])
                ])),
                credential: SecretValue("token")
            )),
            candidateRepository: TimelineCandidateRepository(vault: fixture.vault),
            eventRepository: TimelineEventRepository(vault: fixture.vault),
            normalizationFailureRepository: NormalizationFailureRepository(vault: fixture.vault),
            conditionalRequestCacheRepository: ConditionalRequestCacheRepository(vault: fixture.vault)
        )

        let result = try await service.refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            budget: TimelineRefreshBudget(maximumPages: 1, maximumDecodedBytes: 1),
            observedAt: fixture.observedAt
        )

        XCTAssertEqual(result.outcomes.map(\.status), [.deferredByBudget])
        let state = try await fixture.vault.read { database in
            (
                try String.fetchOne(database, sql: "SELECT endpoint FROM raw_api_snapshots"),
                try Data.fetchOne(database, sql: "SELECT payload FROM raw_api_snapshots"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM timeline_events")
            )
        }
        XCTAssertTrue(try XCTUnwrap(state.0).contains("pending:001"))
        XCTAssertEqual(state.1, payload)
        XCTAssertEqual(state.2, 0)
    }

    func testMalformedTerminalLinkPreservesTimelineAndDoesNotComplete() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let eventRepository = TimelineEventRepository(vault: fixture.vault)
        try await eventRepository.replace(
            [fixture.event(id: "old-event", payload: #"{"event":"assigned"}"#)],
            candidate: fixture.candidate,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt
        )
        let service = GitHubTimelineRefreshService(
            client: GitHubTimelineClient(client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: TimelineRefreshSession(responses: [
                    "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (
                        Data(#"[{"id":"new-event","event":"mentioned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8),
                        ["Link": "not a valid Link header"]
                    )
                ])),
                credential: SecretValue("token")
            )),
            candidateRepository: TimelineCandidateRepository(vault: fixture.vault),
            eventRepository: eventRepository,
            normalizationFailureRepository: NormalizationFailureRepository(vault: fixture.vault),
            conditionalRequestCacheRepository: ConditionalRequestCacheRepository(vault: fixture.vault)
        )

        let result = try await service.refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt
        )

        XCTAssertEqual(result.refreshedTimelineNodeIDs, [])
        XCTAssertEqual(result.incompleteTimelineNodeIDs, [fixture.nodeID])
        let state = try await fixture.vault.read { database in
            (
                try String.fetchOne(database, sql: "SELECT github_event_id FROM timeline_events"),
                try String.fetchOne(database, sql: "SELECT state FROM sync_streams")
            )
        }
        XCTAssertEqual(state.0, "old-event")
        XCTAssertEqual(state.1, CoverageStatus.partial.rawValue)
    }

    func testCancellationAfterSinglePageDoesNotCompleteTimeline() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let eventRepository = TimelineEventRepository(vault: fixture.vault)
        try await eventRepository.replace(
            [fixture.event(id: "old-event", payload: #"{"event":"assigned"}"#)],
            candidate: fixture.candidate,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt
        )
        let service = GitHubTimelineRefreshService(
            client: GitHubTimelineClient(client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: CancellingTimelineSession()),
                credential: SecretValue("token")
            )),
            candidateRepository: TimelineCandidateRepository(vault: fixture.vault),
            eventRepository: eventRepository,
            normalizationFailureRepository: NormalizationFailureRepository(vault: fixture.vault),
            conditionalRequestCacheRepository: ConditionalRequestCacheRepository(vault: fixture.vault)
        )
        let refreshTask = Task {
            try await service.refresh(
                scope: fixture.scope,
                githubOrganizationID: 2,
                currentUserID: ActorID(rawValue: "U_current")!,
                candidates: [fixture.candidate],
                observedAt: fixture.observedAt
            )
        }

        do {
            _ = try await refreshTask.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
        }

        let state = try await fixture.vault.read { database in
            (
                try String.fetchOne(database, sql: "SELECT github_event_id FROM timeline_events"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sync_streams"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM normalization_failures")
            )
        }
        XCTAssertEqual(state.0, "old-event")
        XCTAssertEqual(state.1, 0)
        XCTAssertEqual(state.2, 0)
    }
}

private final class TimelineFixture: @unchecked Sendable {
    let directory: URL
    let accountID = AccountID.make()
    let organizationID = OrganizationID(rawValue: "github")!
    let repositoryID = RepositoryID(rawValue: "repo-1")!
    let nodeID = GitHubNodeID(rawValue: "I_1")!
    let observedAt = Date(timeIntervalSince1970: 1_767_225_600)
    let vault: AccountVault
    let candidate: TimelineCandidate

    var scope: SynchronizationScope {
        SynchronizationScope(
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: CredentialRevision(rawValue: "credential-1")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-1")!
        )
    }

    var timelineStreamID: SyncStreamID {
        SyncStreamID(rawValue: "timeline:\(nodeID.rawValue)")!
    }

    var conditionalRequestIdentity: ConditionalRequestIdentity {
        ConditionalRequestIdentity(
            scope: scope,
            feature: .timelines,
            streamID: timelineStreamID,
            requestKey: "GET /repos/github/triage/issues/1/timeline?per_page=100&page=1"
        )
    }

    init() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".timeline-event-test-\(UUID().uuidString)", isDirectory: true)
        vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        let fixtureAccountID = accountID
        let fixtureOrganizationID = organizationID
        let fixtureRepositoryID = repositoryID
        let fixtureNodeID = nodeID
        let observedAtMilliseconds = Int64((observedAt.timeIntervalSince1970 * 1_000).rounded())
        try await vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO accounts (
                        id, github_user_id, github_node_id, login, display_name, avatar_url,
                        authentication_kind, credential_id, credential_status, credential_revision,
                        created_at_ms, last_validated_at_ms, disabled_at_ms
                    ) VALUES (?, '1', 'U_account', 'octocat', NULL, NULL, 'oauth', 'credential', 'active',
                              'credential-1', ?, ?, NULL)
                    """,
                arguments: [fixtureAccountID.rawValue, observedAtMilliseconds, observedAtMilliseconds]
            )
            try database.execute(
                sql: """
                    INSERT INTO organizations (
                        id, github_organization_id, github_node_id, login, display_name, avatar_url, updated_at_ms
                    ) VALUES (?, '2', 'O_1', 'github', NULL, NULL, ?)
                    """,
                arguments: [fixtureOrganizationID.rawValue, observedAtMilliseconds]
            )
            try database.execute(
                sql: """
                    INSERT INTO account_organizations (
                        account_id, organization_id, access_state, capability_revision, checked_at_ms, selected_at_ms
                    ) VALUES (?, ?, 'available', 'capability-1', ?, ?)
                    """,
                arguments: [
                    fixtureAccountID.rawValue, fixtureOrganizationID.rawValue,
                    observedAtMilliseconds, observedAtMilliseconds
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO repositories (
                        id, organization_id, github_repository_id, github_node_id, owner_login, name,
                        is_private, is_archived, has_discussions, html_url, updated_at_ms, archived_at_ms
                    ) VALUES (?, ?, '3', 'R_1', 'github', 'triage', 1, 0, 0, ?, ?, NULL)
                    """,
                arguments: [
                    fixtureRepositoryID.rawValue, fixtureOrganizationID.rawValue,
                    "https://github.com/github/triage", observedAtMilliseconds
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO github_nodes (
                        github_node_id, account_id, organization_id, repository_id, kind, numeric_id, number,
                        title, state, html_url, body_markdown, author_id, created_at_ms, updated_at_ms,
                        closed_at_ms, merged_at_ms, source_revision, last_observed_at_ms, accessibility_state
                    ) VALUES (?, ?, ?, ?, 'issue', '1', 1, 'Timeline fixture', 'open', ?, NULL, NULL, ?, ?,
                              NULL, NULL, 'revision-1', ?, 'accessible')
                    """,
                arguments: [
                    fixtureNodeID.rawValue, fixtureAccountID.rawValue, fixtureOrganizationID.rawValue, fixtureRepositoryID.rawValue,
                    "https://github.com/github/triage/issues/1",
                    observedAtMilliseconds, observedAtMilliseconds, observedAtMilliseconds
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO issues (
                        github_node_id, locked, comments_count, assignee_node_ids_json, label_node_ids_json,
                        milestone_node_id, updated_at_ms
                    ) VALUES (?, 0, 0, '[]', '[]', NULL, ?)
                    """,
                arguments: [fixtureNodeID.rawValue, observedAtMilliseconds]
            )
        }
        candidate = TimelineCandidate(
            nodeID: nodeID,
            repositoryID: repositoryID,
            repository: try GitHubRepositoryPath(owner: "github", repository: "triage"),
            number: 1,
            sourceRevision: "revision-1"
        )
    }

    func event(id: String, payload: String) -> NormalizedGitHubTimelineEvent {
        NormalizedGitHubTimelineEvent(
            id: GitHubEventID(rawValue: id)!,
            kind: .assigned,
            actor: nil,
            occurredAt: observedAt,
            payload: Data(payload.utf8)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

}

private actor CancellingTimelineSession: HTTPSession {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        withUnsafeCurrentTask { $0?.cancel() }
        return (
            Data(#"[{"id":"new-event","event":"mentioned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}

private actor TimelineRefreshSession: HTTPSession {
    private let responses: [String: (Data, [String: String])]

    init(responses: [String: (Data, [String: String])]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let pathAndQuery = [url.path, url.query].compactMap { $0 }.joined(separator: "?")
        guard let response = responses[pathAndQuery] else { throw URLError(.resourceUnavailable) }
        return (
            response.0,
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: response.1
            )!
        )
    }
}

private actor ConditionalTimelineSession: HTTPSession {
    private var validators = [String?]()
    private var lastModifiedValidators = [String?]()

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let validator = request.value(forHTTPHeaderField: "If-None-Match")
        let lastModified = request.value(forHTTPHeaderField: "If-Modified-Since")
        validators.append(validator)
        lastModifiedValidators.append(lastModified)
        let isConditional = validator != nil || lastModified != nil
        let statusCode = isConditional ? 304 : 200
        let body = !isConditional
            ? Data(#"[{"id":"authoritative-event","event":"mentioned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8)
            : Data()
        return (
            body,
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: !isConditional
                    ? [
                        "ETag": "new-etag",
                        "Last-Modified": "Thu, 22 Oct 2015 07:28:00 GMT"
                    ]
                    : nil
            )!
        )
    }

    func receivedValidators() -> [String?] {
        validators
    }

    func receivedLastModifiedValidators() -> [String?] {
        lastModifiedValidators
    }
}
