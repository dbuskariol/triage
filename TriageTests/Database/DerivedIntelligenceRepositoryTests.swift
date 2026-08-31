import CryptoKit
import Foundation
import GRDB
import XCTest
@testable import Triage

final class DerivedIntelligenceRepositoryTests: XCTestCase {
    func testReplaceAtomicallyRemovesStaleDerivedRowsAndRefreshesFTS() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = DerivedIntelligenceRepository(vault: fixture.vault)

        try await repository.replace(fixture.snapshot(reasonID: "stale", title: "Stale searchable title"))
        try await repository.replace(fixture.snapshot(reasonID: "current", title: "Current searchable title"))

        let workItems = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(workItems.count, 1)
        XCTAssertEqual(workItems[0].attentionReasons.map(\.id), ["current"])
        XCTAssertEqual(workItems[0].attentionReasons[0].evidence.map(\.id.rawValue), ["evidence-current"])
        XCTAssertEqual(workItems[0].score, AttentionScore(value: 900, breakdown: ["attentionReason": 900]))

        let search = SearchRepository(vault: fixture.vault)
        let staleResults = try await search.search(
            "stale", accountID: fixture.accountID, organizationID: fixture.organizationID
        )
        XCTAssertTrue(staleResults.isEmpty)
        let currentResults = try await search.search(
            "current", accountID: fixture.accountID, organizationID: fixture.organizationID
        )
        XCTAssertEqual(currentResults.compactMap(\.workItemID), [fixture.workItemID])
    }

    func testRejectsPartialSnapshotWithoutChangingExistingDerivedState() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = DerivedIntelligenceRepository(vault: fixture.vault)
        try await repository.replace(fixture.snapshot(reasonID: "current", title: "Current title"))

        let incomplete = DerivedIntelligencePersistenceSnapshot(
            scope: fixture.scope,
            sourceRevision: fixture.aggregateSourceRevision,
            evaluatedAt: fixture.date,
            coverage: CoverageEvaluation(
                freshness: FreshnessState(status: .fresh, lastSuccessfulSyncAt: fixture.date),
                missing: []
            ),
            coverageState: .trusted,
            items: []
        )
        do {
            try await repository.replace(incomplete)
            XCTFail("Expected incomplete snapshot rejection.")
        } catch {
            XCTAssertEqual(error as? DerivedIntelligenceRepositoryError, .incompleteWorkItemSnapshot)
        }

        let reasonIDs = try await fixture.vault.read { database in
            try String.fetchAll(database, sql: "SELECT id FROM attention_reasons ORDER BY id")
        }
        XCTAssertEqual(reasonIDs, ["current"])
    }

    func testPersistedWaitingWakeUpReasonMakesWaitingWorkEligibleForInbox() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await WorkflowRepository(vault: fixture.vault).save(
            WorkflowState(status: .waiting, updatedAt: fixture.date),
            for: fixture.workItemID
        )
        try await DerivedIntelligenceRepository(vault: fixture.vault).replace(
            fixture.snapshot(
                reasonID: "wake-up",
                title: "Waiting title",
                ruleID: WaitingAttentionRuleID.awaitedActorResponded.rawValue
            )
        )

        let workItems = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        let workItem = try XCTUnwrap(workItems.first)
        XCTAssertEqual(workItem.workflow.status, .waiting)
        XCTAssertEqual(InboxEligibilityRule().disposition(for: workItem, at: fixture.date), .inbox)
    }

    func testReplacePersistsRevisionBoundRunRuleEvidenceAndCandidateAtomically() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = DerivedIntelligenceRepository(vault: fixture.vault)
        let snapshot = fixture.snapshot(
            reasonID: "candidate",
            title: "Candidate title",
            aiCandidates: [
                DerivedAICandidate(
                    id: "candidate-1",
                    workItemID: fixture.workItemID,
                    score: AttentionScore(value: 900, breakdown: ["attentionReason": 900]),
                    triggerReasonIDs: ["candidate"]
                )
            ]
        )

        try await repository.replace(snapshot)

        let persistedProjection = try await repository.projection(for: fixture.scope)
        let projection = try XCTUnwrap(persistedProjection)
        XCTAssertEqual(projection.run.sourceRevision, fixture.aggregateSourceRevision)
        XCTAssertEqual(projection.run.coverageState, .trusted)
        XCTAssertFalse(projection.run.isProvisional)
        XCTAssertEqual(projection.run.coverage.freshness.status, .fresh)
        XCTAssertEqual(projection.candidates.compactMap(\.candidate), snapshot.aiCandidates)

        let persistedEvidence = try await fixture.vault.read { database -> [String]? in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT source_locator_kind, source_locator, authority_kind,
                           authority_credential_revision, confidence, confirmation,
                           source_revision
                    FROM rule_evaluation_evidence
                    WHERE rule_evaluation_id = 'candidate'
                    """
            ),
            let sourceLocatorKind: String = row["source_locator_kind"],
            let sourceLocator: String = row["source_locator"],
            let authorityKind: String = row["authority_kind"],
            let credentialRevision: String = row["authority_credential_revision"],
            let confidence: String = row["confidence"],
            let confirmation: String = row["confirmation"],
            let sourceRevision: String = row["source_revision"]
            else {
                return nil
            }
            return [
                sourceLocatorKind, sourceLocator, authorityKind, credentialRevision,
                confidence, confirmation, sourceRevision
            ]
        }
        let evidence = try XCTUnwrap(persistedEvidence)
        XCTAssertEqual(evidence, [
            "endpoint", "/repos/github/triage/pulls/1/reviews", "github", "credential",
            "confirmed", "confirmed", "revision"
        ])
    }

    func testCancelledProjectionStopsBeforeOpeningVaultRead() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let repository = DerivedIntelligenceRepository(vault: fixture.vault)
        let gate = ProjectionGate()
        let task = Task {
            await gate.wait()
            return try await repository.projection(for: fixture.scope)
        }

        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()

        do {
            _ = try await task.value
            XCTFail("Expected the cancelled projection to stop before its vault read.")
        } catch is CancellationError {
            // Expected: projection checks cancellation before opening the vault.
        }
    }

    func testStaleScopeRollsBackCompleteReplacement() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = DerivedIntelligenceRepository(vault: fixture.vault)
        try await repository.replace(fixture.snapshot(reasonID: "current", title: "Current title"))

        try await AccountRepository(vault: fixture.vault).save(
            fixture.account,
            credentialRevision: CredentialRevision(rawValue: "new-credential")!
        )
        do {
            try await repository.replace(fixture.snapshot(reasonID: "stale", title: "Stale title"))
            XCTFail("Expected stale synchronization scope rejection.")
        } catch {
            XCTAssertEqual(error as? DerivedIntelligenceRepositoryError, .staleSynchronizationScope)
        }

        let reasonIDs = try await fixture.vault.read { database in
            try String.fetchAll(database, sql: "SELECT id FROM attention_reasons ORDER BY id")
        }
        XCTAssertEqual(reasonIDs, ["current"])
    }

    func testChangedNormalizedSourceRevisionRollsBackReplacement() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = DerivedIntelligenceRepository(vault: fixture.vault)
        let snapshot = fixture.snapshot(reasonID: "revision", title: "Revision title")

        try await fixture.vault.write { database in
            try database.execute(
                sql: "UPDATE github_nodes SET source_revision = 'revision-rotated' WHERE github_node_id = ?",
                arguments: [fixture.nodeID.rawValue]
            )
        }
        do {
            try await repository.replace(snapshot)
            XCTFail("A changed normalized source revision must invalidate the input snapshot.")
        } catch {
            XCTAssertEqual(error as? DerivedIntelligenceRepositoryError, .staleSourceRevision)
        }

        let runCount = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM derived_intelligence_runs")
        }
        XCTAssertEqual(runCount, 0)
    }

    func testProjectionFailsClosedAfterNormalizedSourceRevisionChanges() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = DerivedIntelligenceRepository(vault: fixture.vault)
        try await repository.replace(fixture.snapshot(reasonID: "current", title: "Current title"))

        try await fixture.vault.write { database in
            try database.execute(
                sql: "UPDATE github_nodes SET source_revision = 'revision-newer' WHERE github_node_id = ?",
                arguments: [fixture.nodeID.rawValue]
            )
        }
        do {
            _ = try await repository.projection(for: fixture.scope)
            XCTFail("Stale durable intelligence must never be projected.")
        } catch {
            XCTAssertEqual(error as? DerivedIntelligenceRepositoryError, .staleSourceRevision)
        }
    }

    func testProvisionalInputCannotPersistAICandidate() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = DerivedIntelligenceRepository(vault: fixture.vault)
        let candidate = DerivedAICandidate(
            id: "candidate-provisional",
            workItemID: fixture.workItemID,
            score: AttentionScore(value: 900, breakdown: ["attentionReason": 900]),
            triggerReasonIDs: ["provisional"]
        )
        let snapshot = fixture.snapshot(
            reasonID: "provisional",
            title: "Provisional title",
            isProvisional: true,
            aiCandidates: [candidate]
        )

        do {
            try await repository.replace(snapshot)
            XCTFail("A provisional adapter input must not authorize AI work.")
        } catch {
            XCTAssertEqual(error as? DerivedIntelligenceRepositoryError, .invalidAICandidate)
        }

        let runCount = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM derived_intelligence_runs")
        }
        XCTAssertEqual(runCount, 0)
    }

    func testRejectsRawEvidenceWhoseSnapshotDoesNotCarryMatchingAuthority() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let rawSnapshotID = RawAPISnapshotID(rawValue: "unscoped-derived-evidence")!
        try await RawAPISnapshotRepository(vault: fixture.vault).save(
            RawAPISnapshot(
                id: rawSnapshotID,
                accountID: fixture.accountID,
                githubNodeID: fixture.nodeID,
                endpoint: "/repos/github/triage/pulls/1/reviews",
                eTag: "unscoped",
                parserVersion: 1,
                observedAt: fixture.date,
                payload: Data("[]".utf8)
            )
        )

        do {
            try await DerivedIntelligenceRepository(vault: fixture.vault).replace(
                fixture.snapshot(
                    reasonID: "unscoped-raw",
                    title: "Unscoped raw evidence",
                    rawSnapshotID: rawSnapshotID
                )
            )
            XCTFail("Unscoped raw evidence must not become durable provenance.")
        } catch {
            XCTAssertEqual(error as? DerivedIntelligenceRepositoryError, .invalidEvidence)
        }
    }

    func testProjectionFailsClosedWhenPersistedRawEvidenceAuthorityIsTampered() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let matchingRawID = RawAPISnapshotID(rawValue: "derived-matching-evidence")!
        let mismatchedRawID = RawAPISnapshotID(rawValue: "derived-mismatched-evidence")!
        let rawRepository = RawAPISnapshotRepository(vault: fixture.vault)
        try await rawRepository.save(
            RawAPISnapshot(
                id: matchingRawID,
                accountID: fixture.accountID,
                githubNodeID: fixture.nodeID,
                endpoint: "/repos/github/triage/pulls/1/reviews",
                eTag: "matching",
                parserVersion: 1,
                observedAt: fixture.date,
                payload: Data("[]".utf8),
                requestIdentity: .init(
                    scope: fixture.scope,
                    feature: .reviews,
                    streamID: SyncStreamID(rawValue: "reviews")!,
                    requestKey: "GET /repos/github/triage/pulls/1/reviews"
                )
            )
        )
        try await rawRepository.save(
            RawAPISnapshot(
                id: mismatchedRawID,
                accountID: fixture.accountID,
                githubNodeID: fixture.nodeID,
                endpoint: "/repos/github/triage/pulls/1/reviews",
                eTag: "mismatched",
                parserVersion: 1,
                observedAt: fixture.date.addingTimeInterval(1),
                payload: Data("[]".utf8)
            )
        )
        let repository = DerivedIntelligenceRepository(vault: fixture.vault)
        try await repository.replace(
            fixture.snapshot(
                reasonID: "raw-authority",
                title: "Raw authority",
                rawSnapshotID: matchingRawID
            )
        )
        try await fixture.vault.write { database in
            try database.execute(
                sql: "UPDATE rule_evaluation_evidence SET raw_snapshot_id = ? WHERE rule_evaluation_id = ?",
                arguments: [mismatchedRawID.rawValue, "raw-authority"]
            )
        }

        do {
            _ = try await repository.projection(for: fixture.scope)
            XCTFail("Tampered raw evidence authority must fail closed.")
        } catch {
            XCTAssertEqual(error as? DerivedIntelligenceRepositoryError, .invalidEvidence)
        }
    }

    func testProjectionFailsClosedWhenCandidateScoreIsTampered() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = DerivedIntelligenceRepository(vault: fixture.vault)
        try await repository.replace(fixture.candidateSnapshot(reasonID: "candidate-score"))
        try await fixture.vault.write { database in
            try database.execute(
                sql: "UPDATE ai_action_candidates SET score = ?, score_breakdown_json = ?",
                arguments: [901, try JSONEncoder().encode(["attentionReason": 901])]
            )
        }

        do {
            _ = try await repository.projection(for: fixture.scope)
            XCTFail("A candidate score must match the persisted attention score.")
        } catch {
            XCTAssertEqual(error as? DerivedIntelligenceRepositoryError, .invalidPersistedData)
        }
    }

    func testProjectionFailsClosedWhenCandidateTriggerReasonsAreTampered() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = DerivedIntelligenceRepository(vault: fixture.vault)
        try await repository.replace(fixture.candidateSnapshot(reasonID: "candidate-trigger"))
        try await fixture.vault.write { database in
            try database.execute(
                sql: "UPDATE ai_action_candidates SET trigger_reason_ids_json = ?",
                arguments: [try JSONEncoder().encode(["not-a-persisted-reason"])]
            )
        }

        do {
            _ = try await repository.projection(for: fixture.scope)
            XCTFail("Candidate trigger reasons must resolve to persisted attention reasons.")
        } catch {
            XCTAssertEqual(error as? DerivedIntelligenceRepositoryError, .invalidPersistedData)
        }
    }

    func testProjectionValidationBatchesHighCardinalityEvidenceAndCandidates() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let count = 1_001
        try await DerivedIntelligenceRepository(vault: fixture.vault).replace(
            fixture.snapshot(reasonID: "batch-seed", title: "Batch seed")
        )

        var revisions = [fixture.workItemID: "revision"]
        let workItemIDs = (0 ..< count).map { index in
            WorkItemID(rawValue: "batch-work-item-\(index)")!
        }
        for workItemID in workItemIDs {
            revisions[workItemID] = "revision"
        }
        let sourceRevision = DerivedIntelligenceSourceRevision.aggregate(
            primaryRevisions: revisions,
            supplementalSources: []
        )
        let scoreBreakdown = try JSONEncoder().encode(["attentionReason": 900])
        let observedAt = Fixture.milliseconds(fixture.date)

        try await fixture.vault.write { database in
            try database.execute(
                sql: "UPDATE derived_intelligence_runs SET source_revision = ?",
                arguments: [sourceRevision]
            )
            try database.execute(
                sql: "UPDATE rule_evaluations SET source_revision = ?",
                arguments: [sourceRevision]
            )
            for index in 0 ..< count {
                let nodeID = "batch-node-\(index)"
                let workItemID = workItemIDs[index].rawValue
                let reasonID = "batch-reason-\(index)"
                let rawSnapshotID = "batch-raw-\(index)"
                try database.execute(
                    sql: """
                        INSERT INTO github_nodes (
                            github_node_id, account_id, organization_id, repository_id, kind,
                            numeric_id, number, title, state, html_url, body_markdown, author_id,
                            created_at_ms, updated_at_ms, closed_at_ms, merged_at_ms,
                            source_revision, last_observed_at_ms, accessibility_state
                        ) VALUES (?, ?, ?, NULL, 'issue', ?, ?, 'Batch', 'open', ?, NULL, NULL,
                                  ?, ?, NULL, NULL, 'revision', ?, 'accessible')
                        """,
                    arguments: [
                        nodeID, fixture.accountID.rawValue, fixture.organizationID.rawValue,
                        "batch-number-\(index)", index + 10_000,
                        "https://github.com/github/triage/issues/\(index + 10_000)",
                        observedAt, observedAt, observedAt
                    ]
                )
                try database.execute(
                    sql: """
                        INSERT INTO work_items (
                            id, account_id, organization_id, primary_node_id, state,
                            last_relevant_activity_at_ms, created_at_ms, updated_at_ms
                        ) VALUES (?, ?, ?, ?, 'open', ?, ?, ?)
                        """,
                    arguments: [
                        workItemID, fixture.accountID.rawValue, fixture.organizationID.rawValue,
                        nodeID, observedAt, observedAt, observedAt
                    ]
                )
                try database.execute(
                    sql: """
                        INSERT INTO attention_reasons (
                            id, work_item_id, rule_id, rule_version, category, strength,
                            title, explanation, evaluated_at_ms
                        ) VALUES (?, ?, 'changesRequested', 1, 'pullRequest', 900,
                                  'Batch', 'Batch', ?)
                        """,
                    arguments: [reasonID, workItemID, observedAt]
                )
                try database.execute(
                    sql: """
                        INSERT INTO rule_evaluations (
                            id, account_id, organization_id, work_item_id,
                            credential_revision, capability_revision, source_revision,
                            rule_id, rule_version, category, strength, title, explanation,
                            evaluated_at_ms
                        ) VALUES (?, ?, ?, ?, 'credential', 'capability', ?,
                                  'changesRequested', 1, 'pullRequest', 900, 'Batch', 'Batch', ?)
                        """,
                    arguments: [
                        reasonID, fixture.accountID.rawValue, fixture.organizationID.rawValue,
                        workItemID, sourceRevision, observedAt
                    ]
                )
                try database.execute(
                    sql: """
                        INSERT INTO attention_scores (work_item_id, score, breakdown_json, evaluated_at_ms)
                        VALUES (?, 900, ?, ?)
                        """,
                    arguments: [workItemID, scoreBreakdown, observedAt]
                )
                try database.execute(
                    sql: """
                        INSERT INTO ai_action_candidates (
                            account_id, organization_id, work_item_id, credential_revision,
                            capability_revision, source_revision, candidate_id, disposition,
                            exclusion_reason, score, score_breakdown_json,
                            trigger_reason_ids_json, evaluated_at_ms
                        ) VALUES (?, ?, ?, 'credential', 'capability', ?, ?, 'candidate',
                                  NULL, 900, ?, ?, ?)
                        """,
                    arguments: [
                        fixture.accountID.rawValue, fixture.organizationID.rawValue, workItemID,
                        sourceRevision, "batch-candidate-\(index)", scoreBreakdown,
                        try JSONEncoder().encode([reasonID]), observedAt
                    ]
                )
                try database.execute(
                    sql: """
                        INSERT INTO raw_api_snapshots (
                            id, account_id, github_node_id, endpoint, etag, parser_version,
                            observed_at_ms, payload, last_modified, authority_organization_id,
                            authority_feature, authority_stream_id, authority_request_key,
                            authority_credential_revision, authority_capability_revision
                        ) VALUES (?, ?, ?, '/repos/github/triage/pulls/1/reviews', ?, 1,
                                  ?, X'', NULL, ?, 'reviews', 'reviews', ?, 'credential', 'capability')
                        """,
                    arguments: [
                        rawSnapshotID, fixture.accountID.rawValue, fixture.nodeID.rawValue,
                        "batch-etag-\(index)", observedAt, fixture.organizationID.rawValue,
                        "batch-request-\(index)"
                    ]
                )
                try database.execute(
                    sql: """
                        INSERT INTO rule_evaluation_evidence (
                            rule_evaluation_id, evidence_id, source, source_locator_kind,
                            source_locator, authority_kind, authority_account_id,
                            authority_organization_id, authority_feature, authority_stream_id,
                            authority_credential_revision, authority_capability_revision,
                            source_node_id, source_event_id, source_revision, raw_snapshot_id,
                            confidence, confirmation, observed_at_ms, excerpt
                        ) VALUES ('batch-seed', ?, 'restReview', 'endpoint',
                                  '/repos/github/triage/pulls/1/reviews', 'github', ?, ?,
                                  'reviews', 'reviews', 'credential', 'capability', ?, NULL,
                                  'revision', ?, 'confirmed', 'confirmed', ?, NULL)
                        """,
                    arguments: [
                        "batch-evidence-\(index)", fixture.accountID.rawValue,
                        fixture.organizationID.rawValue, fixture.nodeID.rawValue,
                        rawSnapshotID, observedAt
                    ]
                )
            }
        }

        let counter = ProjectionValidationQueryCounter()
        let repository = DerivedIntelligenceRepository(
            vault: fixture.vault,
            projectionValidationBatchQueryObserver: { counter.record() }
        )
        let loadedProjection = try await repository.projection(for: fixture.scope)
        let projection = try XCTUnwrap(loadedProjection)
        XCTAssertEqual(projection.candidates.compactMap(\.candidate).count, count)
        XCTAssertEqual(
            counter.value,
            9,
            "1,001 candidates and raw evidence references require three raw batches plus three score and three reason batches."
        )
    }

    func testCurrentDerivedSnapshotRejectsLegacyEvidence() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = DerivedIntelligenceRepository(vault: fixture.vault)
        await XCTAssertThrowsErrorAsync {
            try await repository.replace(
                fixture.snapshot(
                    reasonID: "legacy",
                    title: "Legacy title",
                    usesLegacyEvidence: true
                )
            )
        }
        let count = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM rule_evaluation_evidence")
        }
        XCTAssertEqual(count, 0)
    }

    func testCurrentDerivedSnapshotRejectsRevisionlessGitHubEvidence() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = DerivedIntelligenceRepository(vault: fixture.vault)

        await XCTAssertThrowsErrorAsync {
            try await repository.replace(
                fixture.snapshot(
                    reasonID: "revisionless",
                    title: "Revisionless title",
                    usesRevisionlessEvidence: true
                )
            )
        }
    }

    func testCurrentDerivedSnapshotRejectsUnconfirmedAndStaleGitHubEvidence() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = DerivedIntelligenceRepository(vault: fixture.vault)

        await XCTAssertThrowsErrorAsync {
            try await repository.replace(
                fixture.snapshot(
                    reasonID: "provisional",
                    title: "Provisional title",
                    confidence: .provisional
                )
            )
        }
        await XCTAssertThrowsErrorAsync {
            try await repository.replace(
                fixture.snapshot(
                    reasonID: "stale-node-revision",
                    title: "Stale node revision title",
                    evidenceSourceRevision: "retired-node-revision"
                )
            )
        }
    }

    func testScopedPresentationRejectsRotatedRunOrEvidenceButHistoricalReadRemainsAvailable() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await DerivedIntelligenceRepository(vault: fixture.vault).replace(
            fixture.snapshot(reasonID: "current", title: "Current title")
        )

        let workItems = WorkItemRepository(vault: fixture.vault)
        let initial = try await workItems.fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            authorityScope: fixture.scope
        )
        XCTAssertEqual(initial.first?.attentionReasons.map(\.id), ["current"])

        try await fixture.vault.write { database in
            try database.execute(
                sql: "UPDATE rule_evaluation_evidence SET source_revision = 'retired-node-revision'"
            )
        }
        let staleEvidence = try await workItems.fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            authorityScope: fixture.scope
        )
        XCTAssertTrue(staleEvidence.first?.attentionReasons.isEmpty ?? false)
        let historical = try await workItems.fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(historical.first?.attentionReasons.map(\.id), ["current"])

        try await fixture.vault.write { database in
            try database.execute(
                sql: "UPDATE github_nodes SET source_revision = 'rotated-revision' WHERE github_node_id = ?",
                arguments: [fixture.nodeID.rawValue]
            )
        }
        let staleRun = try await workItems.fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            authorityScope: fixture.scope
        )
        XCTAssertTrue(staleRun.first?.attentionReasons.isEmpty ?? false)
    }

    func testCorruptDurableRunFailsClosedInsteadOfReturningEmptyProjection() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = DerivedIntelligenceRepository(vault: fixture.vault)
        try await repository.replace(fixture.snapshot(reasonID: "current", title: "Current title"))
        try await fixture.vault.write { database in
            try database.execute(
                sql: "UPDATE derived_intelligence_runs SET missing_coverage_json = ?",
                arguments: [Data("corrupt".utf8)]
            )
        }

        do {
            _ = try await repository.projection(for: fixture.scope)
            XCTFail("Corrupt durable intelligence must fail closed.")
        } catch {
            XCTAssertEqual(error as? DerivedIntelligenceRepositoryError, .invalidPersistedData)
        }
    }

    func testProjectionFailsClosedWhenEvaluationAndPresentationRowsDiverge() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = DerivedIntelligenceRepository(vault: fixture.vault)
        try await repository.replace(fixture.snapshot(reasonID: "current", title: "Current title"))
        try await fixture.vault.write { database in
            try database.execute(sql: "DELETE FROM rule_evaluations WHERE id = 'current'")
        }

        do {
            _ = try await repository.projection(for: fixture.scope)
            XCTFail("A durable run with a missing rule evaluation must fail closed.")
        } catch {
            XCTAssertEqual(error as? DerivedIntelligenceRepositoryError, .invalidPersistedData)
        }
    }

    func testMigration042CreatesRevisionBoundSchemaAndLegacyEvidenceConstraint() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let schema = try await fixture.vault.read { database -> (Set<String>, Set<String>, Set<String>, Set<String>) in
            let tables = try String.fetchAll(
                database,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN (?, ?, ?, ?) ",
                arguments: [
                    "derived_intelligence_runs", "rule_evaluations",
                    "rule_evaluation_evidence", "ai_action_candidates"
                ]
            )
            let indexes = try String.fetchAll(
                database,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'index'
                      AND (name LIKE 'rule_evaluation_%' OR name LIKE 'ai_action_candidates_%')
                    """
            )
            let triggers = try String.fetchAll(
                database,
                sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'derived_intelligence_%'"
            )
            let runColumns = try Row.fetchAll(
                database,
                sql: "PRAGMA table_info(derived_intelligence_runs)"
            ).compactMap { row -> String? in
                let name: String? = row["name"]
                return name
            }
            return (Set(tables), Set(indexes), Set(triggers), Set(runColumns))
        }

        XCTAssertEqual(schema.0, Set([
            "derived_intelligence_runs", "rule_evaluations",
            "rule_evaluation_evidence", "ai_action_candidates"
        ]))
        XCTAssertTrue(schema.1.isSuperset(of: Set([
            "rule_evaluations_current_scope", "rule_evaluation_evidence_authority",
            "rule_evaluation_evidence_raw_snapshot", "ai_action_candidates_current_scope"
        ])))
        XCTAssertEqual(schema.2, Set([
            "derived_intelligence_protect_evidence_snapshot_delete",
            "derived_intelligence_protect_evidence_snapshot_update"
        ]))
        XCTAssertTrue(schema.3.isSuperset(of: Set([
            "source_revision", "coverage_state", "is_provisional",
            "freshness_status", "missing_coverage_json"
        ])))

        try await DerivedIntelligenceRepository(vault: fixture.vault).replace(
            fixture.snapshot(reasonID: "valid-current", title: "Valid current title")
        )
        try await fixture.vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO rule_evaluation_evidence (
                        rule_evaluation_id, evidence_id, source, source_locator_kind,
                        source_locator, authority_kind, authority_account_id,
                        authority_organization_id, authority_feature, authority_stream_id,
                        authority_credential_revision, authority_capability_revision,
                        source_node_id, source_event_id, source_revision, raw_snapshot_id,
                        confidence, confirmation, observed_at_ms, excerpt
                    ) VALUES (?, 'historical-legacy', 'legacyUnverified', 'legacyUnverified',
                              'legacy-unverified', 'legacyUnverified', NULL, NULL, NULL, NULL,
                              NULL, NULL, NULL, NULL, NULL, NULL, 'provisional', 'provisional', ?, NULL)
                    """,
                arguments: ["valid-current", Fixture.milliseconds(fixture.date)]
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await DerivedIntelligenceRepository(vault: fixture.vault)
                .projection(for: fixture.scope)
        }
        await XCTAssertThrowsErrorAsync {
            try await fixture.vault.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO rule_evaluation_evidence (
                            rule_evaluation_id, evidence_id, source, source_locator_kind,
                            source_locator, authority_kind, authority_account_id,
                            authority_organization_id, authority_feature, authority_stream_id,
                            authority_credential_revision, authority_capability_revision,
                            source_node_id, source_event_id, source_revision, raw_snapshot_id,
                            confidence, confirmation, observed_at_ms, excerpt
                        ) VALUES (?, 'invalid-legacy', 'legacyUnverified', 'legacyUnverified',
                                  'legacy-unverified', 'legacyUnverified', NULL, NULL, NULL, NULL,
                                  NULL, NULL, NULL, NULL, NULL, NULL, 'confirmed', 'provisional', ?, NULL)
                        """,
                    arguments: ["valid-current", Fixture.milliseconds(fixture.date)]
                )
            }
        }
    }

    func testMigration042PinsRawEvidenceAgainstMutationAndCompaction() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await DerivedIntelligenceRepository(vault: fixture.vault).replace(
            fixture.snapshot(reasonID: "pinned", title: "Pinned evidence")
        )

        let olderSnapshotID = RawAPISnapshotID(rawValue: "derived-evidence-older")!
        let newerSnapshotID = RawAPISnapshotID(rawValue: "derived-evidence-newer")!
        let rawRepository = RawAPISnapshotRepository(vault: fixture.vault)
        for (id, offset) in [(olderSnapshotID, 0.0), (newerSnapshotID, 1.0)] {
            try await rawRepository.save(
                RawAPISnapshot(
                    id: id,
                    accountID: fixture.accountID,
                    githubNodeID: fixture.nodeID,
                    endpoint: "/repos/github/triage/pulls/1/reviews",
                    eTag: "derived-\(id.rawValue)",
                    parserVersion: 1,
                    observedAt: fixture.date.addingTimeInterval(offset),
                    payload: Data("[]".utf8)
                )
            )
        }
        try await fixture.vault.write { database in
            try database.execute(
                sql: "UPDATE rule_evaluation_evidence SET raw_snapshot_id = ? WHERE rule_evaluation_id = ?",
                arguments: [olderSnapshotID.rawValue, "pinned"]
            )
        }

        await XCTAssertThrowsErrorAsync {
            try await fixture.vault.write { database in
                try database.execute(
                    sql: "DELETE FROM raw_api_snapshots WHERE id = ?",
                    arguments: [olderSnapshotID.rawValue]
                )
            }
        }
        await XCTAssertThrowsErrorAsync {
            try await fixture.vault.write { database in
                try database.execute(
                    sql: "UPDATE raw_api_snapshots SET payload = ? WHERE id = ?",
                    arguments: [Data("tampered".utf8), olderSnapshotID.rawValue]
                )
            }
        }

        let removed = try await rawRepository.compact(
            accountID: fixture.accountID,
            retainingMostRecentPerSource: 1,
            before: fixture.date.addingTimeInterval(60)
        )
        XCTAssertEqual(removed, 0)
        let retained = try await fixture.vault.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM raw_api_snapshots WHERE id IN (?, ?)",
                arguments: [olderSnapshotID.rawValue, newerSnapshotID.rawValue]
            )
        }
        XCTAssertEqual(retained, 2)
    }

    private final class Fixture: @unchecked Sendable {
        let directory: URL
        let accountID = AccountID(rawValue: "00000000-0000-4000-8000-000000000204")!
        let organizationID = OrganizationID(rawValue: "derived-organization")!
        let workItemID: WorkItemID
        let nodeID = GitHubNodeID(rawValue: "derived-node")!
        let date = Date(timeIntervalSinceReferenceDate: 10_000)
        let vault: AccountVault
        let account: GitHubAccount

        var scope: SynchronizationScope {
            SynchronizationScope(
                accountID: accountID,
                organizationID: organizationID,
                credentialRevision: CredentialRevision(rawValue: "credential")!,
                capabilityRevision: CapabilityRevision(rawValue: "capability")!
            )
        }

        init() async throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(".derived-intelligence-repository-tests-\(UUID().uuidString)", isDirectory: true)
            vault = try await VaultRegistry(rootDirectory: directory).open(
                accountID: accountID,
                vaultKey: try VaultKey.generate()
            )
            account = GitHubAccount(
                    id: accountID,
                    githubUserID: 1,
                    nodeID: GitHubNodeID(rawValue: "derived-user")!,
                    login: "octocat",
                    authenticationKind: .oauth,
                    credentialID: CredentialID.make(),
                    credentialStatus: .active,
                    createdAt: date,
                    lastValidatedAt: date
                )
            try await AccountRepository(vault: vault).save(
                account,
                credentialRevision: CredentialRevision(rawValue: "credential")!
            )
            try await AccountRepository(vault: vault).save(
                GitHubOrganization(
                    id: organizationID,
                    githubOrganizationID: 2,
                    nodeID: GitHubNodeID(rawValue: "derived-organization-node")!,
                    login: "github"
                ),
                access: OrganizationAccess(
                    accountID: accountID,
                    organizationID: organizationID,
                    state: .available,
                    capabilityRevision: CapabilityRevision(rawValue: "capability")!,
                    capabilities: [],
                    checkedAt: date
                ),
                selectedAt: date
            )
            let node = NormalizedGitHubNode(
                nodeID: nodeID,
                accountID: accountID,
                organizationID: organizationID,
                repositoryID: nil,
                kind: .issue,
                numericID: "1",
                number: 1,
                title: "Derived intelligence",
                state: .open,
                url: URL(string: "https://github.com/github/triage/issues/1")!,
                bodyMarkdown: nil,
                authorID: nil,
                createdAt: date,
                updatedAt: date,
                closedAt: nil,
                mergedAt: nil,
                sourceRevision: "revision",
                observedAt: date,
                accessibility: .accessible
            )
            try await GitHubNodeRepository(vault: vault).save(node)
            workItemID = try await WorkItemRepository(vault: vault).ensureWorkItem(for: node)
        }

        func snapshot(
            reasonID: String,
            title: String,
            ruleID: String = "changesRequested",
            sourceRevision: String? = nil,
            coverageState: DerivedIntelligenceCoverageState = .trusted,
            isProvisional: Bool = false,
            usesLegacyEvidence: Bool = false,
            usesRevisionlessEvidence: Bool = false,
            evidenceSourceRevision: String? = nil,
            confidence: RelationConfidence = .confirmed,
            confirmation: EvidenceConfirmation = .confirmed,
            rawSnapshotID: RawAPISnapshotID? = nil,
            aiCandidates: [DerivedAICandidate] = [],
            aiCandidateExclusions: [DerivedAICandidateExclusion] = []
        ) -> DerivedIntelligencePersistenceSnapshot {
            let isWaitingWakeUp = ruleID == WaitingAttentionRuleID.awaitedActorResponded.rawValue
            let reason = AttentionReason(
                id: reasonID,
                category: isWaitingWakeUp ? .waiting : .pullRequest,
                ruleID: ruleID,
                ruleVersion: 1,
                strength: 900,
                title: "Changes requested",
                explanation: "A reviewer requested changes.",
                evidence: [
                    EvidenceReference(
                        id: EvidenceID(rawValue: "evidence-\(reasonID)")!,
                        source: usesLegacyEvidence
                            ? .legacyUnverified
                            : isWaitingWakeUp ? .localWorkflow : .restReview,
                        locator: usesLegacyEvidence
                            ? .legacyUnverified
                            : isWaitingWakeUp
                            ? .localWorkflow("workflow-state")
                            : .endpoint("/repos/github/triage/pulls/1/reviews"),
                        authority: usesLegacyEvidence
                            ? .legacyUnverified
                            : isWaitingWakeUp
                            ? .localWorkflow(accountID: accountID, organizationID: organizationID)
                            : .github(scope: scope, feature: .reviews, streamID: SyncStreamID(rawValue: "reviews")!),
                        nodeID: nodeID,
                        sourceRevision: usesLegacyEvidence || usesRevisionlessEvidence || isWaitingWakeUp
                            ? nil
                            : evidenceSourceRevision ?? "revision",
                        rawSnapshotID: rawSnapshotID,
                        confidence: confidence,
                        confirmation: confirmation,
                        observedAt: date
                    )
                ],
                evaluatedAt: date
            )
            return DerivedIntelligencePersistenceSnapshot(
                scope: scope,
                sourceRevision: sourceRevision ?? aggregateSourceRevision,
                evaluatedAt: date,
                coverage: CoverageEvaluation(
                    freshness: FreshnessState(status: coverageState == .trusted ? .fresh : .partial, lastSuccessfulSyncAt: date),
                    missing: coverageState == .incomplete
                        ? [CoverageRequirement(feature: .reviews, repositoryID: nil, streamID: SyncStreamID(rawValue: "reviews")!)]
                        : []
                ),
                coverageState: coverageState,
                isProvisional: isProvisional,
                items: [
                    DerivedIntelligencePersistenceItem(
                        workItemID: workItemID,
                        attentionReasons: [reason],
                        score: AttentionScore(value: 900, breakdown: ["attentionReason": 900]),
                        searchDocument: SearchDocument(
                            accountID: accountID,
                            organizationID: organizationID,
                            workItemID: workItemID,
                            nodeID: nodeID,
                            title: title,
                            body: "",
                            repository: "",
                            labels: "",
                            people: "",
                            projectValues: "",
                            actionText: "",
                            localNote: ""
                        )
                    )
                ],
                aiCandidates: aiCandidates,
                aiCandidateExclusions: aiCandidateExclusions
            )
        }

        func candidateSnapshot(reasonID: String) -> DerivedIntelligencePersistenceSnapshot {
            snapshot(
                reasonID: reasonID,
                title: "Candidate \(reasonID)",
                aiCandidates: [
                    DerivedAICandidate(
                        id: "candidate-\(reasonID)",
                        workItemID: workItemID,
                        score: AttentionScore(value: 900, breakdown: ["attentionReason": 900]),
                        triggerReasonIDs: [reasonID]
                    )
                ]
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }

        var aggregateSourceRevision: String {
            var material = Data("triage.derived-input.source-revision.v1".utf8)
            appendLengthPrefixed(Data(workItemID.rawValue.utf8), to: &material)
            appendLengthPrefixed(Data("revision".utf8), to: &material)
            return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        }

        private func appendLengthPrefixed(_ value: Data, to material: inout Data) {
            var length = UInt64(value.count).bigEndian
            Swift.withUnsafeBytes(of: &length) { material.append(contentsOf: $0) }
            material.append(value)
        }

        static func milliseconds(_ date: Date) -> Int64 {
            Int64((date.timeIntervalSince1970 * 1_000).rounded())
        }
    }
}

private final class ProjectionValidationQueryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private actor ProjectionGate {
    private var opened = false
    private var didEnter = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entered: CheckedContinuation<Void, Never>?

    func wait() async {
        didEnter = true
        entered?.resume()
        entered = nil
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { entered = $0 }
    }

    func open() {
        opened = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping @Sendable () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {
        // Expected.
    }
}
