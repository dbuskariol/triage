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
            "provisional", "provisional", "review-source-revision"
        ])
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

    func testExplicitLegacyEvidencePersistsOnlyAsProvisionalEvidence() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = DerivedIntelligenceRepository(vault: fixture.vault)
        try await repository.replace(
            fixture.snapshot(
                reasonID: "legacy",
                title: "Legacy title",
                usesLegacyEvidence: true
            )
        )

        let persistedAuthority = try await fixture.vault.read { database -> [String]? in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT authority_kind, confidence, confirmation
                    FROM rule_evaluation_evidence
                    WHERE rule_evaluation_id = 'legacy'
                    """
            ),
            let authorityKind: String = row["authority_kind"],
            let confidence: String = row["confidence"],
            let confirmation: String = row["confirmation"]
            else {
                return nil
            }
            return [authorityKind, confidence, confirmation]
        }
        let authority = try XCTUnwrap(persistedAuthority)
        XCTAssertEqual(authority, ["legacyUnverified", "provisional", "provisional"])
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
            fixture.snapshot(reasonID: "valid-legacy", title: "Valid legacy title", usesLegacyEvidence: true)
        )
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
                    arguments: ["valid-legacy", Fixture.milliseconds(fixture.date)]
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
        let accountID = AccountID(rawValue: "derived-account")!
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
                        sourceRevision: usesLegacyEvidence || isWaitingWakeUp ? nil : "review-source-revision",
                        rawSnapshotID: rawSnapshotID,
                        confidence: .provisional,
                        confirmation: .provisional,
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
