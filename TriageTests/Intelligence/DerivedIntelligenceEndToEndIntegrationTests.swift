import Foundation
import GRDB
import XCTest
@testable import Triage

final class DerivedIntelligenceEndToEndIntegrationTests: XCTestCase {
    func testRevisionQualifiedNormalizedSourcesRemainProvisionalThroughPersistenceAndWorkspaceProjection() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.seedNormalizedSources()

        let inputSnapshot = try await DerivedIntelligenceInputAdapter(vault: fixture.vault).snapshot(
            for: fixture.scope,
            aiPolicy: fixture.aiPolicy,
            evaluatedAt: fixture.now
        )
        XCTAssertTrue(inputSnapshot.isProvisional)
        XCTAssertEqual(inputSnapshot.input.items.count, 1)
        XCTAssertEqual(inputSnapshot.input.items[0].pullRequestReviews.map(\.id), [fixture.reviewNodeID])
        XCTAssertEqual(inputSnapshot.input.items[0].timeline.map(\.id), [fixture.timelineEventID])
        XCTAssertTrue(inputSnapshot.input.items[0].searchDocument.projectValues.contains("Priority: High"))

        let output = try DerivedIntelligenceCoordinator().recompute(inputSnapshot.input)
        XCTAssertEqual(output.coverageState, .incomplete)
        XCTAssertTrue(output.aiCandidates.isEmpty)
        XCTAssertEqual(
            output.aiCandidateExclusions,
            [.init(workItemID: fixture.workItemID, reason: .incompleteCoverage)]
        )

        try await DerivedIntelligenceRepository(vault: fixture.vault).replace(
            persistenceSnapshot(output: output, input: inputSnapshot)
        )
        let persistedProjection = try await DerivedIntelligenceRepository(vault: fixture.vault).projection(
            for: fixture.scope
        )
        let projection = try XCTUnwrap(persistedProjection)
        XCTAssertEqual(projection.run.sourceRevision, inputSnapshot.aggregateSourceRevision)
        XCTAssertEqual(projection.run.coverageState, .incomplete)
        XCTAssertTrue(projection.run.isProvisional)
        XCTAssertEqual(projection.candidates.compactMap { $0.exclusion?.reason }, [.incompleteCoverage])

        let workspace = try await fixture.vault.read { database in
            try WorkspaceDatabaseObservationService.snapshot(
                in: database,
                scope: fixture.scope,
                selectedWorkItemID: fixture.workItemID
            )
        }
        XCTAssertEqual(workspace.workItems.map(\.id), [fixture.workItemID])
        XCTAssertEqual(workspace.menuCounts.allWork, 1)
        XCTAssertEqual(workspace.freshness.status, .partial)
    }

    func testCredentialRotationRejectsPreviouslyDerivedPersistenceAndProjection() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.seedNormalizedSources()
        let inputSnapshot = try await DerivedIntelligenceInputAdapter(vault: fixture.vault).snapshot(
            for: fixture.scope,
            aiPolicy: fixture.aiPolicy,
            evaluatedAt: fixture.now
        )
        let output = try DerivedIntelligenceCoordinator().recompute(inputSnapshot.input)
        let persisted = persistenceSnapshot(output: output, input: inputSnapshot)
        let repository = DerivedIntelligenceRepository(vault: fixture.vault)
        try await repository.replace(persisted)

        try await fixture.rotateCredentialRevision()
        do {
            _ = try await DerivedIntelligenceInputAdapter(vault: fixture.vault).snapshot(
                for: fixture.scope,
                aiPolicy: fixture.aiPolicy,
                evaluatedAt: fixture.now
            )
            XCTFail("The pre-rotation scope must not create new derived input.")
        } catch {
            XCTAssertEqual(error as? DerivedIntelligenceInputAdapterError, .staleSynchronizationScope)
        }
        do {
            try await repository.replace(persisted)
            XCTFail("A pre-rotation derived result must not replace current state.")
        } catch {
            XCTAssertEqual(error as? DerivedIntelligenceRepositoryError, .staleSynchronizationScope)
        }
        do {
            _ = try await repository.projection(for: fixture.scope)
            XCTFail("A pre-rotation derived projection must not be readable as current.")
        } catch {
            XCTAssertEqual(error as? DerivedIntelligenceRepositoryError, .staleSynchronizationScope)
        }
    }

    func testPrimaryRevisionChangeInvalidatesAggregateAndRejectsStalePersistence() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.seedNormalizedSources()
        let adapter = DerivedIntelligenceInputAdapter(vault: fixture.vault)
        let initial = try await adapter.snapshot(
            for: fixture.scope,
            aiPolicy: fixture.aiPolicy,
            evaluatedAt: fixture.now
        )
        let output = try DerivedIntelligenceCoordinator().recompute(initial.input)
        let persisted = persistenceSnapshot(output: output, input: initial)
        let repository = DerivedIntelligenceRepository(vault: fixture.vault)

        try await fixture.advancePrimarySourceRevision()
        let refreshed = try await adapter.snapshot(
            for: fixture.scope,
            aiPolicy: fixture.aiPolicy,
            evaluatedAt: fixture.now
        )

        XCTAssertEqual(initial.sourceRevisions[fixture.workItemID], "derived-e2e-pr-r1")
        XCTAssertEqual(refreshed.sourceRevisions[fixture.workItemID], "derived-e2e-pr-r2")
        XCTAssertNotEqual(initial.aggregateSourceRevision, refreshed.aggregateSourceRevision)
        XCTAssertTrue(refreshed.isProvisional, "Old timeline-page membership cannot certify a new primary revision.")
        do {
            try await repository.replace(persisted)
            XCTFail("A source-revision-stale derived snapshot must not be persisted.")
        } catch {
            XCTAssertEqual(error as? DerivedIntelligenceRepositoryError, .staleSourceRevision)
        }
    }

    func testSupplementalReviewAndThreadRevisionsInvalidateAggregateAndPersistence() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.seedNormalizedSources()
        let adapter = DerivedIntelligenceInputAdapter(vault: fixture.vault)
        let initial = try await adapter.snapshot(for: fixture.scope, aiPolicy: fixture.aiPolicy, evaluatedAt: fixture.now)
        let output = try DerivedIntelligenceCoordinator().recompute(initial.input)
        let persisted = persistenceSnapshot(output: output, input: initial)
        let repository = DerivedIntelligenceRepository(vault: fixture.vault)

        try await fixture.advanceReviewSourceRevision()
        let afterReview = try await adapter.snapshot(for: fixture.scope, aiPolicy: fixture.aiPolicy, evaluatedAt: fixture.now)
        try await fixture.advanceReviewThreadSourceRevision()
        let refreshed = try await adapter.snapshot(for: fixture.scope, aiPolicy: fixture.aiPolicy, evaluatedAt: fixture.now)

        XCTAssertNotEqual(initial.aggregateSourceRevision, afterReview.aggregateSourceRevision)
        XCTAssertNotEqual(afterReview.aggregateSourceRevision, refreshed.aggregateSourceRevision)
        do {
            try await repository.replace(persisted)
            XCTFail("A revision-stale review-thread authority must not be persisted.")
        } catch {
            XCTAssertEqual(error as? DerivedIntelligenceRepositoryError, .staleSourceRevision)
        }
    }

    func testProjectFieldValueChangeInvalidatesAggregateAndPersistence() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.seedNormalizedSources()
        let adapter = DerivedIntelligenceInputAdapter(vault: fixture.vault)
        let initial = try await adapter.snapshot(for: fixture.scope, aiPolicy: fixture.aiPolicy, evaluatedAt: fixture.now)
        let output = try DerivedIntelligenceCoordinator().recompute(initial.input)
        let persisted = persistenceSnapshot(output: output, input: initial)
        let repository = DerivedIntelligenceRepository(vault: fixture.vault)

        try await fixture.updateProjectFieldValue(to: "Urgent")
        let refreshed = try await adapter.snapshot(for: fixture.scope, aiPolicy: fixture.aiPolicy, evaluatedAt: fixture.now)

        XCTAssertNotEqual(initial.aggregateSourceRevision, refreshed.aggregateSourceRevision)
        do {
            try await repository.replace(persisted)
            XCTFail("A changed project-field authority must not be persisted under the old aggregate.")
        } catch {
            XCTAssertEqual(error as? DerivedIntelligenceRepositoryError, .staleSourceRevision)
        }
    }

    private func persistenceSnapshot(
        output: DerivedIntelligenceOutput,
        input: DerivedIntelligenceInputSnapshot
    ) -> DerivedIntelligencePersistenceSnapshot {
        DerivedIntelligencePersistenceSnapshot(
            scope: input.input.scope,
            sourceRevision: input.aggregateSourceRevision,
            evaluatedAt: input.input.evaluatedAt,
            coverage: output.coverage,
            coverageState: output.coverageState,
            isProvisional: input.isProvisional,
            items: output.items.map {
                DerivedIntelligencePersistenceItem(
                    workItemID: $0.workItemID,
                    attentionReasons: $0.attentionReasons,
                    score: $0.score,
                    searchDocument: $0.searchDocument
                )
            },
            aiCandidates: output.aiCandidates,
            aiCandidateExclusions: output.aiCandidateExclusions
        )
    }

    private final class Fixture: @unchecked Sendable {
        let directory: URL
        let accountID = AccountID(rawValue: "derived-e2e-account")!
        let organizationID = OrganizationID(rawValue: "derived-e2e-org")!
        let accountNodeID = GitHubNodeID(rawValue: "derived-e2e-user")!
        let pullRequestNodeID = GitHubNodeID(rawValue: "derived-e2e-pr")!
        let reviewNodeID = GitHubNodeID(rawValue: "derived-e2e-review")!
        let reviewThreadNodeID = GitHubNodeID(rawValue: "derived-e2e-review-thread")!
        let projectNodeID = GitHubNodeID(rawValue: "derived-e2e-project")!
        let projectItemNodeID = GitHubNodeID(rawValue: "derived-e2e-project-item")!
        let timelineEventID = GitHubEventID(rawValue: "derived-e2e-event")!
        let now = Date(timeIntervalSinceReferenceDate: 200_000)
        let vault: AccountVault
        let workItemID: WorkItemID

        let credentialRevision = CredentialRevision(rawValue: "derived-e2e-credential-r1")!
        let capabilityRevision = CapabilityRevision(rawValue: "derived-e2e-capability-r1")!

        var scope: SynchronizationScope {
            SynchronizationScope(
                accountID: accountID,
                organizationID: organizationID,
                credentialRevision: credentialRevision,
                capabilityRevision: capabilityRevision
            )
        }

        let aiPolicy = DerivedAIPolicy(
            isOrganizationConsentActive: true,
            isAuthenticationValid: true,
            isEntitled: true,
            hasAvailableBudget: true
        )

        init() async throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(".derived-e2e-\(UUID().uuidString)", isDirectory: true)
            vault = try await VaultRegistry(rootDirectory: directory).open(
                accountID: accountID,
                vaultKey: try VaultKey.generate()
            )
            try await AccountRepository(vault: vault).save(
                GitHubAccount(
                    id: accountID,
                    githubUserID: 7,
                    nodeID: accountNodeID,
                    login: "octocat",
                    authenticationKind: .oauth,
                    credentialID: CredentialID.make(),
                    credentialStatus: .active,
                    createdAt: now,
                    lastValidatedAt: now
                ),
                credentialRevision: credentialRevision
            )
            try await AccountRepository(vault: vault).save(
                GitHubOrganization(
                    id: organizationID,
                    githubOrganizationID: 8,
                    nodeID: GitHubNodeID(rawValue: "derived-e2e-org-node")!,
                    login: "acme"
                ),
                access: OrganizationAccess(
                    accountID: accountID,
                    organizationID: organizationID,
                    state: .available,
                    capabilityRevision: capabilityRevision,
                    capabilities: [],
                    checkedAt: now
                ),
                selectedAt: now
            )
            let pullRequest = Self.node(
                id: pullRequestNodeID,
                accountID: accountID,
                organizationID: organizationID,
                now: now,
                kind: .pullRequest,
                title: "Derived end-to-end pull request",
                sourceRevision: "derived-e2e-pr-r1",
                body: "Normalized pull request body"
            )
            try await GitHubNodeRepository(vault: vault).save(pullRequest)
            // Finish initializing stored state before the fixture's first
            // database closure captures any fixture members.
            workItemID = try await WorkItemRepository(vault: vault).ensureWorkItem(for: pullRequest)
            try await vault.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO pull_requests (
                            github_node_id, is_draft, mergeable_state, head_ref, base_ref,
                            review_decision, unresolved_thread_count, latest_commit_at_ms, updated_at_ms
                        ) VALUES (?, 0, NULL, NULL, NULL, NULL, 0, NULL, ?)
                        """,
                    arguments: [pullRequestNodeID.rawValue, milliseconds(now)]
                )
            }
            try await OrganizationSchedulerStateRepository(vault: vault).save(
                OrganizationSchedulerState(
                    accountID: accountID,
                    organizationID: organizationID,
                    credentialRevision: credentialRevision,
                    capabilityRevision: capabilityRevision,
                    nextIncrementalRefreshAt: now.addingTimeInterval(600),
                    nextFullReconciliationAt: now.addingTimeInterval(3_600),
                    rateLimitedUntil: nil,
                    blockedReason: nil,
                    consecutiveTransientFailureCount: 0,
                    activeAttemptID: nil,
                    lastAttemptAt: now,
                    lastCompletedAt: now,
                    generation: 1,
                    updatedAt: now
                )
            )
        }

        func seedNormalizedSources() async throws {
            try await saveCoverage(.pullRequests, stream: "hydration-pull-requests-\(organizationID.rawValue)")
            try await saveCoverage(.reviews, stream: "pull-request-reviews-\(organizationID.rawValue)")
            try await saveCoverage(.timelines, stream: "timelines-\(organizationID.rawValue)")
            try await saveCoverage(.timelines, stream: "timeline:\(pullRequestNodeID.rawValue)")
            try await saveCoverage(.projects, stream: "projects-v2-inventory-\(organizationID.rawValue)")
            try await saveCoverage(.projectItems, stream: "projects-v2-items-\(organizationID.rawValue)")
            try await saveCoverage(.projectItems, stream: "projects-v2-items-\(organizationID.rawValue)-\(projectNodeID.rawValue)")
            try await insertCurrentAssignment()
            try await insertReview()
            try await insertReviewThread()
            try await insertTimeline()
            try await insertProjectEvidence()
        }

        func rotateCredentialRevision() async throws {
            let rotated = CredentialRevision(rawValue: "derived-e2e-credential-r2")!
            try await AccountRepository(vault: vault).save(
                GitHubAccount(
                    id: accountID,
                    githubUserID: 7,
                    nodeID: accountNodeID,
                    login: "octocat",
                    authenticationKind: .oauth,
                    credentialID: CredentialID.make(),
                    credentialStatus: .active,
                    createdAt: now,
                    lastValidatedAt: now
                ),
                credentialRevision: rotated
            )
        }

        func advancePrimarySourceRevision() async throws {
            try await GitHubNodeRepository(vault: vault).save(
                Self.node(
                    id: pullRequestNodeID,
                    accountID: accountID,
                    organizationID: organizationID,
                    now: now,
                    kind: .pullRequest,
                    title: "Derived end-to-end pull request",
                    sourceRevision: "derived-e2e-pr-r2",
                    body: "Normalized pull request body after a source update"
                )
            )
        }

        func advanceReviewThreadSourceRevision() async throws {
            try await GitHubNodeRepository(vault: vault).save(
                Self.node(
                    id: reviewThreadNodeID,
                    accountID: accountID,
                    organizationID: organizationID,
                    now: now,
                    kind: .pullRequestReviewThread,
                    title: "Review thread",
                    sourceRevision: "derived-e2e-review-thread-r2",
                    body: nil
                )
            )
        }

        func advanceReviewSourceRevision() async throws {
            try await GitHubNodeRepository(vault: vault).save(
                Self.node(
                    id: reviewNodeID,
                    accountID: accountID,
                    organizationID: organizationID,
                    now: now,
                    kind: .pullRequestReview,
                    title: "Changes requested",
                    sourceRevision: "derived-e2e-review-r2",
                    body: "Please address the review."
                )
            )
        }

        func updateProjectFieldValue(to value: String) async throws {
            try await vault.write { database in
                try database.execute(
                    sql: """
                        UPDATE project_field_values
                        SET display_value = ?
                        WHERE project_item_node_id = ? AND field_name = 'Priority'
                        """,
                    arguments: [value, projectItemNodeID.rawValue]
                )
            }
        }

        private func saveCoverage(_ feature: CoverageFeature, stream: String) async throws {
            try await CoverageRepository(vault: vault).save(
                CoverageRecord(
                    accountID: accountID,
                    organizationID: organizationID,
                    repositoryID: nil,
                    feature: feature,
                    streamID: SyncStreamID(rawValue: stream)!,
                    intervalStart: nil,
                    intervalEnd: nil,
                    credentialRevision: credentialRevision,
                    capabilityRevision: capabilityRevision,
                    status: .complete,
                    lastSuccessfulAt: now,
                    failureDetail: nil
                ),
                attemptedAt: now
            )
        }

        /// The assignment takes the item through AI-candidate evaluation; the
        /// intentionally incomplete global coverage must still exclude it.
        private func insertCurrentAssignment() async throws {
            try await vault.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO relations (
                            id, account_id, subject_node_id, object_node_id, kind,
                            confidence, observed_at_ms
                        ) VALUES (?, ?, ?, ?, 'assigned', 'confirmed', ?)
                        """,
                    arguments: [
                        "derived-e2e-assignment", accountID.rawValue,
                        pullRequestNodeID.rawValue, accountNodeID.rawValue, milliseconds(now)
                    ]
                )
                try database.execute(
                    sql: """
                        INSERT INTO relation_evidence (
                            relation_id, evidence_id, source, source_locator_kind,
                            source_locator, authority_kind, authority_account_id,
                            authority_organization_id, authority_feature,
                            authority_stream_id, authority_credential_revision,
                            authority_capability_revision, source_node_id,
                            source_event_id, source_revision, raw_snapshot_id,
                            confidence, confirmation, observed_at_ms, excerpt
                        ) VALUES (?, ?, 'graphQL', 'query', ?, 'github', ?, ?, ?, ?, ?, ?, ?,
                                  NULL, ?, NULL, 'confirmed', 'confirmed', ?, ?)
                        """,
                    arguments: [
                        "derived-e2e-assignment", "derived-e2e-assignment-evidence",
                        "TriageHydrateNodes", accountID.rawValue, organizationID.rawValue,
                        CoverageFeature.pullRequests.rawValue,
                        "hydration-pull-requests-\(organizationID.rawValue)",
                        credentialRevision.rawValue, capabilityRevision.rawValue,
                        pullRequestNodeID.rawValue, "derived-e2e-pr-r1", milliseconds(now),
                        "The current account is assigned to this pull request."
                    ]
                )
            }
        }

        private func insertReview() async throws {
            try await GitHubNodeRepository(vault: vault).save(
                Self.node(
                    id: reviewNodeID,
                    accountID: accountID,
                    organizationID: organizationID,
                    now: now,
                    kind: .pullRequestReview,
                    title: "Changes requested",
                    sourceRevision: "derived-e2e-review-r1",
                    body: "Please address the review."
                )
            )
            try await vault.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO reviews (
                            github_node_id, pull_request_node_id, author_id, state,
                            body_markdown, submitted_at_ms, html_url, updated_at_ms
                        ) VALUES (?, ?, NULL, 'changesRequested', ?, ?, ?, ?)
                        """,
                    arguments: [
                        reviewNodeID.rawValue, pullRequestNodeID.rawValue,
                        "Please address the review.", milliseconds(now),
                        "https://github.com/acme/repo/pull/1#review", milliseconds(now)
                    ]
                )
            }
        }

        private func insertReviewThread() async throws {
            try await GitHubNodeRepository(vault: vault).save(
                Self.node(
                    id: reviewThreadNodeID,
                    accountID: accountID,
                    organizationID: organizationID,
                    now: now,
                    kind: .pullRequestReviewThread,
                    title: "Review thread",
                    sourceRevision: "derived-e2e-review-thread-r1",
                    body: nil
                )
            )
            try await vault.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO review_threads (
                            github_node_id, pull_request_node_id, is_resolved,
                            requires_current_user_response, updated_at_ms
                        ) VALUES (?, ?, 0, 1, ?)
                        """,
                    arguments: [reviewThreadNodeID.rawValue, pullRequestNodeID.rawValue, milliseconds(now)]
                )
            }
        }

        private func insertTimeline() async throws {
            try await TimelineRepository(vault: vault).save(
                TimelineEventSummary(
                    id: timelineEventID,
                    subjectNodeID: pullRequestNodeID,
                    kind: .commented,
                    actor: nil,
                    occurredAt: now,
                    url: nil,
                    body: "A normalized timeline comment"
                ),
                sourceRevision: "derived-e2e-pr-r1"
            )
            let rawSnapshotID = RawAPISnapshotID(rawValue: "derived-e2e-timeline-raw")!
            try await RawAPISnapshotRepository(vault: vault).save(
                RawAPISnapshot(
                    id: rawSnapshotID,
                    accountID: accountID,
                    githubNodeID: pullRequestNodeID,
                    endpoint: "/repos/acme/repo/issues/1/timeline?page=1",
                    eTag: "timeline-etag",
                    parserVersion: 1,
                    observedAt: now,
                    payload: Data("[]".utf8)
                )
            )
            try await vault.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO timeline_current_pages (
                            account_id, organization_id, github_node_id, feature, stream_id,
                            credential_revision, capability_revision, source_revision, page_index,
                            raw_snapshot_id, request_key, observed_at_ms, is_terminal
                        ) VALUES (?, ?, ?, 'timelines', ?, ?, ?, ?, 1, ?, ?, ?, 1)
                        """,
                    arguments: [
                        accountID.rawValue, organizationID.rawValue, pullRequestNodeID.rawValue,
                        "timeline:\(pullRequestNodeID.rawValue)", credentialRevision.rawValue,
                        capabilityRevision.rawValue, "derived-e2e-pr-r1", rawSnapshotID.rawValue,
                        "GET /repos/acme/repo/issues/1/timeline?page=1", milliseconds(now)
                    ]
                )
            }
        }

        private func insertProjectEvidence() async throws {
            try await GitHubNodeRepository(vault: vault).save(
                Self.node(
                    id: projectNodeID,
                    accountID: accountID,
                    organizationID: organizationID,
                    now: now,
                    kind: .project,
                    title: "Project",
                    sourceRevision: "derived-e2e-project-r1",
                    body: nil
                )
            )
            try await GitHubNodeRepository(vault: vault).save(
                Self.node(
                    id: projectItemNodeID,
                    accountID: accountID,
                    organizationID: organizationID,
                    now: now,
                    kind: .projectItem,
                    title: "Project item",
                    sourceRevision: "derived-e2e-project-item-r1",
                    body: nil
                )
            )
            try await vault.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO projects (github_node_id, organization_id, number, title, state, updated_at_ms)
                        VALUES (?, ?, 1, 'Project', 'open', ?)
                        """,
                    arguments: [projectNodeID.rawValue, organizationID.rawValue, milliseconds(now)]
                )
                try database.execute(
                    sql: """
                        INSERT INTO project_items (
                            github_node_id, project_node_id, content_node_id, content_kind, updated_at_ms
                        ) VALUES (?, ?, ?, 'pullRequest', ?)
                        """,
                    arguments: [projectItemNodeID.rawValue, projectNodeID.rawValue, pullRequestNodeID.rawValue, milliseconds(now)]
                )
                try database.execute(
                    sql: """
                        INSERT INTO project_field_values (
                            project_item_node_id, field_name, display_value, date_value_ms, actor_node_id
                        ) VALUES (?, 'Priority', 'High', NULL, NULL)
                        """,
                    arguments: [projectItemNodeID.rawValue]
                )
            }
        }

        private static func node(
            id: GitHubNodeID,
            accountID: AccountID,
            organizationID: OrganizationID,
            now: Date,
            kind: GitHubContentKind,
            title: String,
            sourceRevision: String,
            body: String?
        ) -> NormalizedGitHubNode {
            NormalizedGitHubNode(
                nodeID: id,
                accountID: accountID,
                organizationID: organizationID,
                repositoryID: nil,
                kind: kind,
                numericID: id.rawValue,
                number: kind == .pullRequest ? 1 : nil,
                title: title,
                state: kind == .pullRequest ? .open : .unknown,
                url: URL(string: "https://github.com/acme/repo/\(id.rawValue)")!,
                bodyMarkdown: body,
                authorID: nil,
                createdAt: now,
                updatedAt: now,
                closedAt: nil,
                mergedAt: nil,
                sourceRevision: sourceRevision,
                observedAt: now,
                accessibility: .accessible
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }

        private func milliseconds(_ date: Date) -> Int64 {
            Int64((date.timeIntervalSince1970 * 1_000).rounded())
        }
    }
}
