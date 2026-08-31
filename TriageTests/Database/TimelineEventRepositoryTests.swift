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
            requestKey: fixture.timelineRequestKey,
            scope: fixture.scope,
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
                requestKey: fixture.timelineRequestKey,
                scope: fixture.scope,
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
            return (
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
        try await repository.replaceForFixture(
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
            requestKey: fixture.timelineRequestKey,
            scope: fixture.scope,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt
        )
        try await repository.commitValidatedRawPage(
            snapshotID,
            candidate: fixture.candidate,
            pageIndex: 1,
            requestKey: fixture.timelineRequestKey,
            scope: fixture.scope,
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
                observedAt: fixture.observedAt.addingTimeInterval(1),
                relationReconciliation: .unavailable
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
            observedAt: fixture.observedAt.addingTimeInterval(1),
            relationReconciliation: .unavailable
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

    func testCompleteTimelineWritesPageBoundConfirmedRelationAndCoverage() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let repository = TimelineEventRepository(vault: fixture.vault)
        let payload = Data(#"[{"id":"comment-1","event":"commented","actor":{"node_id":"U_commenter","login":"commenter"},"created_at":"2026-01-01T00:00:00Z"}]"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = try decoder.decode([GitHubTimelineEventDTO].self, from: payload)
        let snapshotID = try await repository.saveRawPage(
            GitHubPage(values: events, payload: payload, nextPageURL: nil, etag: nil, lastModified: nil, ssoHeader: nil),
            candidate: fixture.candidate,
            pageIndex: 1,
            requestKey: fixture.timelineRequestKey,
            scope: fixture.scope,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt
        )
        try await repository.commitValidatedRawPage(
            snapshotID,
            candidate: fixture.candidate,
            pageIndex: 1,
            requestKey: fixture.timelineRequestKey,
            scope: fixture.scope,
            nextPageURL: nil,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            attemptedAt: fixture.observedAt
        )
        let saved = try await repository.savedPages(
            for: fixture.candidate,
            scope: fixture.scope,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        let normalized = try GitHubTimelineNormalizer.normalize(saved.events)

        try await repository.replaceAndComplete(
            normalized,
            candidate: fixture.candidate,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt,
            relationReconciliation: .complete(
                scope: fixture.scope,
                pageProvenances: saved.pageProvenances,
                eventPageProvenances: saved.eventPageProvenances
            )
        )

        let persisted = try await fixture.vault.read { database in
            let relation = try Row.fetchOne(database, sql: """
                SELECT relations.kind, relations.object_node_id, relation_evidence.source,
                       relation_evidence.source_locator, relation_evidence.raw_snapshot_id,
                       relation_evidence.confirmation
                FROM relations
                JOIN relation_evidence ON relation_evidence.relation_id = relations.id
                """)
            let coverage = try Row.fetchOne(database, sql: """
                SELECT repository_id, feature, stream_id, status, last_successful_at_ms
                FROM coverage_records
                """)
            return TimelineRelationPersistence(
                relationKind: relation?["kind"],
                relationObjectNodeID: relation?["object_node_id"],
                evidenceSource: relation?["source"],
                evidenceLocator: relation?["source_locator"],
                evidenceRawSnapshotID: relation?["raw_snapshot_id"],
                evidenceConfirmation: relation?["confirmation"],
                coverageRepositoryID: coverage?["repository_id"],
                coverageFeature: coverage?["feature"],
                coverageStreamID: coverage?["stream_id"],
                coverageStatus: coverage?["status"],
                coverageLastSuccessfulAtMilliseconds: coverage?["last_successful_at_ms"]
            )
        }
        XCTAssertEqual(persisted.relationKind, WorkRelationKind.commented.rawValue)
        XCTAssertEqual(persisted.relationObjectNodeID, "U_commenter")
        XCTAssertEqual(persisted.evidenceSource, EvidenceSource.restTimeline.rawValue)
        XCTAssertEqual(persisted.evidenceLocator, fixture.timelineRequestKey)
        XCTAssertEqual(persisted.evidenceRawSnapshotID, snapshotID.rawValue)
        XCTAssertEqual(persisted.evidenceConfirmation, EvidenceConfirmation.confirmed.rawValue)
        XCTAssertEqual(persisted.coverageRepositoryID, fixture.repositoryID.rawValue)
        XCTAssertEqual(persisted.coverageFeature, CoverageFeature.timelines.rawValue)
        XCTAssertEqual(persisted.coverageStreamID, fixture.timelineStreamID.rawValue)
        XCTAssertEqual(persisted.coverageStatus, CoverageStatus.complete.rawValue)
        XCTAssertEqual(persisted.coverageLastSuccessfulAtMilliseconds, fixture.observedAtMilliseconds)
    }

    func testRelationRawAuthorityFailureRollsBackTimelineAndCoverage() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let repository = TimelineEventRepository(vault: fixture.vault)
        try await repository.replaceForFixture(
            [fixture.event(id: "old-event", payload: #"{"event":"mentioned"}"#)],
            candidate: fixture.candidate,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt
        )
        let (normalized, provenance) = try await fixture.pageBoundComment(repository: repository)
        let invalidProvenance = TimelineRawPageProvenance(
            snapshotID: RawAPISnapshotID.make(),
            endpoint: provenance.endpoint,
            requestKey: provenance.requestKey,
            parserVersion: provenance.parserVersion,
            observedAt: provenance.observedAt
        )

        do {
            try await repository.replaceAndComplete(
                normalized,
                candidate: fixture.candidate,
                accountID: fixture.accountID,
                organizationID: fixture.organizationID,
                observedAt: fixture.observedAt,
                relationReconciliation: .complete(
                    scope: fixture.scope,
                    pageProvenances: [invalidProvenance],
                    eventPageProvenances: [normalized[0].id: invalidProvenance]
                )
            )
            XCTFail("Expected cross-snapshot relation authority rejection.")
        } catch let error as WorkRelationRepositoryError {
            XCTAssertEqual(error, .rawSnapshotScopeMismatch)
        }

        let rolledBack = try await fixture.vault.read { database in
            (
                try String.fetchAll(database, sql: "SELECT github_event_id FROM timeline_events"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM coverage_records"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM relation_evidence")
            )
        }
        XCTAssertEqual(rolledBack.0, ["old-event"])
        XCTAssertEqual(rolledBack.1, 0)
        XCTAssertEqual(rolledBack.2, 0)
    }

    func testTwoPageTimelineRetainsEachExactPageBindingAcrossIdempotentReplay() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let repository = TimelineEventRepository(vault: fixture.vault)
        let pageOne = try fixture.timelinePage(
            eventID: "comment-page-one",
            actorNodeID: "U_page_one",
            pageIndex: 1
        )
        let pageTwo = try fixture.timelinePage(
            eventID: "review-page-two",
            actorNodeID: "U_page_two",
            pageIndex: 2
        )
        let firstSnapshotID = try await repository.saveRawPage(
            pageOne.page,
            candidate: fixture.candidate,
            pageIndex: 1,
            requestKey: pageOne.requestKey,
            scope: fixture.scope,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt
        )
        try await repository.commitValidatedRawPage(
            firstSnapshotID,
            candidate: fixture.candidate,
            pageIndex: 1,
            requestKey: pageOne.requestKey,
            scope: fixture.scope,
            nextPageURL: URL(string: "https://api.github.com/repos/github/triage/issues/1/timeline?page=2&per_page=100"),
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            attemptedAt: fixture.observedAt
        )
        let secondSnapshotID = try await repository.saveRawPage(
            pageTwo.page,
            candidate: fixture.candidate,
            pageIndex: 2,
            requestKey: pageTwo.requestKey,
            scope: fixture.scope,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt
        )
        try await repository.commitValidatedRawPage(
            secondSnapshotID,
            candidate: fixture.candidate,
            pageIndex: 2,
            requestKey: pageTwo.requestKey,
            scope: fixture.scope,
            nextPageURL: nil,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            attemptedAt: fixture.observedAt
        )
        let saved = try await repository.savedPages(
            for: fixture.candidate,
            scope: fixture.scope,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        let normalized = try GitHubTimelineNormalizer.normalize(saved.events)
        let reconciliation = TimelineRelationReconciliation.complete(
            scope: fixture.scope,
            pageProvenances: saved.pageProvenances,
            eventPageProvenances: saved.eventPageProvenances
        )

        try await repository.replaceAndComplete(
            normalized,
            candidate: fixture.candidate,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt,
            relationReconciliation: reconciliation
        )
        try await repository.replaceAndComplete(
            normalized,
            candidate: fixture.candidate,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt,
            relationReconciliation: reconciliation
        )

        let bindings = try await fixture.vault.read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT source_locator, raw_snapshot_id FROM relation_evidence ORDER BY source_locator"
            ).map { row in
                ((row["source_locator"] as String?) ?? "") + "\u{0}" + ((row["raw_snapshot_id"] as String?) ?? "")
            }
        }
        XCTAssertEqual(bindings, [
            pageOne.requestKey + "\u{0}" + firstSnapshotID.rawValue,
            pageTwo.requestKey + "\u{0}" + secondSnapshotID.rawValue
        ])
    }

    func testOnePageRefreshPublishesShrinkOnlyAtCompletionAndRetainsRawHistory() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let repository = TimelineEventRepository(vault: fixture.vault)
        let pageOne = try fixture.timelinePage(eventID: "old-one", actorNodeID: "U_one", pageIndex: 1)
        let pageTwo = try fixture.timelinePage(eventID: "old-two", actorNodeID: "U_two", pageIndex: 2)
        let firstID = try await repository.saveRawPage(pageOne.page, candidate: fixture.candidate, pageIndex: 1, requestKey: pageOne.requestKey, scope: fixture.scope, accountID: fixture.accountID, organizationID: fixture.organizationID, observedAt: fixture.observedAt)
        try await repository.commitValidatedRawPage(firstID, candidate: fixture.candidate, pageIndex: 1, requestKey: pageOne.requestKey, scope: fixture.scope, nextPageURL: URL(string: "https://api.github.com/repos/github/triage/issues/1/timeline?page=2&per_page=100"), accountID: fixture.accountID, organizationID: fixture.organizationID, attemptedAt: fixture.observedAt)
        let secondID = try await repository.saveRawPage(pageTwo.page, candidate: fixture.candidate, pageIndex: 2, requestKey: pageTwo.requestKey, scope: fixture.scope, accountID: fixture.accountID, organizationID: fixture.organizationID, observedAt: fixture.observedAt)
        try await repository.commitValidatedRawPage(secondID, candidate: fixture.candidate, pageIndex: 2, requestKey: pageTwo.requestKey, scope: fixture.scope, nextPageURL: nil, accountID: fixture.accountID, organizationID: fixture.organizationID, attemptedAt: fixture.observedAt)
        let oldSaved = try await repository.savedPages(for: fixture.candidate, scope: fixture.scope, accountID: fixture.accountID, organizationID: fixture.organizationID)
        try await repository.replaceAndComplete(try GitHubTimelineNormalizer.normalize(oldSaved.events), candidate: fixture.candidate, accountID: fixture.accountID, organizationID: fixture.organizationID, observedAt: fixture.observedAt, relationReconciliation: .unavailable)

        let refreshedCandidate = try await fixture.advanceSourceRevision(to: "revision-shrunk")
        let newPage = try fixture.timelinePage(eventID: "new-only", actorNodeID: "U_new", pageIndex: 1)
        let newID = try await repository.saveRawPage(newPage.page, candidate: refreshedCandidate, pageIndex: 1, requestKey: newPage.requestKey, scope: fixture.scope, accountID: fixture.accountID, organizationID: fixture.organizationID, observedAt: fixture.observedAt.addingTimeInterval(1))
        try await repository.commitValidatedRawPage(newID, candidate: refreshedCandidate, pageIndex: 1, requestKey: newPage.requestKey, scope: fixture.scope, nextPageURL: nil, accountID: fixture.accountID, organizationID: fixture.organizationID, attemptedAt: fixture.observedAt.addingTimeInterval(1))

        let beforePublication = try await fixture.vault.read { database in
            (try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM timeline_current_pages"), try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM timeline_staged_pages"), try String.fetchAll(database, sql: "SELECT github_event_id FROM timeline_events ORDER BY github_event_id"))
        }
        XCTAssertEqual(beforePublication.0, 2)
        XCTAssertEqual(beforePublication.1, 1)
        XCTAssertEqual(beforePublication.2, ["old-one", "old-two"])

        let newSaved = try await repository.savedPages(for: refreshedCandidate, scope: fixture.scope, accountID: fixture.accountID, organizationID: fixture.organizationID)
        try await repository.replaceAndComplete(try GitHubTimelineNormalizer.normalize(newSaved.events), candidate: refreshedCandidate, accountID: fixture.accountID, organizationID: fixture.organizationID, observedAt: fixture.observedAt.addingTimeInterval(1), relationReconciliation: .unavailable)
        let published = try await fixture.vault.read { database in
            (try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM timeline_current_pages"), try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM timeline_staged_pages"), try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots"), try String.fetchAll(database, sql: "SELECT github_event_id FROM timeline_events"))
        }
        XCTAssertEqual(published.0, 1)
        XCTAssertEqual(published.1, 0)
        XCTAssertEqual(published.2, 3)
        XCTAssertEqual(published.3, ["new-only"])
    }

    func testUnavailableTimelineReconciliationDoesNotDeleteExistingRelations() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let repository = TimelineEventRepository(vault: fixture.vault)
        let (normalized, _) = try await fixture.pageBoundComment(repository: repository)
        let saved = try await repository.savedPages(
            for: fixture.candidate,
            scope: fixture.scope,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        try await repository.replaceAndComplete(
            normalized,
            candidate: fixture.candidate,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt,
            relationReconciliation: .complete(
                scope: fixture.scope,
                pageProvenances: saved.pageProvenances,
                eventPageProvenances: saved.eventPageProvenances
            )
        )

        try await repository.replaceAndComplete(
            [fixture.event(id: "resumed-event", payload: #"{"event":"mentioned"}"#)],
            candidate: fixture.candidate,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt.addingTimeInterval(1),
            relationReconciliation: .unavailable
        )

        let evidenceCount = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM relation_evidence")
        }
        XCTAssertEqual(evidenceCount, 1)
    }

    func testStaleScopeRollsBackTimelineRelationCompletion() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let repository = TimelineEventRepository(vault: fixture.vault)
        try await repository.replaceForFixture(
            [fixture.event(id: "old-event", payload: #"{"event":"mentioned"}"#)],
            candidate: fixture.candidate,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            observedAt: fixture.observedAt
        )
        let (normalized, _) = try await fixture.pageBoundComment(repository: repository)
        let saved = try await repository.savedPages(
            for: fixture.candidate,
            scope: fixture.scope,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        try await fixture.vault.write { database in
            try database.execute(
                sql: "UPDATE account_organizations SET capability_revision = 'capability-rotated'"
            )
        }

        do {
            try await repository.replaceAndComplete(
                normalized,
                candidate: fixture.candidate,
                accountID: fixture.accountID,
                organizationID: fixture.organizationID,
                observedAt: fixture.observedAt,
                relationReconciliation: .complete(
                    scope: fixture.scope,
                    pageProvenances: saved.pageProvenances,
                    eventPageProvenances: saved.eventPageProvenances
                )
            )
            XCTFail("Expected stale scope rejection.")
        } catch let error as WorkRelationRepositoryError {
            XCTAssertEqual(error, .staleSynchronizationScope)
        }
        let rolledBack = try await fixture.vault.read { database in
            (
                try String.fetchAll(database, sql: "SELECT github_event_id FROM timeline_events"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM coverage_records")
            )
        }
        XCTAssertEqual(rolledBack.0, ["old-event"])
        XCTAssertEqual(rolledBack.1, 0)
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

    func testResumedTraversalRequiresExactRawAuthorityAndRetainsLastModified() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let secondPage = URL(
            string: "https://api.github.com/repos/github/triage/issues/1/timeline?page=2"
        )!
        let lastModified = "Wed, 21 Oct 2015 07:28:00 GMT"
        let firstService = GitHubTimelineRefreshService(
            client: GitHubTimelineClient(client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: TimelineRefreshSession(responses: [
                    "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (
                        Data(#"[{"id":"first","event":"mentioned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8),
                        [
                            "Last-Modified": lastModified,
                            "Link": "<\(secondPage)>; rel=\"next\""
                        ]
                    )
                ])),
                credential: SecretValue("token")
            )),
            candidateRepository: TimelineCandidateRepository(vault: fixture.vault),
            eventRepository: TimelineEventRepository(vault: fixture.vault),
            normalizationFailureRepository: NormalizationFailureRepository(vault: fixture.vault),
            conditionalRequestCacheRepository: ConditionalRequestCacheRepository(vault: fixture.vault)
        )

        let deferred = try await firstService.refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            budget: TimelineRefreshBudget(maximumPages: 1, maximumDecodedBytes: 1_024),
            observedAt: fixture.observedAt
        )
        XCTAssertEqual(deferred.outcomes.map(\.status), [.deferredByBudget])

        let initialSnapshots = try await RawAPISnapshotRepository(vault: fixture.vault)
            .snapshots(for: fixture.accountID)
        let firstSnapshot = try XCTUnwrap(initialSnapshots.first)
        XCTAssertEqual(firstSnapshot.lastModified, lastModified)
        XCTAssertEqual(firstSnapshot.requestIdentity, fixture.conditionalRequestIdentity)

        let resumedService = GitHubTimelineRefreshService(
            client: GitHubTimelineClient(client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: TimelineRefreshSession(responses: [
                    "/repos/github/triage/issues/1/timeline?page=2": (
                        Data(#"[{"id":"second","event":"mentioned","created_at":"2026-01-02T00:00:00Z"}]"#.utf8),
                        [:]
                    )
                ])),
                credential: SecretValue("token")
            )),
            candidateRepository: TimelineCandidateRepository(vault: fixture.vault),
            eventRepository: TimelineEventRepository(vault: fixture.vault),
            normalizationFailureRepository: NormalizationFailureRepository(vault: fixture.vault),
            conditionalRequestCacheRepository: ConditionalRequestCacheRepository(vault: fixture.vault)
        )
        let resumed = try await resumedService.refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt.addingTimeInterval(1)
        )

        XCTAssertEqual(resumed.outcomes.map(\.status), [.refreshed])
        let snapshots = try await RawAPISnapshotRepository(vault: fixture.vault)
            .snapshots(for: fixture.accountID)
        XCTAssertEqual(snapshots.count, 2)
        let secondSnapshot = try XCTUnwrap(
            snapshots.first { $0.requestIdentity?.requestKey.hasSuffix("timeline?page=2") == true }
        )
        XCTAssertEqual(secondSnapshot.requestIdentity?.scope, fixture.scope)
        XCTAssertEqual(secondSnapshot.requestIdentity?.feature, .timelines)
        XCTAssertEqual(secondSnapshot.requestIdentity?.streamID, fixture.timelineStreamID)
        let validator = try await ConditionalRequestCacheRepository(vault: fixture.vault)
            .validator(for: fixture.conditionalRequestIdentity)
        XCTAssertNil(validator?.eTag)
        XCTAssertEqual(validator?.lastModified, lastModified)
    }

    func testScopedPartialResultsPreservePriorTimelineAndRetainPendingRawResponse() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let eventRepository = TimelineEventRepository(vault: fixture.vault)
        try await eventRepository.replaceForFixture(
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

    func testValidNotModifiedReceiptCompletesNewSourceRevisionWithoutBodyFetch() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let initialPayload = Data(
            #"[{"id":"stable-event","event":"mentioned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8
        )
        let first = try await timelineService(
            fixture: fixture,
            session: TimelineRefreshSession(responses: [
                "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (
                    initialPayload,
                    ["ETag": "stable-etag"]
                )
            ])
        ).refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt
        )
        XCTAssertEqual(first.outcomes.map(\.status), [.refreshed])

        let updatedCandidate = try await fixture.advanceSourceRevision(to: "revision-2")
        let session = ConditionalTimelineSession()
        let replayedAt = fixture.observedAt.addingTimeInterval(60)
        let replayed = try await timelineService(fixture: fixture, session: session).refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [updatedCandidate],
            budget: TimelineRefreshBudget(maximumPages: 1, maximumDecodedBytes: 1_024),
            observedAt: replayedAt
        )

        XCTAssertEqual(replayed.outcomes.map(\.status), [.refreshed])
        let receivedETags = await session.receivedValidators()
        let receivedLastModified = await session.receivedLastModifiedValidators()
        XCTAssertEqual(receivedETags, ["stable-etag"])
        XCTAssertEqual(receivedLastModified, [nil])
        let state = try await fixture.vault.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots"),
                try String.fetchOne(
                    database,
                    sql: "SELECT github_event_id FROM timeline_events"
                ),
                try String.fetchOne(
                    database,
                    sql: "SELECT source_revision FROM timeline_events"
                ),
                try String.fetchOne(
                    database,
                    sql: "SELECT normalized_source_revision FROM timeline_replay_receipts"
                ),
                try String.fetchOne(
                    database,
                    sql: "SELECT raw_source_revision FROM timeline_replay_receipts"
                ),
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM sync_shards WHERE state = 'completed'"
                )
            )
        }
        XCTAssertEqual(state.0, 1)
        XCTAssertEqual(state.1, "stable-event")
        XCTAssertEqual(state.2, "revision-2")
        XCTAssertEqual(state.3, "revision-2")
        XCTAssertEqual(state.4, "revision-1")
        XCTAssertEqual(state.5, 2)
        let validator = try await ConditionalRequestCacheRepository(vault: fixture.vault)
            .validator(for: fixture.conditionalRequestIdentity)
        XCTAssertEqual(validator?.observedAt, replayedAt)
    }

    func testLastModifiedReceiptAuthorizesEmptyTimelineReplay() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let lastModified = "Wed, 21 Oct 2015 07:28:00 GMT"
        let first = try await timelineService(
            fixture: fixture,
            session: TimelineRefreshSession(responses: [
                "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (
                    Data("[]".utf8),
                    ["Last-Modified": lastModified]
                )
            ])
        ).refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt
        )
        XCTAssertEqual(first.outcomes.map(\.status), [.refreshed])

        let updatedCandidate = try await fixture.advanceSourceRevision(to: "revision-empty-2")
        let session = ConditionalTimelineSession()
        let replayed = try await timelineService(fixture: fixture, session: session).refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [updatedCandidate],
            budget: TimelineRefreshBudget(maximumPages: 1, maximumDecodedBytes: 1_024),
            observedAt: fixture.observedAt.addingTimeInterval(60)
        )

        XCTAssertEqual(replayed.outcomes.map(\.status), [.refreshed])
        let receivedETags = await session.receivedValidators()
        let receivedLastModified = await session.receivedLastModifiedValidators()
        XCTAssertEqual(receivedETags, [nil])
        XCTAssertEqual(receivedLastModified, [lastModified])
        let state = try await fixture.vault.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM timeline_events"),
                try Int.fetchOne(
                    database,
                    sql: "SELECT normalized_event_count FROM timeline_replay_receipts"
                ),
                try String.fetchOne(
                    database,
                    sql: "SELECT normalized_source_revision FROM timeline_replay_receipts"
                )
            )
        }
        XCTAssertEqual(state.0, 0)
        XCTAssertEqual(state.1, 0)
        XCTAssertEqual(state.2, "revision-empty-2")
    }

    func testNotModifiedWithIncompleteReceiptFallsBackToSameEndpoint() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let first = try await timelineService(
            fixture: fixture,
            session: TimelineRefreshSession(responses: [
                "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (
                    Data(#"[{"id":"old-event","event":"mentioned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8),
                    ["ETag": "old-etag"]
                )
            ])
        ).refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt
        )
        XCTAssertEqual(first.outcomes.map(\.status), [.refreshed])
        try await fixture.vault.write { database in
            try database.execute(sql: "DELETE FROM timeline_replay_receipt_pages")
        }
        let updatedCandidate = try await fixture.advanceSourceRevision(to: "revision-2")
        let session = ConditionalTimelineSession()
        let refreshed = try await timelineService(fixture: fixture, session: session).refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [updatedCandidate],
            observedAt: fixture.observedAt.addingTimeInterval(60)
        )

        XCTAssertEqual(refreshed.outcomes.map(\.status), [.refreshed])
        let receivedETags = await session.receivedValidators()
        XCTAssertEqual(receivedETags, ["old-etag", nil])
        let state = try await fixture.vault.read { database in
            (
                try String.fetchOne(database, sql: "SELECT github_event_id FROM timeline_events"),
                try String.fetchOne(
                    database,
                    sql: "SELECT raw_source_revision FROM timeline_replay_receipts"
                ),
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM timeline_replay_receipt_pages"
                )
            )
        }
        XCTAssertEqual(state.0, "authoritative-event")
        XCTAssertEqual(state.1, "revision-2")
        XCTAssertEqual(state.2, 1)
    }

    func testCancellationAfterNotModifiedLeavesReplayAuthorityUnchanged() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let first = try await timelineService(
            fixture: fixture,
            session: TimelineRefreshSession(responses: [
                "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (
                    Data(#"[{"id":"stable-event","event":"mentioned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8),
                    ["ETag": "stable-etag"]
                )
            ])
        ).refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt
        )
        XCTAssertEqual(first.outcomes.map(\.status), [.refreshed])

        let updatedCandidate = try await fixture.advanceSourceRevision(to: "revision-2")
        let session = CancellingNotModifiedTimelineSession()
        let service = try timelineService(fixture: fixture, session: session)
        let refreshTask = Task {
            try await service.refresh(
                scope: fixture.scope,
                githubOrganizationID: 2,
                currentUserID: ActorID(rawValue: "U_current")!,
                candidates: [updatedCandidate],
                observedAt: fixture.observedAt.addingTimeInterval(60)
            )
        }

        do {
            _ = try await refreshTask.value
            XCTFail("Expected cancellation after the conditional response.")
        } catch is CancellationError {
        }

        let receivedETags = await session.receivedValidators()
        XCTAssertEqual(receivedETags, ["stable-etag"])
        let unchanged = try await fixture.vault.read { database in
            (
                try String.fetchOne(
                    database,
                    sql: "SELECT source_revision FROM timeline_events"
                ),
                try String.fetchOne(
                    database,
                    sql: "SELECT normalized_source_revision FROM timeline_replay_receipts"
                ),
                try Int64.fetchOne(
                    database,
                    sql: "SELECT validator_observed_at_ms FROM timeline_replay_receipts"
                ),
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM sync_shards WHERE state = 'completed'"
                ),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")
            )
        }
        XCTAssertEqual(unchanged.0, "revision-1")
        XCTAssertEqual(unchanged.1, "revision-1")
        XCTAssertEqual(
            unchanged.2,
            Int64((fixture.observedAt.timeIntervalSince1970 * 1_000).rounded())
        )
        XCTAssertEqual(unchanged.3, 1)
        XCTAssertEqual(unchanged.4, 1)
        let unchangedValidator = try await ConditionalRequestCacheRepository(vault: fixture.vault)
            .validator(for: fixture.conditionalRequestIdentity)
        XCTAssertEqual(unchangedValidator?.observedAt, fixture.observedAt)
    }

    func testNotModifiedWithCorruptNormalizedStateFallsBackUnconditionally() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let first = try await timelineService(
            fixture: fixture,
            session: TimelineRefreshSession(responses: [
                "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (
                    Data(#"[{"id":"old-event","event":"mentioned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8),
                    ["ETag": "old-etag"]
                )
            ])
        ).refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt
        )
        XCTAssertEqual(first.outcomes.map(\.status), [.refreshed])
        try await fixture.vault.write { database in
            try database.execute(
                sql: "UPDATE timeline_events SET payload_json = ?",
                arguments: [Data(#"{"event":"tampered"}"#.utf8)]
            )
        }

        let updatedCandidate = try await fixture.advanceSourceRevision(to: "revision-2")
        let session = ConditionalTimelineSession()
        let refreshed = try await timelineService(fixture: fixture, session: session).refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [updatedCandidate],
            observedAt: fixture.observedAt.addingTimeInterval(60)
        )

        XCTAssertEqual(refreshed.outcomes.map(\.status), [.refreshed])
        let receivedETags = await session.receivedValidators()
        XCTAssertEqual(receivedETags, ["old-etag", nil])
        let state = try await fixture.vault.read { database in
            (
                try String.fetchOne(database, sql: "SELECT github_event_id FROM timeline_events"),
                try String.fetchOne(database, sql: "SELECT source_revision FROM timeline_events"),
                try String.fetchOne(
                    database,
                    sql: "SELECT raw_source_revision FROM timeline_replay_receipts"
                )
            )
        }
        XCTAssertEqual(state.0, "authoritative-event")
        XCTAssertEqual(state.1, "revision-2")
        XCTAssertEqual(state.2, "revision-2")
    }

    func testNotModifiedWithMismatchedReceiptValidatorFallsBackUnconditionally() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let first = try await timelineService(
            fixture: fixture,
            session: TimelineRefreshSession(responses: [
                "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (
                    Data(#"[{"id":"old-event","event":"mentioned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8),
                    ["ETag": "old-etag"]
                )
            ])
        ).refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt
        )
        XCTAssertEqual(first.outcomes.map(\.status), [.refreshed])
        try await fixture.vault.write { database in
            try database.execute(
                sql: "UPDATE timeline_replay_receipts SET etag = 'mismatched-etag'"
            )
        }

        let updatedCandidate = try await fixture.advanceSourceRevision(to: "revision-2")
        let session = ConditionalTimelineSession()
        let refreshed = try await timelineService(fixture: fixture, session: session).refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [updatedCandidate],
            observedAt: fixture.observedAt.addingTimeInterval(60)
        )

        XCTAssertEqual(refreshed.outcomes.map(\.status), [.refreshed])
        let receivedETags = await session.receivedValidators()
        XCTAssertEqual(receivedETags, ["old-etag", nil])
        let eventID = try await fixture.vault.read { database in
            try String.fetchOne(database, sql: "SELECT github_event_id FROM timeline_events")
        }
        XCTAssertEqual(eventID, "authoritative-event")
    }

    func testNotModifiedWithGappedReceiptPageIndicesFallsBackUnconditionally() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let first = try await timelineService(
            fixture: fixture,
            session: TimelineRefreshSession(responses: [
                "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (
                    Data(#"[{"id":"old-event","event":"mentioned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8),
                    ["ETag": "old-etag"]
                )
            ])
        ).refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt
        )
        XCTAssertEqual(first.outcomes.map(\.status), [.refreshed])
        let unrelatedSnapshot = RawAPISnapshot(
            id: RawAPISnapshotID(rawValue: "unrelated-receipt-page")!,
            accountID: fixture.accountID,
            githubNodeID: nil,
            endpoint: "https://api.github.com/unrelated",
            eTag: nil,
            parserVersion: 1,
            observedAt: fixture.observedAt.addingTimeInterval(1),
            payload: Data("[]".utf8)
        )
        try await RawAPISnapshotRepository(vault: fixture.vault).save(unrelatedSnapshot)
        try await fixture.vault.write { database in
            let receiptID = try String.fetchOne(
                database,
                sql: "SELECT id FROM timeline_replay_receipts"
            )
            try database.execute(
                sql: """
                    INSERT INTO timeline_replay_receipt_pages (
                        receipt_id, page_index, raw_snapshot_id
                    ) VALUES (?, 3, ?)
                    """,
                arguments: [receiptID, unrelatedSnapshot.id.rawValue]
            )
            try database.execute(
                sql: "UPDATE timeline_replay_receipts SET page_count = 2 WHERE id = ?",
                arguments: [receiptID]
            )
        }

        let updatedCandidate = try await fixture.advanceSourceRevision(to: "revision-2")
        let session = ConditionalTimelineSession()
        let refreshed = try await timelineService(fixture: fixture, session: session).refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [updatedCandidate],
            observedAt: fixture.observedAt.addingTimeInterval(60)
        )

        XCTAssertEqual(refreshed.outcomes.map(\.status), [.refreshed])
        let receivedETags = await session.receivedValidators()
        XCTAssertEqual(receivedETags, ["old-etag", nil])
        let state = try await fixture.vault.read { database in
            (
                try String.fetchOne(database, sql: "SELECT github_event_id FROM timeline_events"),
                try Int.fetchAll(
                    database,
                    sql: "SELECT page_index FROM timeline_replay_receipt_pages ORDER BY page_index"
                )
            )
        }
        XCTAssertEqual(state.0, "authoritative-event")
        XCTAssertEqual(state.1, [1])
    }

    func testTimelineReplayReceiptProtectsEveryRawPageFromCompaction() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let secondPage = URL(
            string: "https://api.github.com/repos/github/triage/issues/1/timeline?page=2"
        )!
        let refreshed = try await timelineService(
            fixture: fixture,
            session: TimelineRefreshSession(responses: [
                "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (
                    Data(#"[{"id":"first","event":"mentioned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8),
                    [
                        "ETag": "two-page-etag",
                        "Link": "<\(secondPage)>; rel=\"next\""
                    ]
                ),
                "/repos/github/triage/issues/1/timeline?page=2": (
                    Data(#"[{"id":"second","event":"mentioned","created_at":"2026-01-02T00:00:00Z"}]"#.utf8),
                    [:]
                )
            ])
        ).refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt
        )
        XCTAssertEqual(refreshed.outcomes.map(\.status), [.refreshed])

        let receiptSnapshotIDs = try await fixture.vault.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT raw_snapshot_id FROM timeline_replay_receipt_pages ORDER BY page_index"
            )
        }
        XCTAssertEqual(receiptSnapshotIDs.count, 2)
        let repository = RawAPISnapshotRepository(vault: fixture.vault)
        let receiptSnapshots = try await repository.snapshots(for: fixture.accountID)
            .filter { receiptSnapshotIDs.contains($0.id.rawValue) }
        XCTAssertEqual(receiptSnapshots.count, 2)
        for (offset, snapshot) in receiptSnapshots.enumerated() {
            try await repository.save(RawAPISnapshot(
                id: RawAPISnapshotID(rawValue: "newer-timeline-page-\(offset + 1)")!,
                accountID: snapshot.accountID,
                githubNodeID: snapshot.githubNodeID,
                endpoint: snapshot.endpoint,
                eTag: snapshot.eTag,
                lastModified: snapshot.lastModified,
                parserVersion: snapshot.parserVersion,
                observedAt: fixture.observedAt.addingTimeInterval(60),
                payload: snapshot.payload,
                requestIdentity: snapshot.requestIdentity
            ))
        }

        let removed = try await repository.compact(
            accountID: fixture.accountID,
            retainingMostRecentPerSource: 1,
            before: fixture.observedAt.addingTimeInterval(120)
        )

        XCTAssertEqual(removed, 0)
        let retainedIDs = Set(
            try await repository.snapshots(for: fixture.accountID).map(\.id.rawValue)
        )
        XCTAssertTrue(Set(receiptSnapshotIDs).isSubset(of: retainedIDs))
        XCTAssertEqual(retainedIDs.count, 4)
    }

    func testValidatorlessRefreshRetiresObsoleteAuthorityReceiptAndReleasesRawPage() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let first = try await timelineService(
            fixture: fixture,
            session: TimelineRefreshSession(responses: [
                "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (
                    Data(#"[{"id":"old-event","event":"mentioned","created_at":"2026-01-01T00:00:00Z"}]"#.utf8),
                    ["ETag": "old-etag"]
                )
            ])
        ).refresh(
            scope: fixture.scope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [fixture.candidate],
            observedAt: fixture.observedAt
        )
        XCTAssertEqual(first.outcomes.map(\.status), [.refreshed])
        let initialSnapshots = try await RawAPISnapshotRepository(vault: fixture.vault)
            .snapshots(for: fixture.accountID)
        let oldSnapshot = try XCTUnwrap(initialSnapshots.first)
        try await fixture.vault.write { database in
            try database.execute(
                sql: "UPDATE accounts SET credential_revision = 'credential-2' WHERE id = ?",
                arguments: [fixture.accountID.rawValue]
            )
            try database.execute(
                sql: """
                    UPDATE account_organizations
                    SET capability_revision = 'capability-2'
                    WHERE account_id = ? AND organization_id = ?
                    """,
                arguments: [fixture.accountID.rawValue, fixture.organizationID.rawValue]
            )
        }
        let currentScope = SynchronizationScope(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: CredentialRevision(rawValue: "credential-2")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-2")!
        )
        let updatedCandidate = try await fixture.advanceSourceRevision(to: "revision-2")
        let refreshed = try await timelineService(
            fixture: fixture,
            session: TimelineRefreshSession(responses: [
                "/repos/github/triage/issues/1/timeline?per_page=100&page=1": (
                    Data(#"[{"id":"new-event","event":"mentioned","created_at":"2026-01-02T00:00:00Z"}]"#.utf8),
                    [:]
                )
            ])
        ).refresh(
            scope: currentScope,
            githubOrganizationID: 2,
            currentUserID: ActorID(rawValue: "U_current")!,
            candidates: [updatedCandidate],
            observedAt: fixture.observedAt.addingTimeInterval(60)
        )
        XCTAssertEqual(refreshed.outcomes.map(\.status), [.refreshed])
        let receiptCount = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM timeline_replay_receipts")
        }
        XCTAssertEqual(receiptCount, 0)

        let rawRepository = RawAPISnapshotRepository(vault: fixture.vault)
        try await rawRepository.save(RawAPISnapshot(
            id: RawAPISnapshotID(rawValue: "newer-unbound-old-authority-page")!,
            accountID: oldSnapshot.accountID,
            githubNodeID: oldSnapshot.githubNodeID,
            endpoint: oldSnapshot.endpoint,
            eTag: nil,
            parserVersion: oldSnapshot.parserVersion,
            observedAt: fixture.observedAt.addingTimeInterval(120),
            payload: oldSnapshot.payload
        ))
        let removed = try await rawRepository.compact(
            accountID: fixture.accountID,
            retainingMostRecentPerSource: 1,
            before: fixture.observedAt.addingTimeInterval(180)
        )
        XCTAssertEqual(removed, 1)
        let retainedIDs = Set(
            try await rawRepository.snapshots(for: fixture.accountID).map(\.id)
        )
        XCTAssertFalse(retainedIDs.contains(oldSnapshot.id))
    }

    func testUndecodableTransportPayloadIsRetainedWithRedactedFailure() async throws {
        let fixture = try await TimelineFixture()
        defer { fixture.remove() }
        let eventRepository = TimelineEventRepository(vault: fixture.vault)
        try await eventRepository.replaceForFixture(
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
        try await eventRepository.replaceForFixture(
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
                    [
                        "ETag": "retry-etag",
                        "Link": "<\(secondPage)>; rel=\"next\""
                    ]
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
        let recoveredState = try await fixture.vault.read { database in
            (
                try String.fetchAll(
                    database,
                    sql: "SELECT github_event_id FROM timeline_events ORDER BY github_event_id"
                ),
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM timeline_replay_receipt_pages"
                )
            )
        }
        XCTAssertEqual(recoveredState.0, ["new-event", "new-final"])
        XCTAssertEqual(recoveredState.1, 2)
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
        try await eventRepository.replaceForFixture(
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
        try await eventRepository.replaceForFixture(
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
        try await eventRepository.replaceForFixture(
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

    private func timelineService(
        fixture: TimelineFixture,
        session: any HTTPSession
    ) throws -> GitHubTimelineRefreshService {
        GitHubTimelineRefreshService(
            client: GitHubTimelineClient(client: GitHubRESTClient(
                transport: try GitHubRESTTransport(session: session),
                credential: SecretValue("token")
            )),
            candidateRepository: TimelineCandidateRepository(vault: fixture.vault),
            eventRepository: TimelineEventRepository(vault: fixture.vault),
            normalizationFailureRepository: NormalizationFailureRepository(vault: fixture.vault),
            conditionalRequestCacheRepository: ConditionalRequestCacheRepository(vault: fixture.vault)
        )
    }
}

private struct TimelineRelationPersistence: Sendable {
    let relationKind: String?
    let relationObjectNodeID: String?
    let evidenceSource: String?
    let evidenceLocator: String?
    let evidenceRawSnapshotID: String?
    let evidenceConfirmation: String?
    let coverageRepositoryID: String?
    let coverageFeature: String?
    let coverageStreamID: String?
    let coverageStatus: String?
    let coverageLastSuccessfulAtMilliseconds: Int64?
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

    var observedAtMilliseconds: Int64 {
        Int64((observedAt.timeIntervalSince1970 * 1_000).rounded())
    }

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

    var timelineRequestKey: String {
        "GET /repos/github/triage/issues/1/timeline?per_page=100&page=1"
    }

    var conditionalRequestIdentity: ConditionalRequestIdentity {
        ConditionalRequestIdentity(
            scope: scope,
            feature: .timelines,
            streamID: timelineStreamID,
            requestKey: timelineRequestKey
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

    func pageBoundComment(
        repository: TimelineEventRepository
    ) async throws -> ([NormalizedGitHubTimelineEvent], TimelineRawPageProvenance) {
        let payload = Data(#"[{"id":"comment-1","event":"commented","actor":{"node_id":"U_commenter","login":"commenter"},"created_at":"2026-01-01T00:00:00Z"}]"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = try decoder.decode([GitHubTimelineEventDTO].self, from: payload)
        let snapshotID = try await repository.saveRawPage(
            GitHubPage(values: events, payload: payload, nextPageURL: nil, etag: nil, lastModified: nil, ssoHeader: nil),
            candidate: candidate,
            pageIndex: 1,
            requestKey: timelineRequestKey,
            scope: scope,
            accountID: accountID,
            organizationID: organizationID,
            observedAt: observedAt
        )
        try await repository.commitValidatedRawPage(
            snapshotID,
            candidate: candidate,
            pageIndex: 1,
            requestKey: timelineRequestKey,
            scope: scope,
            nextPageURL: nil,
            accountID: accountID,
            organizationID: organizationID,
            attemptedAt: observedAt
        )
        let saved = try await repository.savedPages(
            for: candidate,
            scope: scope,
            accountID: accountID,
            organizationID: organizationID
        )
        let normalized = try GitHubTimelineNormalizer.normalize(saved.events)
        return (normalized, try XCTUnwrap(saved.eventPageProvenances[normalized[0].id]))
    }

    func timelinePage(
        eventID: String,
        actorNodeID: String,
        pageIndex: Int
    ) throws -> (page: GitHubPage<GitHubTimelineEventDTO>, requestKey: String) {
        let event = pageIndex == 1 ? "commented" : "reviewed"
        let payload = Data("""
        [{"id":"\(eventID)","event":"\(event)","actor":{"node_id":"\(actorNodeID)","login":"actor-\(pageIndex)"},"created_at":"2026-01-01T00:00:00Z"}]
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = try decoder.decode([GitHubTimelineEventDTO].self, from: payload)
        return (
            GitHubPage(
                values: events,
                payload: payload,
                nextPageURL: nil,
                etag: nil,
                lastModified: nil,
                ssoHeader: nil
            ),
            "GET /repos/github/triage/issues/1/timeline?page=\(pageIndex)&per_page=100"
        )
    }

    func advanceSourceRevision(to sourceRevision: String) async throws -> TimelineCandidate {
        try await vault.write { database in
            try database.execute(
                sql: "UPDATE github_nodes SET source_revision = ? WHERE github_node_id = ?",
                arguments: [sourceRevision, nodeID.rawValue]
            )
        }
        return TimelineCandidate(
            nodeID: candidate.nodeID,
            repositoryID: candidate.repositoryID,
            repository: candidate.repository,
            number: candidate.number,
            sourceRevision: sourceRevision
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

private actor CancellingNotModifiedTimelineSession: HTTPSession {
    private var validators = [String?]()

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        validators.append(request.value(forHTTPHeaderField: "If-None-Match"))
        withUnsafeCurrentTask { $0?.cancel() }
        return (
            Data(),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 304,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    func receivedValidators() -> [String?] {
        validators
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
