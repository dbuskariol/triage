import Foundation
import GRDB
import XCTest
@testable import Triage

final class DerivedIntelligenceEndToEndIntegrationTests: XCTestCase {
    func testAuthoritativeHydrationRoleAndTimelineSourcesDriveProductionAttentionRules() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.seedAuthoritativeRuleSources()

        try await OrganizationWorkItemGraphProjectionService(vault: fixture.vault)
            .projectAfterNormalizedCommit(for: fixture.scope, at: fixture.now)

        let snapshot = try await DerivedIntelligenceInputAdapter(vault: fixture.vault).snapshot(
            for: fixture.scope,
            aiPolicy: fixture.aiPolicy,
            evaluatedAt: fixture.now
        )
        XCTAssertEqual(
            snapshot.sourceStates.first {
                $0.workItemID == fixture.workItemID && $0.feature == .statusChecks
            }?.availability,
            .trusted
        )
        let output = try DerivedIntelligenceCoordinator().recompute(snapshot.input)
        let result = try XCTUnwrap(output.items.first)
        let ruleIDs = Set(result.attentionReasons.map(\.ruleID))
        XCTAssertTrue(ruleIDs.contains(AttentionRuleID.assignedToCurrentUser.rawValue))
        XCTAssertTrue(ruleIDs.contains(ConversationAttentionRuleID.directMentionAfterProgress.rawValue))
        XCTAssertTrue(ruleIDs.contains(WaitingAttentionRuleID.awaitedActorResponded.rawValue))
    }

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
        // Normalized review rows alone are deliberately not a current source:
        // the fixture has organization coverage but no immutable, candidate-
        // revision-qualified complete-traversal receipt.  Keeping those rows
        // out avoids treating a stale or partial review refresh as trusted
        // derived input while their revisions still fence persistence.
        XCTAssertTrue(inputSnapshot.input.items[0].pullRequestReviews.isEmpty)
        XCTAssertTrue(inputSnapshot.input.items[0].pullRequestReviewThreads.isEmpty)
        XCTAssertEqual(
            inputSnapshot.sourceStates.filter { $0.feature == .reviews || $0.feature == .reviewThreads },
            [
                .init(workItemID: fixture.workItemID, feature: .reviewThreads, availability: .excluded),
                .init(workItemID: fixture.workItemID, feature: .reviews, availability: .excluded)
            ]
        )
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
        let accountID = AccountID(rawValue: "00000000-0000-4000-8000-000000000201")!
        let organizationID = OrganizationID(rawValue: "derived-e2e-org")!
        let accountNodeID = GitHubNodeID(rawValue: "derived-e2e-user")!
        let repositoryID = RepositoryID(rawValue: "derived-e2e-repository")!
        let pullRequestNodeID = GitHubNodeID(rawValue: "derived-e2e-pr")!
        let reviewNodeID = GitHubNodeID(rawValue: "derived-e2e-review")!
        let reviewThreadNodeID = GitHubNodeID(rawValue: "derived-e2e-review-thread")!
        let reviewerNodeID = GitHubNodeID(rawValue: "derived-e2e-reviewer")!
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

        func seedAuthoritativeRuleSources() async throws {
            // Node freshness and status-check authority are deliberately
            // distinct: the former is updated-at based, while the latter is
            // the immutable PR head commit SHA.
            let primaryRevision = now.ISO8601Format()
            let headCommitSHA = String(repeating: "a", count: 64)
            try await vault.write { database in
                try database.execute(
                    sql: """
                        INSERT OR IGNORE INTO repositories (
                            id, organization_id, github_repository_id, github_node_id,
                            owner_login, name, is_private, is_archived, has_discussions,
                            html_url, updated_at_ms, archived_at_ms
                        ) VALUES (?, ?, 1, ?, 'acme', 'derived-e2e', 1, 0, 1, ?, ?, NULL)
                        """,
                    arguments: [
                        repositoryID.rawValue,
                        organizationID.rawValue,
                        "derived-e2e-repository-node",
                        "https://github.com/acme/derived-e2e",
                        milliseconds(now)
                    ]
                )
            }
            try await GitHubNodeRepository(vault: vault).save(
                Self.node(
                    id: pullRequestNodeID,
                    accountID: accountID,
                    organizationID: organizationID,
                    repositoryID: repositoryID,
                    now: now,
                    kind: .pullRequest,
                    title: "Derived end-to-end pull request",
                    sourceRevision: primaryRevision,
                    pullRequestHeadCommitSHA: headCommitSHA,
                    body: "Normalized pull request body"
                )
            )
            let hydrationStreamID = SyncStreamID(rawValue: "hydration-pull-requests-\(organizationID.rawValue)")!
            try await saveCoverage(.pullRequests, stream: hydrationStreamID.rawValue)
            let statusCheckStreamID = PullRequestStatusCheckRefreshService.sourceStreamID(
                organizationID: organizationID,
                pullRequestNodeID: pullRequestNodeID,
                sourceRevision: headCommitSHA
            )
            let statusCheckCoverage = CoverageRecord(
                accountID: accountID,
                organizationID: organizationID,
                repositoryID: repositoryID,
                feature: .statusChecks,
                streamID: statusCheckStreamID,
                intervalStart: nil,
                intervalEnd: nil,
                credentialRevision: credentialRevision,
                capabilityRevision: capabilityRevision,
                status: .complete,
                lastSuccessfulAt: now,
                failureDetail: nil
            )
            try await StatusCheckRepository(vault: vault).replace(
                .init(
                    mergeableState: "MERGEABLE",
                    checks: [],
                    sourceRevision: headCommitSHA,
                    observedAt: now
                ),
                authority: .init(
                    scope: scope,
                    pullRequestNodeID: pullRequestNodeID,
                    pullRequestSourceRevision: headCommitSHA,
                    streamID: statusCheckStreamID,
                    schedulingStreamID: SyncStreamID(
                        rawValue: "pull-request-status-checks-\(organizationID.rawValue)"
                    )!,
                    observedAt: now
                ),
                coverage: statusCheckCoverage,
                attemptedAt: now
            )
            let statusSnapshot = try await StatusCheckRepository(vault: vault).snapshot(
                pullRequestNodeID: pullRequestNodeID,
                scope: scope
            )
            XCTAssertEqual(statusSnapshot?.sourceRevision, headCommitSHA)
            try await ActorRepository(vault: vault).save(
                ActorSummary(
                    id: ActorID(rawValue: reviewerNodeID.rawValue)!,
                    nodeID: reviewerNodeID,
                    login: "reviewer",
                    displayName: nil,
                    avatarURL: nil
                ),
                observedAt: now
            )
            let hydrationPayload = Data("""
                {"data":{"nodes":[{"id":"\(pullRequestNodeID.rawValue)","author":{"id":"\(accountNodeID.rawValue)"},"assignees":{"nodes":[{"id":"\(accountNodeID.rawValue)"}],"pageInfo":{"hasNextPage":false}},"reviewRequests":{"nodes":[{"requestedReviewer":{"id":"\(reviewerNodeID.rawValue)","login":"reviewer"}}],"pageInfo":{"hasNextPage":false}}}]}}
                """.utf8)
            try await RawAPISnapshotRepository(vault: vault).save(
                RawAPISnapshot(
                    id: RawAPISnapshotID(rawValue: "derived-e2e-hydration-rules")!,
                    accountID: accountID,
                    githubNodeID: pullRequestNodeID,
                    endpoint: "graphql:TriageHydrateNodes",
                    eTag: nil,
                    parserVersion: 2,
                    observedAt: now,
                    payload: hydrationPayload,
                    requestIdentity: ConditionalRequestIdentity(
                        scope: scope,
                        feature: .pullRequests,
                        streamID: hydrationStreamID,
                        requestKey: "graphql:TriageHydrateNodes/node=\(pullRequestNodeID.rawValue)"
                    )
                )
            )

            let mentionStreamID = SyncStreamID(rawValue: "role-discovery-\(organizationID.rawValue)-open-direct-mentions")!
            try await SyncStreamRepository(vault: vault).save(
                SyncStream(
                    id: mentionStreamID,
                    accountID: accountID,
                    organizationID: organizationID,
                    feature: .roleDiscovery,
                    highWater: nil,
                    lastSuccessfulAt: now,
                    lastAttemptAt: now,
                    status: .complete,
                    failureDetail: nil
                )
            )
            try await saveCoverage(.roleDiscovery, stream: mentionStreamID.rawValue)
            let mentionQuery = try GitHubIssueSearchQuery(
                organizationLogin: "acme",
                userLogin: "octocat",
                state: .open,
                relationship: .mentioned
            )
            let mentionIdentity = try GitHubIssueSearchRequestIdentity(
                query: mentionQuery,
                page: 1,
                scope: scope,
                streamID: mentionStreamID
            )
            let timestamp = now.ISO8601Format()
            let mentionSnapshot = RawAPISnapshot(
                id: RawAPISnapshotID(rawValue: "derived-e2e-direct-mention")!,
                accountID: accountID,
                githubNodeID: nil,
                endpoint: mentionIdentity.endpoint,
                eTag: "\"derived-e2e-direct-mention\"",
                parserVersion: GitHubIssueSearchRequestIdentity.parserVersion,
                observedAt: now,
                payload: Data("""
                    {"total_count":1,"incomplete_results":false,"items":[{"id":1,"node_id":"\(pullRequestNodeID.rawValue)","number":1,"title":"Derived end-to-end pull request","state":"open","html_url":"https://github.com/acme/repo/pull/1","created_at":"\(timestamp)","updated_at":"\(timestamp)","closed_at":null,"pull_request":{"url":"https://api.github.com/repos/acme/repo/pulls/1"},"repository_url":"https://api.github.com/repos/acme/repo"}]}
                    """.utf8),
                requestIdentity: ConditionalRequestIdentity(
                    scope: scope,
                    feature: .roleDiscovery,
                    streamID: mentionStreamID,
                    requestKey: mentionIdentity.requestKey
                )
            )
            try await RawAPISnapshotRepository(vault: vault).save(mentionSnapshot)
            try await RoleSearchPageReplayRepository(vault: vault).save(
                RoleSearchPageReplay(
                    requestKey: mentionIdentity.requestKey,
                    accountID: accountID,
                    organizationID: organizationID,
                    streamID: mentionStreamID,
                    queryValue: mentionQuery.value,
                    page: 1,
                    endpoint: mentionIdentity.endpoint,
                    credentialRevision: credentialRevision,
                    capabilityRevision: capabilityRevision,
                    rawSnapshotID: mentionSnapshot.id,
                    eTag: mentionSnapshot.eTag,
                    lastModified: nil,
                    parserVersion: GitHubIssueSearchRequestIdentity.parserVersion,
                    lastValidatedAt: now
                )
            )

            try await saveCoverage(.timelines, stream: "timelines-\(organizationID.rawValue)")
            try await saveCoverage(
                .timelines,
                stream: "timeline:\(pullRequestNodeID.rawValue)",
                repositoryID: repositoryID
            )
            try await TimelineRepository(vault: vault).save(
                TimelineEventSummary(
                    id: GitHubEventID(rawValue: "derived-e2e-reviewer-response")!,
                    subjectNodeID: pullRequestNodeID,
                    kind: .commented,
                    actor: ActorSummary(
                        id: ActorID(rawValue: reviewerNodeID.rawValue)!,
                        nodeID: reviewerNodeID,
                        login: "reviewer",
                        displayName: nil,
                        avatarURL: nil
                    ),
                    occurredAt: now,
                    url: nil,
                    body: "Authoritative reviewer response"
                ),
                sourceRevision: primaryRevision
            )
            let timelineSnapshotID = RawAPISnapshotID(rawValue: "derived-e2e-timeline-rules")!
            try await RawAPISnapshotRepository(vault: vault).save(
                RawAPISnapshot(
                    id: timelineSnapshotID,
                    accountID: accountID,
                    githubNodeID: pullRequestNodeID,
                    endpoint: "/repos/acme/repo/issues/1/timeline?page=1",
                    eTag: "timeline-rules-etag",
                    parserVersion: 1,
                    observedAt: now,
                    payload: Data("[]".utf8),
                    requestIdentity: ConditionalRequestIdentity(
                        scope: scope,
                        feature: .timelines,
                        streamID: SyncStreamID(rawValue: "timeline:\(pullRequestNodeID.rawValue)")!,
                        requestKey: "GET /repos/acme/repo/issues/1/timeline?page=1"
                    )
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
                        capabilityRevision.rawValue, primaryRevision, timelineSnapshotID.rawValue,
                        "GET /repos/acme/repo/issues/1/timeline?page=1", milliseconds(now)
                    ]
                )
            }
            try await WorkflowRepository(vault: vault).save(
                WorkflowState(status: .waiting, updatedAt: now.addingTimeInterval(-1)),
                for: workItemID
            )
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

        private func saveCoverage(
            _ feature: CoverageFeature,
            stream: String,
            repositoryID: RepositoryID? = nil
        ) async throws {
            try await CoverageRepository(vault: vault).save(
                CoverageRecord(
                    accountID: accountID,
                    organizationID: organizationID,
                    repositoryID: repositoryID,
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
            repositoryID: RepositoryID? = nil,
            now: Date,
            kind: GitHubContentKind,
            title: String,
            sourceRevision: String,
            pullRequestHeadCommitSHA: String? = nil,
            body: String?
        ) -> NormalizedGitHubNode {
            NormalizedGitHubNode(
                nodeID: id,
                accountID: accountID,
                organizationID: organizationID,
                repositoryID: repositoryID,
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
                pullRequestHeadCommitSHA: kind == .pullRequest
                    ? (pullRequestHeadCommitSHA ?? String(repeating: "b", count: 64))
                    : nil,
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
