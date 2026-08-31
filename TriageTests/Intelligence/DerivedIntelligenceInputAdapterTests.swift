import Foundation
import GRDB
import XCTest
@testable import Triage

final class DerivedIntelligenceInputAdapterTests: XCTestCase {
    func testAdmitsRevisionCurrentReviewDataButMarksMissingStreamsProvisional() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.saveCoverage(feature: .pullRequests, revision: fixture.scope.credentialRevision)
        try await fixture.saveCoverage(feature: .reviews, revision: fixture.scope.credentialRevision)
        try await fixture.insertReview(sourceRevision: "review-r1")
        try await fixture.saveReviewTraversalReceipt()

        let snapshot = try await DerivedIntelligenceInputAdapter(vault: fixture.vault).snapshot(
            for: fixture.scope,
            aiPolicy: fixture.aiPolicy,
            evaluatedAt: fixture.now
        )

        XCTAssertEqual(snapshot.input.items.count, 1)
        XCTAssertEqual(snapshot.input.items[0].pullRequestReviews.map(\.id), [fixture.reviewNodeID])
        XCTAssertTrue(snapshot.input.items[0].pullRequestReviewThreads.isEmpty)
        XCTAssertEqual(snapshot.input.items[0].workItem.freshness.status, .partial)
        XCTAssertTrue(snapshot.isProvisional)
        XCTAssertEqual(
            snapshot.sourceStates.first {
                $0.workItemID == fixture.workItemID && $0.feature == .reviews
            }?.availability,
            .trusted
        )
        XCTAssertEqual(
            snapshot.sourceStates.first {
                $0.workItemID == fixture.workItemID && $0.feature == .reviewThreads
            }?.availability,
            .excluded
        )
        XCTAssertEqual(snapshot.sourceRevisions[fixture.workItemID], "pull-request-r1")
        XCTAssertEqual(snapshot.aggregateSourceRevision.count, 64)
        XCTAssertFalse(snapshot.aggregateSourceRevision.allSatisfy { $0 == "0" })
    }

    func testStaleCredentialCoverageCannotAuthorizePersistedReviewRows() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let staleRevision = CredentialRevision(rawValue: "credential-stale")!
        try await fixture.saveCoverage(feature: .pullRequests, revision: staleRevision)
        try await fixture.saveCoverage(feature: .reviews, revision: staleRevision)
        try await fixture.insertReview(sourceRevision: "review-r1")

        let snapshot = try await DerivedIntelligenceInputAdapter(vault: fixture.vault).snapshot(
            for: fixture.scope,
            aiPolicy: fixture.aiPolicy,
            evaluatedAt: fixture.now
        )

        XCTAssertTrue(snapshot.input.items[0].pullRequestReviews.isEmpty)
        XCTAssertTrue(snapshot.isProvisional)
        XCTAssertEqual(snapshot.input.items[0].workItem.freshness.status, .partial)
        XCTAssertEqual(
            snapshot.sourceStates.first {
                $0.workItemID == fixture.workItemID && $0.feature == .reviews
            }?.availability,
            .excluded
        )
    }

    func testStaleRelationEvidenceIsExcludedFromTheDerivedInputGraph() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let staleCredentialRevision = CredentialRevision(rawValue: "credential-stale")!
        try await fixture.insertAuthoredRelation(credentialRevision: staleCredentialRevision)

        let snapshot = try await DerivedIntelligenceInputAdapter(vault: fixture.vault).snapshot(
            for: fixture.scope,
            aiPolicy: fixture.aiPolicy,
            evaluatedAt: fixture.now
        )

        XCTAssertFalse(snapshot.input.items[0].workItem.relations.contains {
            $0.kind == .authored && $0.objectNodeID == fixture.userNodeID
        })
    }

    func testPartialOrUnavailableReviewCoverageNeverAdmitsPersistedRows() async throws {
        for status in [CoverageStatus.partial, .unavailable] {
            let fixture = try await Fixture()
            defer { fixture.remove() }
            try await fixture.saveCoverage(feature: .pullRequests, status: .complete)
            try await fixture.saveCoverage(feature: .reviews, status: status)
            try await fixture.insertReview(sourceRevision: "review-r1")

            let snapshot = try await DerivedIntelligenceInputAdapter(vault: fixture.vault).snapshot(
                for: fixture.scope,
                aiPolicy: fixture.aiPolicy,
                evaluatedAt: fixture.now
            )

            XCTAssertTrue(snapshot.input.items[0].pullRequestReviews.isEmpty, "\(status) coverage must not authorize retained reviews")
            XCTAssertTrue(snapshot.isProvisional)
            XCTAssertEqual(
                snapshot.sourceStates.first {
                    $0.workItemID == fixture.workItemID && $0.feature == .reviews
                }?.availability,
                .excluded
            )
        }
    }

    func testPartialPrimaryHydrationFromLabelOverflowIsProvisionalAndExcludesAI() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        // A labels connection that exceeds its allowed cardinality fails the
        // primary hydration batch, which is recorded as partial PR coverage.
        try await fixture.saveCoverage(feature: .pullRequests, status: .partial)
        let eligibleAIPolicy = DerivedAIPolicy(
            isOrganizationConsentActive: true,
            isAuthenticationValid: true,
            isEntitled: true,
            hasAvailableBudget: true
        )

        let snapshot = try await DerivedIntelligenceInputAdapter(vault: fixture.vault).snapshot(
            for: fixture.scope,
            aiPolicy: eligibleAIPolicy,
            evaluatedAt: fixture.now
        )

        XCTAssertTrue(snapshot.input.isProvisional)
        XCTAssertEqual(snapshot.input.items[0].workItem.freshness.status, .partial)
        XCTAssertEqual(
            snapshot.sourceStates.first {
                $0.workItemID == fixture.workItemID && $0.feature == .pullRequests
            }?.availability,
            .provisional
        )
        XCTAssertEqual(snapshot.input.items[0].searchDocument.labels, "")

        let output = try DerivedIntelligenceCoordinator().recompute(snapshot.input)
        XCTAssertEqual(output.coverageState, .incomplete)
        XCTAssertTrue(output.aiCandidates.isEmpty)
        // This fixture has no actionable attention reason, so it is not an AI
        // candidate even under complete coverage. The critical regression is
        // that incomplete label authority stays provisional and never queues AI.
    }

    func testOldTimelinePageMembershipDoesNotAppearAsCurrentEmptyOrFreshTimeline() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.saveCoverage(feature: .pullRequests, status: .complete)
        try await fixture.saveCoverage(feature: .timelines, status: .complete)
        try await fixture.saveTimelineCandidateCoverage(status: .complete)
        try await fixture.insertTimeline(
            eventRevision: "pull-request-r0",
            pageRevision: "pull-request-r0"
        )

        let snapshot = try await DerivedIntelligenceInputAdapter(vault: fixture.vault).snapshot(
            for: fixture.scope,
            aiPolicy: fixture.aiPolicy,
            evaluatedAt: fixture.now
        )

        XCTAssertTrue(snapshot.input.items[0].timeline.isEmpty)
        XCTAssertTrue(snapshot.isProvisional)
        XCTAssertEqual(
            snapshot.sourceStates.first {
                $0.workItemID == fixture.workItemID && $0.feature == .timelines
            }?.availability,
            .excluded
        )
    }

    func testCurrentTimelineInputCarriesExactScopeAndSourceRevisionEvidence() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.saveCoverage(feature: .pullRequests, status: .complete)
        try await fixture.saveCoverage(feature: .timelines, status: .complete)
        try await fixture.saveTimelineCandidateCoverage(status: .complete)
        try await fixture.insertTimeline(
            eventRevision: "pull-request-r1",
            pageRevision: "pull-request-r1"
        )

        let snapshot = try await DerivedIntelligenceInputAdapter(vault: fixture.vault).snapshot(
            for: fixture.scope,
            aiPolicy: fixture.aiPolicy,
            evaluatedAt: fixture.now
        )
        let item = try XCTUnwrap(snapshot.input.items.first)
        let event = try XCTUnwrap(item.timeline.first)
        let evidence = try XCTUnwrap(item.timelineEvidence[event.id])

        XCTAssertEqual(evidence.authority, .github(
            scope: fixture.scope,
            feature: .timelines,
            streamID: SyncStreamID(rawValue: "timeline:\(fixture.pullRequestNodeID.rawValue)")!
        ))
        XCTAssertEqual(evidence.sourceRevision, "pull-request-r1")
        XCTAssertEqual(evidence.eventID, event.id)
        XCTAssertNotNil(item.primaryEvidence)
    }

    func testRejectsARequestedScopeWhoseAuthorityRevisionIsNoLongerCurrent() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let staleScope = SynchronizationScope(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: CredentialRevision(rawValue: "not-current")!,
            capabilityRevision: fixture.scope.capabilityRevision
        )

        do {
            _ = try await DerivedIntelligenceInputAdapter(vault: fixture.vault).snapshot(
                for: staleScope,
                aiPolicy: fixture.aiPolicy,
                evaluatedAt: fixture.now
            )
            XCTFail("A stale scope must not be used to derive current intelligence.")
        } catch {
            XCTAssertEqual(error as? DerivedIntelligenceInputAdapterError, .staleSynchronizationScope)
        }
    }

    func testLoadsVaultBackedRepositoryPreferenceAndReturnsTheCurrentPublicationMarker() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let preferences = RepositoryRankingPreferenceRepository(vault: fixture.vault)
        try await preferences.save(
            37,
            for: fixture.repositoryID,
            scope: fixture.scope,
            at: fixture.now
        )

        let adapter = DerivedIntelligenceInputAdapter(vault: fixture.vault)
        let snapshot = try await adapter.snapshot(
            for: fixture.scope,
            aiPolicy: fixture.aiPolicy,
            evaluatedAt: fixture.now
        )
        let currentMarker = try await adapter.currentSourceRevisionMarker(
            for: fixture.scope,
            evaluatedAt: fixture.now
        )

        XCTAssertEqual(snapshot.input.repositoryPreferences, [fixture.repositoryID: 37])
        XCTAssertEqual(snapshot.publicationMarker.scope, fixture.scope)
        XCTAssertEqual(snapshot.publicationMarker.sourceRevision, snapshot.aggregateSourceRevision)
        XCTAssertEqual(currentMarker, snapshot.publicationMarker)

        try await preferences.save(38, for: fixture.repositoryID, scope: fixture.scope, at: fixture.now)
        let changedMarker = try await adapter.currentSourceRevisionMarker(
            for: fixture.scope,
            evaluatedAt: fixture.now
        )
        XCTAssertNotEqual(changedMarker, snapshot.publicationMarker)
    }

    func testAIAnalysisCacheUsesTheExactSelectedModelInItsFingerprintAndKey() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let selectedPolicy = DerivedAIPolicy(
            isOrganizationConsentActive: true,
            isAuthenticationValid: true,
            isEntitled: true,
            hasAvailableBudget: true,
            selectedModelID: "selected-model",
            effectiveModelID: "selected-model"
        )
        let key = try fixture.aiCacheKey(
            selectedModelID: "selected-model",
            effectiveModelID: "selected-model"
        )
        try await AIAnalysisRepository(vault: fixture.vault).save(
            .init(
                id: "selected-model-analysis",
                key: key,
                modelID: "selected-model",
                resultJSON: Data("{}".utf8),
                createdAt: fixture.now
            ),
            for: fixture.scope
        )

        let cached = try await DerivedIntelligenceInputAdapter(vault: fixture.vault).snapshot(
            for: fixture.scope,
            aiPolicy: selectedPolicy,
            evaluatedAt: fixture.now
        )
        XCTAssertFalse(cached.input.items[0].hasChangedAIFingerprint)
        XCTAssertTrue(cached.input.items[0].hasValidCachedAIAnalysis)

        let differentModelPolicy = DerivedAIPolicy(
            isOrganizationConsentActive: true,
            isAuthenticationValid: true,
            isEntitled: true,
            hasAvailableBudget: true,
            selectedModelID: "different-model",
            effectiveModelID: "different-model"
        )
        let uncached = try await DerivedIntelligenceInputAdapter(vault: fixture.vault).snapshot(
            for: fixture.scope,
            aiPolicy: differentModelPolicy,
            evaluatedAt: fixture.now
        )
        XCTAssertTrue(uncached.input.items[0].hasChangedAIFingerprint)
        XCTAssertFalse(uncached.input.items[0].hasValidCachedAIAnalysis)
    }

    private final class Fixture: @unchecked Sendable {
        let directory: URL
        let accountID = AccountID(rawValue: "00000000-0000-4000-8000-000000000202")!
        let organizationID = OrganizationID(rawValue: "derived-adapter-org")!
        let userNodeID = GitHubNodeID(rawValue: "derived-adapter-user")!
        let userActorID = ActorID(rawValue: "derived-adapter-user-actor")!
        let pullRequestNodeID = GitHubNodeID(rawValue: "derived-adapter-pr")!
        let reviewNodeID = GitHubNodeID(rawValue: "derived-adapter-review")!
        let now = Date(timeIntervalSinceReferenceDate: 100_000)
        let vault: AccountVault
        let workItemID: WorkItemID
        let repositoryID: RepositoryID

        var scope: SynchronizationScope {
            SynchronizationScope(
                accountID: accountID,
                organizationID: organizationID,
                credentialRevision: CredentialRevision(rawValue: "credential-current")!,
                capabilityRevision: CapabilityRevision(rawValue: "capability-current")!
            )
        }

        let aiPolicy = DerivedAIPolicy(
            isOrganizationConsentActive: false,
            isAuthenticationValid: false,
            isEntitled: false,
            hasAvailableBudget: false
        )

        init() async throws {
            let credentialRevision = CredentialRevision(rawValue: "credential-current")!
            let capabilityRevision = CapabilityRevision(rawValue: "capability-current")!
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(".derived-input-adapter-\(UUID().uuidString)", isDirectory: true)
            vault = try await VaultRegistry(rootDirectory: directory).open(
                accountID: accountID,
                vaultKey: try VaultKey.generate()
            )
            try await AccountRepository(vault: vault).save(
                GitHubAccount(
                    id: accountID,
                    githubUserID: 1,
                    nodeID: userNodeID,
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
                    githubOrganizationID: 2,
                    nodeID: GitHubNodeID(rawValue: "derived-adapter-org-node")!,
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
            try await ActorRepository(vault: vault).save(
                ActorSummary(
                    id: userActorID,
                    nodeID: userNodeID,
                    login: "octocat",
                    displayName: nil,
                    avatarURL: nil
                ),
                observedAt: now
            )
            let repositories = try await RepositoryInventoryRepository(vault: vault).replace(
                [
                    GitHubRepositoryDTO(
                        id: 3,
                        nodeID: "derived-adapter-repository",
                        name: "repo",
                        isPrivate: true,
                        isArchived: false,
                        hasDiscussions: true,
                        htmlURL: URL(string: "https://github.com/acme/repo")!,
                        updatedAt: now,
                        owner: .init(login: "acme")
                    )
                ],
                accountID: accountID,
                organization: GitHubOrganization(
                    id: organizationID,
                    githubOrganizationID: 2,
                    nodeID: GitHubNodeID(rawValue: "derived-adapter-org-node")!,
                    login: "acme"
                ),
                observedAt: now
            )
            guard let persistedRepositoryID = repositories.first?.id else {
                throw DerivedIntelligenceInputAdapterError.invalidPersistedData
            }
            repositoryID = persistedRepositoryID
            let pullRequest = NormalizedGitHubNode(
                nodeID: pullRequestNodeID,
                accountID: accountID,
                organizationID: organizationID,
                repositoryID: repositoryID,
                kind: .pullRequest,
                numericID: "17",
                number: 17,
                title: "Adapter pull request",
                state: .open,
                url: URL(string: "https://github.com/acme/repo/pull/17")!,
                bodyMarkdown: "Current body",
                authorID: userActorID,
                createdAt: now,
                updatedAt: now,
                closedAt: nil,
                mergedAt: nil,
                sourceRevision: "pull-request-r1",
                observedAt: now,
                accessibility: .accessible
            )
            try await GitHubNodeRepository(vault: vault).save(pullRequest)
            // Complete stored-property initialization before a vault closure
            // captures fixture state.
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
        }

        func saveCoverage(
            feature: CoverageFeature,
            revision: CredentialRevision? = nil,
            status: CoverageStatus = .complete
        ) async throws {
            let stream: String
            switch feature {
            case .pullRequests:
                stream = "hydration-pull-requests-\(organizationID.rawValue)"
            case .reviews:
                stream = "pull-request-reviews-\(organizationID.rawValue)"
            case .timelines:
                stream = "timelines-\(organizationID.rawValue)"
            default:
                fatalError("Unsupported fixture feature")
            }
            try await CoverageRepository(vault: vault).save(
                CoverageRecord(
                    accountID: accountID,
                    organizationID: organizationID,
                    repositoryID: nil,
                    feature: feature,
                    streamID: SyncStreamID(rawValue: stream)!,
                    intervalStart: nil,
                    intervalEnd: nil,
                    credentialRevision: revision ?? scope.credentialRevision,
                    capabilityRevision: scope.capabilityRevision,
                    status: status,
                    lastSuccessfulAt: status == .complete ? now : nil,
                    failureDetail: status == .complete ? nil : "Fixture intentionally lacks complete coverage."
                ),
                attemptedAt: now
            )
        }

        func insertAuthoredRelation(credentialRevision: CredentialRevision) async throws {
            // relation_evidence retains a real stream foreign key even when
            // the evidence is deliberately stale. Materialize that exact
            // historical stream so this fixture exercises the adapter's
            // authority filter rather than violating persistence integrity.
            try await saveCoverage(feature: .pullRequests, revision: credentialRevision)
            try await vault.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO relations (
                            id, account_id, subject_node_id, object_node_id, kind,
                            confidence, observed_at_ms
                        ) VALUES (?, ?, ?, ?, 'authored', 'confirmed', ?)
                        """,
                    arguments: [
                        "derived-adapter-authored-stale",
                        accountID.rawValue,
                        pullRequestNodeID.rawValue,
                        userNodeID.rawValue,
                        milliseconds(now)
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
                                  NULL, 'pull-request-r1', NULL, 'confirmed', 'confirmed', ?, ?)
                        """,
                    arguments: [
                        "derived-adapter-authored-stale",
                        "derived-adapter-authored-stale-evidence",
                        "TriageHydrateNodes",
                        accountID.rawValue,
                        organizationID.rawValue,
                        CoverageFeature.pullRequests.rawValue,
                        "hydration-pull-requests-\(organizationID.rawValue)",
                        credentialRevision.rawValue,
                        scope.capabilityRevision.rawValue,
                        pullRequestNodeID.rawValue,
                        milliseconds(now),
                        "Stale authored relation"
                    ]
                )
            }
        }

        func insertReview(sourceRevision: String) async throws {
            let reviewNode = NormalizedGitHubNode(
                nodeID: reviewNodeID,
                accountID: accountID,
                organizationID: organizationID,
                repositoryID: nil,
                kind: .pullRequestReview,
                numericID: "18",
                number: nil,
                title: "Review",
                state: .unknown,
                url: URL(string: "https://github.com/acme/repo/pull/17#review")!,
                bodyMarkdown: "Please revise this.",
                authorID: nil,
                createdAt: now,
                updatedAt: now,
                closedAt: nil,
                mergedAt: nil,
                sourceRevision: sourceRevision,
                observedAt: now,
                accessibility: .accessible
            )
            try await GitHubNodeRepository(vault: vault).save(reviewNode)
            try await vault.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO reviews (
                            github_node_id, pull_request_node_id, author_id, state,
                            body_markdown, submitted_at_ms, html_url, updated_at_ms
                        ) VALUES (?, ?, NULL, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        reviewNodeID.rawValue, pullRequestNodeID.rawValue,
                        ReviewState.changesRequested.rawValue, "Please revise this.",
                        milliseconds(now), "https://github.com/acme/repo/pull/17#review", milliseconds(now)
                    ]
                )
            }
        }

        func saveReviewTraversalReceipt() async throws {
            let streamID = SyncStreamID(rawValue: "pull-request-reviews-\(organizationID.rawValue)")!
            let review = GitHubPullRequestReviewDTO(
                id: 18,
                nodeID: reviewNodeID.rawValue,
                state: "CHANGES_REQUESTED",
                body: "Please revise this.",
                submittedAt: now
            )
            let requestedReviewers = GitHubRequestedReviewersDTO(users: [], teams: [])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let reviewPayload = try encoder.encode([review])
            let requestedReviewerPayload = try encoder.encode(requestedReviewers)
            func page(
                endpoint: String,
                payload: Data
            ) -> ReviewCandidateTraversalPage {
                let requestKey = "GET /repos/acme/repo/pulls/17/\(endpoint)"
                    + (endpoint == "reviews" ? "?per_page=100" : "")
                return ReviewCandidateTraversalPage(
                    ordinal: 1,
                    rawSnapshotID: .make(),
                    requestIdentity: .init(
                        scope: scope,
                        feature: .reviews,
                        streamID: streamID,
                        requestKey: requestKey
                    ),
                    endpoint: requestKey,
                    payload: payload,
                    isTerminal: true
                )
            }
            _ = try await ReviewCandidateCompleteTraversalReceiptRepository(vault: vault).persist(
                .init(
                    scope: scope,
                    feature: .reviews,
                    streamID: streamID,
                    candidate: .init(
                        nodeID: pullRequestNodeID,
                        repositoryID: repositoryID,
                        repository: try GitHubRepositoryPath(owner: "acme", repository: "repo"),
                        number: 17,
                        sourceRevision: "pull-request-r1"
                    ),
                    candidateSourceRevision: "pull-request-r1",
                    parserVersion: 1,
                    observedAt: now,
                    normalizedDigest: PullRequestReviewReplacementProof.normalizedDigest(
                        reviews: [review],
                        requestedReviewers: requestedReviewers
                    ),
                    segments: [
                        .init(
                            kind: .reviewHistory,
                            pages: [page(endpoint: "reviews", payload: reviewPayload)]
                        ),
                        .init(
                            kind: .requestedReviewers,
                            pages: [page(
                                endpoint: "requested_reviewers",
                                payload: requestedReviewerPayload
                            )]
                        )
                    ]
                )
            )
        }

        func saveTimelineCandidateCoverage(status: CoverageStatus) async throws {
            try await CoverageRepository(vault: vault).save(
                CoverageRecord(
                    accountID: accountID,
                    organizationID: organizationID,
                    repositoryID: repositoryID,
                    feature: .timelines,
                    streamID: SyncStreamID(rawValue: "timeline:\(pullRequestNodeID.rawValue)")!,
                    intervalStart: nil,
                    intervalEnd: nil,
                    credentialRevision: scope.credentialRevision,
                    capabilityRevision: scope.capabilityRevision,
                    status: status,
                    lastSuccessfulAt: status == .complete ? now : nil,
                    failureDetail: status == .complete ? nil : "Fixture intentionally lacks current timeline coverage."
                ),
                attemptedAt: now
            )
        }

        func insertTimeline(eventRevision: String, pageRevision: String) async throws {
            let eventID = GitHubEventID(rawValue: "derived-adapter-timeline-event")!
            let rawSnapshotID = RawAPISnapshotID(rawValue: "derived-adapter-timeline-raw")!
            try await TimelineRepository(vault: vault).save(
                TimelineEventSummary(
                    id: eventID,
                    subjectNodeID: pullRequestNodeID,
                    kind: .commented,
                    actor: nil,
                    occurredAt: now,
                    url: nil,
                    body: "Older timeline event"
                ),
                sourceRevision: eventRevision
            )
            try await RawAPISnapshotRepository(vault: vault).save(
                RawAPISnapshot(
                    id: rawSnapshotID,
                    accountID: accountID,
                    githubNodeID: pullRequestNodeID,
                    endpoint: "/repos/acme/repo/issues/17/timeline?page=1",
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
                        "timeline:\(pullRequestNodeID.rawValue)", scope.credentialRevision.rawValue,
                        scope.capabilityRevision.rawValue, pageRevision, rawSnapshotID.rawValue,
                        "GET /repos/acme/repo/issues/17/timeline?page=1", milliseconds(now)
                    ]
                )
            }
        }

        func aiCacheKey(
            selectedModelID: String?,
            effectiveModelID: String
        ) throws -> AIAnalysisCacheKey {
            let input = CopilotAnalysisInput(
                candidateID: AIRequestID(rawValue: "derived-\(workItemID.rawValue)")!,
                workItemTitle: "Adapter pull request",
                workItemState: WorkItemState.active.rawValue,
                deterministicReasons: ["derived-input"],
                body: "Current body",
                conversation: [],
                evidenceIDs: []
            )
            return .init(
                workItemID: workItemID,
                fingerprint: try AIFingerprint.make(
                    scope: scope,
                    input: input,
                    sourceRevision: "pull-request-r1",
                    selectedModelID: selectedModelID,
                    effectiveModelID: effectiveModelID,
                    promptVersion: 1,
                    outputSchemaVersion: 1
                ),
                selectedModelID: selectedModelID,
                effectiveModelID: effectiveModelID,
                promptVersion: 1,
                outputSchemaVersion: 1
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
