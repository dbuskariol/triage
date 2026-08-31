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

    private final class Fixture: @unchecked Sendable {
        let directory: URL
        let accountID = AccountID(rawValue: "derived-adapter-account")!
        let organizationID = OrganizationID(rawValue: "derived-adapter-org")!
        let userNodeID = GitHubNodeID(rawValue: "derived-adapter-user")!
        let userActorID = ActorID(rawValue: "derived-adapter-user-actor")!
        let pullRequestNodeID = GitHubNodeID(rawValue: "derived-adapter-pr")!
        let reviewNodeID = GitHubNodeID(rawValue: "derived-adapter-review")!
        let now = Date(timeIntervalSinceReferenceDate: 100_000)
        let vault: AccountVault
        let workItemID: WorkItemID

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
            let pullRequest = NormalizedGitHubNode(
                nodeID: pullRequestNodeID,
                accountID: accountID,
                organizationID: organizationID,
                repositoryID: nil,
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

        func saveTimelineCandidateCoverage(status: CoverageStatus) async throws {
            try await CoverageRepository(vault: vault).save(
                CoverageRecord(
                    accountID: accountID,
                    organizationID: organizationID,
                    repositoryID: nil,
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

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }

        private func milliseconds(_ date: Date) -> Int64 {
            Int64((date.timeIntervalSince1970 * 1_000).rounded())
        }
    }
}
