import Foundation
import GRDB
import XCTest
@testable import Triage

final class OrganizationContextRefreshServiceTests: XCTestCase {
    func testFullReconciliationPolicyWidensButKeepsCandidateSetsBounded() {
        XCTAssertEqual(
            OrganizationContextSelectionPolicy.policy(for: .incremental),
            .init(maximumDiscussionRepositories: 25, maximumProjects: 25)
        )
        XCTAssertEqual(
            OrganizationContextSelectionPolicy.policy(for: .fullReconciliation),
            .init(maximumDiscussionRepositories: 100, maximumProjects: 50)
        )
    }

    func testDiscussionEligibilityPreservesPrivateAndArchivedAndSkipsUnknownAndDisabled() async throws {
        let fixture = try await OrganizationContextFixture()
        defer { fixture.remove() }
        let repositories = try await fixture.persistRepositories([
            fixture.repository(id: 1, nodeID: "R_private", name: "b-private", isPrivate: true),
            fixture.repository(id: 2, nodeID: "R_archived", name: "a-archived", isArchived: true),
            fixture.repository(id: 3, nodeID: "R_disabled", name: "c-disabled", hasDiscussions: false),
            fixture.repository(id: 4, nodeID: "R_unknown", name: "d-unknown", hasDiscussions: nil)
        ])
        let recorder = OrganizationContextRecorder()
        let service = fixture.service(
            recorder: recorder,
            discussion: { scope, _, repository, streamID, _, observedAt in
                await recorder.recordDiscussion(repository.id, streamID: streamID, highWater: nil)
                let record = fixture.coverage(
                    scope: scope,
                    repositoryID: repository.id,
                    feature: .discussions,
                    streamID: streamID,
                    observedAt: observedAt
                )
                try await CoverageRepository(vault: fixture.vault).save(record, attemptedAt: observedAt)
                return record
            }
        )

        let outcome = try await service.refresh(
            scope: fixture.scope,
            organization: fixture.organization,
            repositories: repositories,
            observedAt: fixture.observedAt
        )

        let calls = await recorder.discussions()
        XCTAssertEqual(calls.map(\.repositoryID.rawValue), ["R_archived", "R_private"])
        XCTAssertTrue(calls.allSatisfy { $0.highWater == nil })
        XCTAssertEqual(outcome.discussionCoverage.status, .unknown)
        let records = try await fixture.coverageRepository.records(
            for: fixture.account.id,
            organizationID: fixture.organization.id
        )
        XCTAssertEqual(records.status(feature: .discussions, stream: "discussions-acme-R_disabled"), .unavailable)
        XCTAssertEqual(records.status(feature: .discussions, stream: "discussions-acme-R_unknown"), .unknown)
        XCTAssertEqual(records.status(feature: .discussionComments, stream: "discussion-comments-acme"), .unknown)
        XCTAssertEqual(records.status(feature: .discussionReplies, stream: "discussion-replies-acme"), .unknown)
        XCTAssertEqual(
            records.filter { $0.feature == .discussionComments && $0.repositoryID != nil }.count,
            repositories.count
        )
        XCTAssertEqual(
            records.filter { $0.feature == .discussionReplies && $0.repositoryID != nil }.count,
            repositories.count
        )
    }

    func testDiscussionSelectionIsBoundedDeterministicAndUsesExactLeafHighWater() async throws {
        let fixture = try await OrganizationContextFixture()
        defer { fixture.remove() }
        let repositories = try await fixture.persistRepositories([
            fixture.repository(id: 1, nodeID: "R_a", name: "a"),
            fixture.repository(id: 2, nodeID: "R_b", name: "b"),
            fixture.repository(id: 3, nodeID: "R_c", name: "c")
        ])
        let priorHighWater = fixture.observedAt.addingTimeInterval(-3_600)
        try await fixture.coverageRepository.save(
            fixture.coverage(
                scope: fixture.scope,
                repositoryID: repositories[0].id,
                feature: .discussions,
                streamID: SyncStreamID(rawValue: "discussions-acme-R_a")!,
                observedAt: priorHighWater
            ),
            attemptedAt: priorHighWater
        )
        let recorder = OrganizationContextRecorder()
        let service = fixture.service(
            recorder: recorder,
            policy: .init(maximumDiscussionRepositories: 2, maximumProjects: 1),
            discussion: { scope, _, repository, streamID, highWater, observedAt in
                await recorder.recordDiscussion(repository.id, streamID: streamID, highWater: highWater)
                let record = fixture.coverage(
                    scope: scope,
                    repositoryID: repository.id,
                    feature: .discussions,
                    streamID: streamID,
                    observedAt: observedAt
                )
                try await CoverageRepository(vault: fixture.vault).save(record, attemptedAt: observedAt)
                return record
            }
        )

        let first = try await service.refresh(
            scope: fixture.scope,
            organization: fixture.organization,
            repositories: repositories,
            observedAt: fixture.observedAt
        )

        let firstCalls = await recorder.discussions()
        XCTAssertEqual(firstCalls.map(\.repositoryID.rawValue), ["R_b", "R_c"])
        XCTAssertEqual(first.discussionCoverage.status, .partial)
        XCTAssertNil(first.discussionCoverage.lastSuccessfulAt)

        let secondRecorder = OrganizationContextRecorder()
        let secondService = fixture.service(
            recorder: secondRecorder,
            policy: .init(maximumDiscussionRepositories: 2, maximumProjects: 1),
            discussion: { scope, _, repository, streamID, highWater, observedAt in
                await secondRecorder.recordDiscussion(repository.id, streamID: streamID, highWater: highWater)
                return fixture.coverage(
                    scope: scope,
                    repositoryID: repository.id,
                    feature: .discussions,
                    streamID: streamID,
                    observedAt: observedAt
                )
            }
        )
        _ = try await secondService.refresh(
            scope: fixture.scope,
            organization: fixture.organization,
            repositories: repositories,
            observedAt: fixture.observedAt.addingTimeInterval(60)
        )
        let secondCalls = await secondRecorder.discussions()
        XCTAssertEqual(secondCalls.first?.repositoryID.rawValue, "R_a")
        XCTAssertEqual(secondCalls.first?.highWater, priorHighWater)
        XCTAssertNotEqual(secondCalls.last?.highWater, priorHighWater)
    }

    func testDiscussionCommentLeavesUseIndependentStreamsAndAggregateOnlyAfterAllCandidates() async throws {
        let fixture = try await OrganizationContextFixture()
        defer { fixture.remove() }
        let repository = try await fixture.persistRepositories([
            fixture.repository(id: 1, nodeID: "R_a", name: "a")
        ])[0]
        try await fixture.persistDiscussion(nodeID: "D_a", repositoryID: repository.id)
        try await fixture.persistDiscussion(nodeID: "D_b", repositoryID: repository.id)
        let commentHighWater = fixture.observedAt.addingTimeInterval(-3_600)
        let replyHighWater = fixture.observedAt.addingTimeInterval(-1_800)
        try await fixture.coverageRepository.save(
            fixture.coverage(
                scope: fixture.scope,
                repositoryID: repository.id,
                feature: .discussionComments,
                streamID: SyncStreamID(rawValue: "discussion-comments-acme-R_a-D_a")!,
                observedAt: commentHighWater
            ),
            attemptedAt: commentHighWater
        )
        try await fixture.coverageRepository.save(
            fixture.coverage(
                scope: fixture.scope,
                repositoryID: repository.id,
                feature: .discussionReplies,
                streamID: SyncStreamID(rawValue: "discussion-replies-acme-R_a-D_a")!,
                observedAt: replyHighWater
            ),
            attemptedAt: replyHighWater
        )
        let recorder = OrganizationContextRecorder()
        let service = fixture.service(
            recorder: recorder,
            discussionComments: { scope, _, repository, discussionNodeID, commentStreamID, replyStreamID, previousCommentHighWater, previousReplyHighWater, observedAt in
                await recorder.recordDiscussionComment(
                    discussionNodeID,
                    commentStreamID: commentStreamID,
                    replyStreamID: replyStreamID,
                    commentHighWater: previousCommentHighWater,
                    replyHighWater: previousReplyHighWater
                )
                return .init(
                    comments: [],
                    replies: [],
                    commentCoverage: fixture.coverage(
                        scope: scope,
                        repositoryID: repository.id,
                        feature: .discussionComments,
                        streamID: commentStreamID,
                        observedAt: observedAt
                    ),
                    replyCoverage: fixture.coverage(
                        scope: scope,
                        repositoryID: repository.id,
                        feature: .discussionReplies,
                        streamID: replyStreamID,
                        observedAt: observedAt
                    )
                )
            }
        )

        _ = try await service.refresh(
            scope: fixture.scope,
            organization: fixture.organization,
            repositories: [repository],
            observedAt: fixture.observedAt
        )

        let calls = await recorder.discussionComments()
        XCTAssertEqual(calls.map(\.discussionNodeID.rawValue), ["D_b", "D_a"])
        XCTAssertEqual(calls[0].commentStreamID.rawValue, "discussion-comments-acme-R_a-D_b")
        XCTAssertEqual(calls[0].replyStreamID.rawValue, "discussion-replies-acme-R_a-D_b")
        XCTAssertNil(calls[0].commentHighWater)
        XCTAssertNil(calls[0].replyHighWater)
        XCTAssertEqual(calls[1].commentHighWater, commentHighWater)
        XCTAssertEqual(calls[1].replyHighWater, replyHighWater)
        let records = try await fixture.coverageRepository.records(
            for: fixture.account.id,
            organizationID: fixture.organization.id
        )
        XCTAssertEqual(
            records.status(feature: .discussionComments, stream: "discussion-comments-acme-R_a"),
            .complete
        )
        XCTAssertEqual(
            records.status(feature: .discussionReplies, stream: "discussion-replies-acme-R_a"),
            .complete
        )
    }

    func testDiscussionSourceFailureContinuesSiblingsAndAggregatesRecovery() async throws {
        let fixture = try await OrganizationContextFixture()
        defer { fixture.remove() }
        let repositories = try await fixture.persistRepositories([
            fixture.repository(id: 1, nodeID: "R_a", name: "a"),
            fixture.repository(id: 2, nodeID: "R_b", name: "b")
        ])
        let recorder = OrganizationContextRecorder()
        let ssoHeader = GitHubSSOHeader.authorizationRequired(
            URL(string: "https://github.com/orgs/acme/sso")!
        )
        let service = fixture.service(
            recorder: recorder,
            discussion: { scope, _, repository, streamID, highWater, observedAt in
                await recorder.recordDiscussion(repository.id, streamID: streamID, highWater: highWater)
                if repository.id.rawValue == "R_a" {
                    throw DiscussionProjectV2SynchronizationError.requiresSSO(ssoHeader)
                }
                return fixture.coverage(
                    scope: scope,
                    repositoryID: repository.id,
                    feature: .discussions,
                    streamID: streamID,
                    observedAt: observedAt
                )
            },
            projectInventory: { scope, _, streamID, _, _, observedAt in
                await recorder.recordEvent("project-inventory")
                throw GitHubGraphQLError.requestFailed(
                    GitHubFailure(kind: .rateLimited, statusCode: 429, retryAfter: 120)
                )
            }
        )

        let outcome = try await service.refresh(
            scope: fixture.scope,
            organization: fixture.organization,
            repositories: repositories,
            observedAt: fixture.observedAt
        )

        let discussionCalls = await recorder.discussions()
        let projectCalls = await recorder.projectItems()
        XCTAssertEqual(discussionCalls.map(\.repositoryID.rawValue), ["R_a", "R_b"])
        XCTAssertEqual(outcome.discussionCoverage.status, .requiresSSO)
        XCTAssertEqual(outcome.projectItemCoverage.status, .partial)
        XCTAssertEqual(outcome.recovery.ssoRequirement, ssoHeader)
        XCTAssertTrue(outcome.recovery.rateLimited)
        XCTAssertEqual(outcome.recovery.rateLimitRetryAt, fixture.observedAt.addingTimeInterval(120))
        XCTAssertTrue(projectCalls.isEmpty)
    }

    func testScopedPartialResultsStayPartialWithoutCreatingTerminalSSORecovery() async throws {
        let fixture = try await OrganizationContextFixture()
        defer { fixture.remove() }
        let repositories = try await fixture.persistRepositories([
            fixture.repository(id: 1, nodeID: "R_a", name: "a")
        ])
        let recorder = OrganizationContextRecorder()
        let partialHeader = GitHubSSOHeader.partialResults([fixture.organization.githubOrganizationID])
        let service = fixture.service(
            recorder: recorder,
            discussion: { _, _, _, _, _, _ in
                throw DiscussionProjectV2SynchronizationError.requiresSSO(partialHeader)
            }
        )

        let outcome = try await service.refresh(
            scope: fixture.scope,
            organization: fixture.organization,
            repositories: repositories,
            observedAt: fixture.observedAt
        )

        XCTAssertEqual(outcome.discussionCoverage.status, .partial)
        XCTAssertNil(outcome.recovery.ssoRequirement)
        XCTAssertTrue(outcome.recovery.isEmpty)
    }

    func testProjectInventoryPrecedesBoundedItemsAndItemFailureDoesNotStopSibling() async throws {
        let fixture = try await OrganizationContextFixture()
        defer { fixture.remove() }
        let recorder = OrganizationContextRecorder()
        let projects = [fixture.project("P_b", number: 2), fixture.project("P_a", number: 1), fixture.project("P_c", number: 3)]
        let service = fixture.service(
            recorder: recorder,
            policy: .init(maximumDiscussionRepositories: 1, maximumProjects: 2),
            projectInventory: { scope, _, streamID, _, _, observedAt in
                await recorder.recordEvent("project-inventory")
                return ProjectV2SynchronizationResult(
                    projects: projects,
                    projectCoverage: fixture.coverage(
                        scope: scope,
                        repositoryID: nil,
                        feature: .projects,
                        streamID: streamID,
                        observedAt: observedAt
                    ),
                    itemCoverages: [:]
                )
            },
            projectItems: { project, scope, _, streamID, highWater, _, observedAt in
                await recorder.recordProject(project.nodeID, streamID: streamID, highWater: highWater)
                await recorder.recordEvent("project-item-\(project.nodeID.rawValue)")
                if project.nodeID.rawValue == "P_a" {
                    throw GitHubProjectV2ClientError.missingData([])
                }
                return fixture.coverage(
                    scope: scope,
                    repositoryID: nil,
                    feature: .projectItems,
                    streamID: streamID,
                    observedAt: observedAt
                )
            }
        )

        let outcome = try await service.refresh(
            scope: fixture.scope,
            organization: fixture.organization,
            repositories: [],
            observedAt: fixture.observedAt
        )

        let events = await recorder.events()
        let projectCalls = await recorder.projectItems()
        XCTAssertEqual(events, ["project-inventory", "project-item-P_a", "project-item-P_b"])
        XCTAssertEqual(projectCalls.map(\.projectID.rawValue), ["P_a", "P_b"])
        XCTAssertEqual(outcome.projectItemCoverage.status, .partial)
        XCTAssertNil(outcome.projectItemCoverage.lastSuccessfulAt)
        XCTAssertTrue(outcome.recovery.isEmpty)
    }

    func testProjectInventoryAndItemReuseTheirOwnExactHighWaters() async throws {
        let fixture = try await OrganizationContextFixture()
        defer { fixture.remove() }
        let inventoryHighWater = fixture.observedAt.addingTimeInterval(-7_200)
        let itemHighWater = fixture.observedAt.addingTimeInterval(-3_600)
        try await fixture.coverageRepository.save(
            fixture.coverage(
                scope: fixture.scope,
                repositoryID: nil,
                feature: .projects,
                streamID: SyncStreamID(rawValue: "projects-v2-inventory-acme")!,
                observedAt: inventoryHighWater
            ),
            attemptedAt: inventoryHighWater
        )
        try await fixture.coverageRepository.save(
            fixture.coverage(
                scope: fixture.scope,
                repositoryID: nil,
                feature: .projectItems,
                streamID: SyncStreamID(rawValue: "projects-v2-items-acme-P_a")!,
                observedAt: itemHighWater
            ),
            attemptedAt: itemHighWater
        )
        let recorder = OrganizationContextRecorder()
        let project = fixture.project("P_a", number: 1)
        let service = fixture.service(
            recorder: recorder,
            projectInventory: { scope, _, streamID, highWater, _, observedAt in
                await recorder.recordInventory(highWater: highWater)
                return ProjectV2SynchronizationResult(
                    projects: [project],
                    projectCoverage: fixture.coverage(
                        scope: scope,
                        repositoryID: nil,
                        feature: .projects,
                        streamID: streamID,
                        observedAt: observedAt
                    ),
                    itemCoverages: [:]
                )
            }
        )

        _ = try await service.refresh(
            scope: fixture.scope,
            organization: fixture.organization,
            repositories: [],
            observedAt: fixture.observedAt
        )

        let inventoryCalls = await recorder.inventories()
        let projectCalls = await recorder.projectItems()
        XCTAssertEqual(inventoryCalls, [inventoryHighWater])
        XCTAssertEqual(projectCalls.map(\.projectID.rawValue), ["P_a"])
        XCTAssertEqual(projectCalls.map(\.highWater), [itemHighWater])
    }

    func testProjectCallbacksReceiveFullAndIncrementalReconciliationIntent() async throws {
        let fixture = try await OrganizationContextFixture()
        defer { fixture.remove() }
        let recorder = OrganizationContextRecorder()
        let project = fixture.project("P_intent", number: 1)
        let service = fixture.service(
            recorder: recorder,
            projectInventory: { scope, _, streamID, highWater, reconciliationIntent, observedAt in
                await recorder.recordInventory(
                    highWater: highWater,
                    reconciliationIntent: reconciliationIntent
                )
                return ProjectV2SynchronizationResult(
                    projects: [project],
                    projectCoverage: fixture.coverage(
                        scope: scope,
                        repositoryID: nil,
                        feature: .projects,
                        streamID: streamID,
                        observedAt: observedAt
                    ),
                    itemCoverages: [:]
                )
            },
            projectItems: { project, scope, _, streamID, highWater, reconciliationIntent, observedAt in
                await recorder.recordProject(
                    project.nodeID,
                    streamID: streamID,
                    highWater: highWater,
                    reconciliationIntent: reconciliationIntent
                )
                return fixture.coverage(
                    scope: scope,
                    repositoryID: nil,
                    feature: .projectItems,
                    streamID: streamID,
                    observedAt: observedAt
                )
            }
        )

        _ = try await service.refresh(
            scope: fixture.scope,
            organization: fixture.organization,
            repositories: [],
            reconciliationIntent: .fullReconciliation,
            observedAt: fixture.observedAt
        )
        _ = try await service.refresh(
            scope: fixture.scope,
            organization: fixture.organization,
            repositories: [],
            reconciliationIntent: .incremental,
            observedAt: fixture.observedAt.addingTimeInterval(60)
        )

        let inventoryIntents = await recorder.inventoryIntents()
        let projectIntents = await recorder.projectIntents()
        XCTAssertEqual(inventoryIntents, [.fullReconciliation, .incremental])
        XCTAssertEqual(projectIntents, [.fullReconciliation, .incremental])
    }

    func testProjectInventoryFailureCreatesExplicitItemCoverageAndStartsNoItems() async throws {
        let fixture = try await OrganizationContextFixture()
        defer { fixture.remove() }
        let recorder = OrganizationContextRecorder()
        let service = fixture.service(
            recorder: recorder,
            projectInventory: { _, _, _, _, _, _ in
                await recorder.recordEvent("project-inventory")
                throw GitHubGraphQLError.requestFailed(GitHubFailure(kind: .unauthorized, statusCode: 401))
            }
        )

        let outcome = try await service.refresh(
            scope: fixture.scope,
            organization: fixture.organization,
            repositories: [],
            observedAt: fixture.observedAt
        )

        XCTAssertNil(outcome.projectCoverage)
        XCTAssertEqual(outcome.projectItemCoverage.status, .failed)
        XCTAssertTrue(outcome.recovery.authenticationRequired)
        let projectCalls = await recorder.projectItems()
        XCTAssertTrue(projectCalls.isEmpty)
        let records = try await fixture.coverageRepository.records(
            for: fixture.account.id,
            organizationID: fixture.organization.id
        )
        XCTAssertEqual(records.status(feature: .projectItems, stream: "projects-v2-items-acme"), .failed)
    }

    func testTransportCancellationStopsAllLaterSourcesWithoutFailureCoverage() async throws {
        let fixture = try await OrganizationContextFixture()
        defer { fixture.remove() }
        let repositories = try await fixture.persistRepositories([
            fixture.repository(id: 1, nodeID: "R_a", name: "a"),
            fixture.repository(id: 2, nodeID: "R_b", name: "b")
        ])
        let recorder = OrganizationContextRecorder()
        let service = fixture.service(
            recorder: recorder,
            discussion: { _, _, repository, streamID, highWater, _ in
                await recorder.recordDiscussion(repository.id, streamID: streamID, highWater: highWater)
                throw URLError(.cancelled)
            }
        )

        do {
            _ = try await service.refresh(
                scope: fixture.scope,
                organization: fixture.organization,
                repositories: repositories,
                observedAt: fixture.observedAt
            )
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        }

        let discussionCalls = await recorder.discussions()
        let events = await recorder.events()
        XCTAssertEqual(discussionCalls.map(\.repositoryID.rawValue), ["R_a"])
        XCTAssertFalse(events.contains("project-inventory"))
        let records = try await fixture.coverageRepository.records(
            for: fixture.account.id,
            organizationID: fixture.organization.id
        )
        XCTAssertNil(records.first { $0.streamID.rawValue == "discussions-acme-R_a" })
        XCTAssertNil(records.first { $0.streamID.rawValue == "discussions-acme" })
    }

    func testCredentialRotationDuringProjectInventoryCancelsWithoutPostGateWrites() async throws {
        try await assertScopeRotationDuringProjectInventory(.credential)
    }

    func testCapabilityRotationDuringProjectInventoryCancelsWithoutPostGateWrites() async throws {
        try await assertScopeRotationDuringProjectInventory(.capability)
    }

    private func assertScopeRotationDuringProjectInventory(
        _ rotation: OrganizationContextScopeRotation
    ) async throws {
        let fixture = try await OrganizationContextFixture()
        defer { fixture.remove() }
        let recorder = OrganizationContextRecorder()
        let gate = OrganizationContextResponseGate()
        let service = fixture.service(
            recorder: recorder,
            projectInventory: { scope, _, streamID, _, _, observedAt in
                await gate.enterAndWait()
                return ProjectV2SynchronizationResult(
                    projects: [],
                    projectCoverage: fixture.coverage(
                        scope: scope,
                        repositoryID: nil,
                        feature: .projects,
                        streamID: streamID,
                        observedAt: observedAt
                    ),
                    itemCoverages: [:]
                )
            }
        )
        let task = Task {
            try await service.refresh(
                scope: fixture.scope,
                organization: fixture.organization,
                repositories: [],
                observedAt: fixture.observedAt
            )
        }

        await gate.waitUntilEntered()
        let before = try await organizationContextDurableState(in: fixture.vault)
        try await fixture.vault.write { database in
            switch rotation {
            case .credential:
                try database.execute(
                    sql: "UPDATE accounts SET credential_revision = 'credential-2' WHERE id = ?",
                    arguments: [fixture.account.id.rawValue]
                )
            case .capability:
                try database.execute(
                    sql: """
                        UPDATE account_organizations
                        SET capability_revision = 'capability-2'
                        WHERE account_id = ? AND organization_id = ?
                    """,
                    arguments: [fixture.account.id.rawValue, fixture.organization.id.rawValue]
                )
            }
        }
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("Expected scope rotation to cancel context refresh.")
        } catch is CancellationError {
            // Expected supersession.
        }
        let after = try await organizationContextDurableState(in: fixture.vault)
        XCTAssertEqual(after, before)
        let events = await recorder.events()
        XCTAssertFalse(events.contains("project-item"))
    }

    func testLeafSynchronizersTranslateTransportCancellationWithoutPersistingFailureCoverage() async throws {
        let fixture = try await OrganizationContextFixture()
        defer { fixture.remove() }
        let repositories = try await fixture.persistRepositories([
            fixture.repository(id: 1, nodeID: "R_a", name: "a")
        ])
        let graphQL = GitHubGraphQLClient(
            session: CancelledOrganizationContextSession(),
            credential: SecretValue("token")
        )
        let discussion = DiscussionSynchronizationService(
            client: GitHubDiscussionClient(client: graphQL),
            repository: DiscussionRepository(vault: fixture.vault),
            coverage: fixture.coverageRepository
        )
        let projects = ProjectV2SynchronizationService(
            client: GitHubProjectV2Client(client: graphQL),
            repository: ProjectV2Repository(vault: fixture.vault),
            coverage: fixture.coverageRepository
        )

        await assertCancellation {
            _ = try await discussion.refresh(
                scope: fixture.scope,
                organization: fixture.organization,
                repositoryID: repositories[0].id,
                repositoryNodeID: repositories[0].nodeID,
                streamID: SyncStreamID(rawValue: "discussions-acme-R_a")!,
                previousHighWater: nil,
                observedAt: fixture.observedAt
            )
        }
        await assertCancellation {
            _ = try await projects.refreshProjects(
                scope: fixture.scope,
                organization: fixture.organization,
                streamID: SyncStreamID(rawValue: "projects-v2-inventory-acme")!,
                previousHighWater: nil,
                observedAt: fixture.observedAt
            )
        }
        await assertCancellation {
            _ = try await projects.refreshItems(
                project: fixture.project("P_a", number: 1),
                scope: fixture.scope,
                organization: fixture.organization,
                streamID: SyncStreamID(rawValue: "projects-v2-items-acme-P_a")!,
                previousHighWater: nil,
                observedAt: fixture.observedAt
            )
        }

        let records = try await fixture.coverageRepository.records(
            for: fixture.account.id,
            organizationID: fixture.organization.id
        )
        XCTAssertTrue(records.isEmpty)
    }

    func testScopeMismatchStartsNoSourceWork() async throws {
        let fixture = try await OrganizationContextFixture()
        defer { fixture.remove() }
        let recorder = OrganizationContextRecorder()
        let service = fixture.service(recorder: recorder)
        let otherScope = SynchronizationScope(
            accountID: AccountID.make(),
            organizationID: fixture.organization.id,
            credentialRevision: fixture.scope.credentialRevision,
            capabilityRevision: fixture.scope.capabilityRevision
        )

        do {
            _ = try await service.refresh(
                scope: otherScope,
                organization: fixture.organization,
                repositories: [],
                observedAt: fixture.observedAt
            )
            XCTFail("Expected account-scope rejection.")
        } catch let error as OrganizationContextRefreshServiceError {
            XCTAssertEqual(error, .accountScopeMismatch)
        }

        let discussionCalls = await recorder.discussions()
        let events = await recorder.events()
        let projectCalls = await recorder.projectItems()
        XCTAssertTrue(discussionCalls.isEmpty)
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(projectCalls.isEmpty)
    }

    func testAggregateCoverageAndHighWatersSurviveEncryptedVaultReopen() async throws {
        let fixture = try await OrganizationContextFixture()
        defer { fixture.remove() }
        let recorder = OrganizationContextRecorder()
        let service = fixture.service(recorder: recorder)
        _ = try await service.refresh(
            scope: fixture.scope,
            organization: fixture.organization,
            repositories: [],
            observedAt: fixture.observedAt
        )

        let reopened = try await VaultRegistry(rootDirectory: fixture.root).open(
            accountID: fixture.account.id,
            vaultKey: fixture.vaultKey
        )
        let streams = try await SyncStreamRepository(vault: reopened).streams(
            for: fixture.account.id,
            organizationID: fixture.organization.id
        )

        XCTAssertEqual(
            streams.first { $0.id.rawValue == "discussions-acme" }?.highWater,
            fixture.observedAt
        )
        XCTAssertEqual(
            streams.first { $0.id.rawValue == "projects-v2-items-acme" }?.highWater,
            fixture.observedAt
        )
    }
}

private actor OrganizationContextRecorder {
    struct DiscussionCall: Sendable {
        let repositoryID: RepositoryID
        let streamID: SyncStreamID
        let highWater: Date?
    }

    struct ProjectCall: Sendable {
        let projectID: GitHubNodeID
        let streamID: SyncStreamID
        let highWater: Date?
    }

    struct DiscussionCommentCall: Sendable {
        let discussionNodeID: GitHubNodeID
        let commentStreamID: SyncStreamID
        let replyStreamID: SyncStreamID
        let commentHighWater: Date?
        let replyHighWater: Date?
    }

    private var discussionCalls = [DiscussionCall]()
    private var projectCalls = [ProjectCall]()
    private var inventoryCalls = [Date?]()
    private var inventoryIntentValues = [SynchronizationReconciliationIntent]()
    private var projectIntentValues = [SynchronizationReconciliationIntent]()
    private var discussionCommentCalls = [DiscussionCommentCall]()
    private var eventValues = [String]()

    func recordDiscussion(_ repositoryID: RepositoryID, streamID: SyncStreamID, highWater: Date?) {
        discussionCalls.append(.init(repositoryID: repositoryID, streamID: streamID, highWater: highWater))
    }

    func recordProject(_ projectID: GitHubNodeID, streamID: SyncStreamID, highWater: Date?) {
        projectCalls.append(.init(projectID: projectID, streamID: streamID, highWater: highWater))
    }

    func recordDiscussionComment(
        _ discussionNodeID: GitHubNodeID,
        commentStreamID: SyncStreamID,
        replyStreamID: SyncStreamID,
        commentHighWater: Date?,
        replyHighWater: Date?
    ) {
        discussionCommentCalls.append(.init(
            discussionNodeID: discussionNodeID,
            commentStreamID: commentStreamID,
            replyStreamID: replyStreamID,
            commentHighWater: commentHighWater,
            replyHighWater: replyHighWater
        ))
    }

    func recordProject(
        _ projectID: GitHubNodeID,
        streamID: SyncStreamID,
        highWater: Date?,
        reconciliationIntent: SynchronizationReconciliationIntent
    ) {
        recordProject(projectID, streamID: streamID, highWater: highWater)
        projectIntentValues.append(reconciliationIntent)
    }

    func recordInventory(highWater: Date?) {
        inventoryCalls.append(highWater)
    }

    func recordInventory(
        highWater: Date?,
        reconciliationIntent: SynchronizationReconciliationIntent
    ) {
        recordInventory(highWater: highWater)
        inventoryIntentValues.append(reconciliationIntent)
    }

    func recordEvent(_ event: String) {
        eventValues.append(event)
    }

    func discussions() -> [DiscussionCall] { discussionCalls }
    func projectItems() -> [ProjectCall] { projectCalls }
    func inventories() -> [Date?] { inventoryCalls }
    func inventoryIntents() -> [SynchronizationReconciliationIntent] { inventoryIntentValues }
    func projectIntents() -> [SynchronizationReconciliationIntent] { projectIntentValues }
    func discussionComments() -> [DiscussionCommentCall] { discussionCommentCalls }
    func events() -> [String] { eventValues }
}

private actor CancelledOrganizationContextSession: HTTPSession {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.cancelled)
    }
}

private enum OrganizationContextScopeRotation {
    case credential
    case capability
}

private struct OrganizationContextDurableState: Equatable {
    let coverageRecords: Int
    let syncStreams: Int
    let rawSnapshots: Int
    let normalizationFailures: Int
}

private func organizationContextDurableState(
    in vault: AccountVault
) async throws -> OrganizationContextDurableState {
    try await vault.read { database in
        OrganizationContextDurableState(
            coverageRecords: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM coverage_records")!,
            syncStreams: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sync_streams")!,
            rawSnapshots: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")!,
            normalizationFailures: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM normalization_failures")!
        )
    }
}

private actor OrganizationContextResponseGate {
    private var entered = false
    private var released = false
    private var enteredWaiters = [CheckedContinuation<Void, Never>]()
    private var releaseWaiters = [CheckedContinuation<Void, Never>]()

    func enterAndWait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private func assertCancellation(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected cancellation.", file: file, line: line)
    } catch is CancellationError {
        // Expected.
    } catch {
        XCTFail("Expected CancellationError, received \(error).", file: file, line: line)
    }
}

private final class OrganizationContextFixture: @unchecked Sendable {
    let root: URL
    let vault: AccountVault
    let vaultKey: VaultKey
    let account: GitHubAccount
    let organization: GitHubOrganization
    let scope: SynchronizationScope
    let observedAt = Date(timeIntervalSinceReferenceDate: 50_000)

    var coverageRepository: CoverageRepository { CoverageRepository(vault: vault) }

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".triage-context-test-\(UUID().uuidString)", isDirectory: true)
        let accountID = AccountID.make()
        let credentialRevision = CredentialRevision(rawValue: "credential-1")!
        let capabilityRevision = CapabilityRevision(rawValue: "capability-1")!
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
        scope = SynchronizationScope(
            accountID: accountID,
            organizationID: organization.id,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision
        )
        vaultKey = try VaultKey.generate()
        vault = try await VaultRegistry(rootDirectory: root).open(
            accountID: accountID,
            vaultKey: vaultKey
        )
        let accounts = AccountRepository(vault: vault)
        try await accounts.save(account, credentialRevision: credentialRevision)
        try await accounts.save(
            organization,
            access: OrganizationAccess(
                accountID: accountID,
                organizationID: organization.id,
                state: .available,
                capabilityRevision: capabilityRevision,
                capabilities: [],
                checkedAt: observedAt
            )
        )
    }

    func service(
        recorder: OrganizationContextRecorder,
        policy: OrganizationContextSelectionPolicy = .init(
            maximumDiscussionRepositories: 25,
            maximumProjects: 25
        ),
        discussion: OrganizationContextRefreshService.DiscussionRefresh? = nil,
        projectInventory: OrganizationContextRefreshService.ProjectInventoryRefresh? = nil,
        projectItems: OrganizationContextRefreshService.ProjectItemsRefresh? = nil,
        discussionComments: OrganizationContextRefreshService.DiscussionCommentsRefresh? = nil
    ) -> OrganizationContextRefreshService {
        OrganizationContextRefreshService(
            vault: vault,
            selectionPolicy: policy,
            refreshDiscussion: discussion ?? { scope, _, repository, streamID, highWater, observedAt in
                await recorder.recordDiscussion(repository.id, streamID: streamID, highWater: highWater)
                return self.coverage(
                    scope: scope,
                    repositoryID: repository.id,
                    feature: .discussions,
                    streamID: streamID,
                    observedAt: observedAt
                )
            },
            refreshProjectInventory: projectInventory ?? { scope, _, streamID, _, _, observedAt in
                await recorder.recordEvent("project-inventory")
                return ProjectV2SynchronizationResult(
                    projects: [],
                    projectCoverage: self.coverage(
                        scope: scope,
                        repositoryID: nil,
                        feature: .projects,
                        streamID: streamID,
                        observedAt: observedAt
                    ),
                    itemCoverages: [:]
                )
            },
            refreshProjectItems: projectItems ?? { project, scope, _, streamID, highWater, _, observedAt in
                await recorder.recordProject(project.nodeID, streamID: streamID, highWater: highWater)
                return self.coverage(
                    scope: scope,
                    repositoryID: nil,
                    feature: .projectItems,
                    streamID: streamID,
                    observedAt: observedAt
                )
            },
            refreshDiscussionComments: discussionComments ?? { scope, _, repository, discussionNodeID, commentStreamID, replyStreamID, _, _, observedAt in
                await recorder.recordDiscussionComment(
                    discussionNodeID,
                    commentStreamID: commentStreamID,
                    replyStreamID: replyStreamID,
                    commentHighWater: nil,
                    replyHighWater: nil
                )
                return .init(
                    comments: [],
                    replies: [],
                    commentCoverage: self.coverage(
                        scope: scope,
                        repositoryID: repository.id,
                        feature: .discussionComments,
                        streamID: commentStreamID,
                        observedAt: observedAt
                    ),
                    replyCoverage: self.coverage(
                        scope: scope,
                        repositoryID: repository.id,
                        feature: .discussionReplies,
                        streamID: replyStreamID,
                        observedAt: observedAt
                    )
                )
            }
        )
    }

    func persistRepositories(_ values: [GitHubRepositoryDTO]) async throws -> [RepositorySummary] {
        try await RepositoryInventoryRepository(vault: vault).replace(
            values,
            accountID: account.id,
            organization: organization,
            observedAt: observedAt
        )
    }

    func repository(
        id: UInt64,
        nodeID: String,
        name: String,
        isPrivate: Bool = false,
        isArchived: Bool = false,
        hasDiscussions: Bool? = true
    ) -> GitHubRepositoryDTO {
        GitHubRepositoryDTO(
            id: id,
            nodeID: nodeID,
            name: name,
            isPrivate: isPrivate,
            isArchived: isArchived,
            hasDiscussions: hasDiscussions,
            htmlURL: URL(string: "https://github.com/acme/\(name)")!,
            updatedAt: observedAt,
            owner: .init(login: "acme")
        )
    }

    func project(_ nodeID: String, number: Int) -> GitHubProjectV2Record {
        GitHubProjectV2Record(
            nodeID: GitHubNodeID(rawValue: nodeID)!,
            number: number,
            title: nodeID,
            description: nil,
            url: URL(string: "https://github.com/orgs/acme/projects/\(number)")!,
            updatedAt: observedAt,
            state: .active
        )
    }

    func persistDiscussion(nodeID: String, repositoryID: RepositoryID) async throws {
        let discussionNodeID = GitHubNodeID(rawValue: nodeID)!
        try await vault.write { database in
            try GitHubNodeRepository.save(
                .init(
                    nodeID: discussionNodeID,
                    accountID: account.id,
                    organizationID: organization.id,
                    repositoryID: repositoryID,
                    kind: .discussion,
                    numericID: nil,
                    number: 1,
                    title: "Discussion \(nodeID)",
                    state: .open,
                    url: URL(string: "https://github.com/acme/a/discussions/1")!,
                    bodyMarkdown: nil,
                    authorID: nil,
                    createdAt: observedAt,
                    updatedAt: observedAt,
                    closedAt: nil,
                    mergedAt: nil,
                    sourceRevision: observedAt.ISO8601Format(),
                    observedAt: observedAt,
                    accessibility: .accessible
                ),
                in: database
            )
            try database.execute(
                sql: """
                    INSERT INTO discussions (
                        github_node_id, category_name, answer_comment_node_id,
                        comments_count, updated_at_ms
                    ) VALUES (?, NULL, NULL, 0, ?)
                    """,
                arguments: [discussionNodeID.rawValue, Int64((observedAt.timeIntervalSince1970 * 1_000).rounded())]
            )
        }
    }

    func coverage(
        scope: SynchronizationScope,
        repositoryID: RepositoryID?,
        feature: CoverageFeature,
        streamID: SyncStreamID,
        observedAt: Date,
        status: CoverageStatus = .complete
    ) -> CoverageRecord {
        CoverageRecord(
            accountID: scope.accountID,
            organizationID: scope.organizationID,
            repositoryID: repositoryID,
            feature: feature,
            streamID: streamID,
            intervalStart: Date(timeIntervalSince1970: 0),
            intervalEnd: observedAt,
            credentialRevision: scope.credentialRevision,
            capabilityRevision: scope.capabilityRevision,
            status: status,
            lastSuccessfulAt: status == .complete ? observedAt : nil,
            failureDetail: nil
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private extension Array where Element == CoverageRecord {
    func status(feature: CoverageFeature, stream: String) -> CoverageStatus? {
        first { $0.feature == feature && $0.streamID.rawValue == stream }?.status
    }
}
