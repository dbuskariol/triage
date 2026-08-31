import GRDB
import XCTest
@testable import Triage

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {}
}

final class WorkItemGroupingDecisionRepositoryTests: XCTestCase {
    func testRoleMentionQualifiersRequireExactLoginAndSelectedOrganizationOwner() {
        XCTAssertEqual(
            OrganizationWorkItemGraphProjectionService.roleQueryQualifier(
                named: "mentions",
                in: "org:github is:open mentions:octocat"
            ),
            "octocat"
        )
        XCTAssertNotEqual(
            OrganizationWorkItemGraphProjectionService.roleQueryQualifier(
                named: "mentions",
                in: "org:github is:open mentions:octocat-maintainer"
            ),
            "octocat"
        )
        XCTAssertNil(
            OrganizationWorkItemGraphProjectionService.roleTeamMentionQualifier(
                in: "org:github is:open team:github/triage/extra"
            )
        )
        XCTAssertEqual(
            OrganizationWorkItemGraphProjectionService.roleTeamMentionSlug(
                in: "org:github is:open team:github/triage",
                organizationLogin: "github"
            ),
            "triage"
        )
        XCTAssertNil(
            OrganizationWorkItemGraphProjectionService.roleTeamMentionSlug(
                in: "org:github is:open team:other-org/triage",
                organizationLogin: "github"
            )
        )
        XCTAssertNil(
            OrganizationWorkItemGraphProjectionService.roleTeamMentionSlug(
                in: "org:github is:open mentions:github/triage",
                organizationLogin: "github"
            )
        )
    }

    func testReplacingDecisionsRestoresEvidenceAndRemovesStaleRows() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let repository = WorkItemGroupingDecisionRepository(vault: fixture.vault)
        let decision = fixture.decision
        try await repository.replace([decision], accountID: fixture.accountID)
        let restoredDecisions = try await repository.decisions(for: fixture.accountID)
        XCTAssertEqual(restoredDecisions, [decision])

        try await repository.replace([], accountID: fixture.accountID)
        let remainingDecisions = try await repository.decisions(for: fixture.accountID)
        XCTAssertTrue(remainingDecisions.isEmpty)
    }

    func testRejectsDecisionReferencingNodeOutsideVaultAccount() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let foreignNode = fixture.node(
            id: GitHubNodeID(rawValue: "foreign-node")!,
            accountID: AccountID.make()
        )
        let decision = WorkItemGroupingDecision(
            sourceNodeID: fixture.firstNode.nodeID,
            destinationNodeID: foreignNode.nodeID,
            relation: .closes,
            strength: .strong,
            evidence: [],
            decidedAt: fixture.date
        )

        do {
            try await WorkItemGroupingDecisionRepository(vault: fixture.vault).replace(
                [decision],
                accountID: fixture.accountID
            )
            XCTFail("Expected a node scope mismatch.")
        } catch {
            XCTAssertEqual(
                error as? WorkItemGroupingDecisionRepositoryError,
                .nodeScopeMismatch
            )
        }
    }

    func testProjectionMergesDecisionJoinedItemsAndFailsClosedForUnprovenWeakRelation() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        try await WorkItemGroupingDecisionRepository(vault: fixture.vault).replace(
            [fixture.decision],
            accountID: fixture.accountID
        )

        try await OrganizationWorkItemGraphProjectionService(vault: fixture.vault)
            .projectAfterNormalizedCommit(for: fixture.scope, at: fixture.date)

        let items = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(items.count, 2)

        let merged = try XCTUnwrap(items.first { $0.primaryNodeID == fixture.firstNode.nodeID })
        XCTAssertEqual(
            Set(merged.members.map(\.id)),
            Set([fixture.firstNode.nodeID, fixture.secondNode.nodeID])
        )
        // The directly seeded cross-reference deliberately has no current
        // raw receipt. It may not affect either grouping or contextual UI.
        XCTAssertFalse(merged.contextLinks.contains {
            $0.id == fixture.thirdNode.nodeID && $0.relation == .crossReferences
        })
        XCTAssertNotNil(items.first { $0.primaryNodeID == fixture.thirdNode.nodeID })

        let recordedRevisions: (credential: String, capability: String, source: String)? = try await fixture.vault.read { database in
            try Row.fetchOne(
                database,
                sql: """
                    SELECT credential_revision, capability_revision, source_revision
                    FROM work_item_graph_runs
                    WHERE account_id = ? AND organization_id = ?
                    """,
                arguments: [fixture.accountID.rawValue, fixture.organizationID.rawValue]
            ).map { row in
                guard let credential: String = row["credential_revision"],
                      let capability: String = row["capability_revision"],
                      let source: String = row["source_revision"]
                else {
                    throw WorkItemGraphRepositoryError.workItemScopeMismatch
                }
                return (credential, capability, source)
            }
        }
        XCTAssertEqual(recordedRevisions?.credential, fixture.scope.credentialRevision.rawValue)
        XCTAssertEqual(recordedRevisions?.capability, fixture.scope.capabilityRevision.rawValue)
        XCTAssertEqual(recordedRevisions?.source.count, 64)
    }

    func testRemovingConfirmedDecisionRestoresConstituentVisibleItemsAndActionOwnership() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        try await WorkItemGroupingDecisionRepository(vault: fixture.vault).replace(
            [fixture.decision], accountID: fixture.accountID
        )
        let beforeMerge = try await fixture.workItemID(for: fixture.secondNode.nodeID)
        try await fixture.insertAction(workItemID: beforeMerge)

        let projector = OrganizationWorkItemGraphProjectionService(vault: fixture.vault)
        let mergedResult = try await projector.projectAfterNormalizedCommit(for: fixture.scope, at: fixture.date)
        let merged = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID, organizationID: fixture.organizationID
        )
        XCTAssertEqual(merged.count, 2)
        let canonical = try XCTUnwrap(merged.first { $0.primaryNodeID == fixture.firstNode.nodeID })
        XCTAssertEqual(canonical.actionItems.map(\.workItemID), [beforeMerge])
        XCTAssertEqual(mergedResult.notificationCleanupConstituentWorkItemIDs, [beforeMerge])

        try await WorkItemGroupingDecisionRepository(vault: fixture.vault).replace(
            [], accountID: fixture.accountID
        )
        let splitResult = try await projector.projectAfterNormalizedCommit(
            for: fixture.scope, at: fixture.date.addingTimeInterval(1)
        )
        let split = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID, organizationID: fixture.organizationID
        )
        XCTAssertEqual(Set(split.map(\.primaryNodeID)), Set([
            fixture.firstNode.nodeID, fixture.secondNode.nodeID, fixture.thirdNode.nodeID
        ]))
        XCTAssertTrue(splitResult.notificationCleanupConstituentWorkItemIDs.isEmpty)
        let restored = try XCTUnwrap(split.first { $0.primaryNodeID == fixture.secondNode.nodeID })
        XCTAssertEqual(restored.actionItems.map(\.workItemID), [beforeMerge])
        let first = try XCTUnwrap(split.first { $0.primaryNodeID == fixture.firstNode.nodeID })
        XCTAssertEqual(first.members.map(\.id), [fixture.firstNode.nodeID])
    }

    func testManualSeparateDecisionIsPersistedLocallyAndDoesNotMergeWeakRelation() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let service = WorkItemGroupingDecisionService(vault: fixture.vault)
        let history = try await service.apply(
            .keepSeparate(
                sourceNodeID: fixture.firstNode.nodeID,
                destinationNodeID: fixture.secondNode.nodeID,
                relation: .crossReferences
            ),
            scope: fixture.scope,
            at: fixture.date
        )

        XCTAssertTrue(history.before.isEmpty)
        XCTAssertEqual(history.after.map(\.strength), [.userSeparated])
        let persistedStrengths = try await WorkItemGroupingDecisionRepository(vault: fixture.vault)
            .decisions(for: fixture.scope)
            .map(\.strength)
        XCTAssertEqual(persistedStrengths, [.userSeparated])
        let splitItems = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(splitItems.count, 3)

        _ = try await service.apply(
            .confirmMerge(
                sourceNodeID: fixture.firstNode.nodeID,
                destinationNodeID: fixture.secondNode.nodeID,
                relation: .crossReferences
            ),
            scope: fixture.scope,
            at: fixture.date.addingTimeInterval(1)
        )
        let mergedItems = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(mergedItems.count, 2)
    }

    func testManualGroupingUndoRejectsNewerDecisionAndRestoresExactPriorState() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let service = WorkItemGroupingDecisionService(vault: fixture.vault)
        let history = try await service.apply(
            .confirmMerge(
                sourceNodeID: fixture.firstNode.nodeID,
                destinationNodeID: fixture.secondNode.nodeID,
                relation: .crossReferences
            ),
            scope: fixture.scope,
            at: fixture.date
        )
        try await service.restore(
            history.before,
            expectedCurrent: history.after,
            scope: fixture.scope,
            at: fixture.date.addingTimeInterval(1)
        )
        let restoredDecisions = try await WorkItemGroupingDecisionRepository(vault: fixture.vault)
            .decisions(for: fixture.scope)
        XCTAssertTrue(restoredDecisions.isEmpty)

        do {
            try await service.restore(
                history.before,
                expectedCurrent: history.after,
                scope: fixture.scope,
                at: fixture.date.addingTimeInterval(2)
            )
            XCTFail("A stale undo must not overwrite newer grouping state.")
        } catch {
            XCTAssertEqual(error as? WorkItemGroupingDecisionServiceError, .staleRollbackPreserved)
        }
    }

    func testAssigningSplitActionOwnershipRequiresCurrentCanonicalGroup() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let firstWorkItemID = try await fixture.workItemID(for: fixture.firstNode.nodeID)
        let secondWorkItemID = try await fixture.workItemID(for: fixture.secondNode.nodeID)
        try await fixture.insertAction(workItemID: secondWorkItemID)

        let service = WorkItemGroupingDecisionService(vault: fixture.vault)
        _ = try await service.apply(
            .confirmMerge(
                sourceNodeID: fixture.firstNode.nodeID,
                destinationNodeID: fixture.secondNode.nodeID,
                relation: .crossReferences
            ),
            scope: fixture.scope,
            at: fixture.date
        )
        try await service.assignActionItem(
            ActionItemID(rawValue: "preserved-donor-action")!,
            expectedOwnerWorkItemID: secondWorkItemID,
            visibleWorkItemID: firstWorkItemID,
            destinationNodeID: fixture.firstNode.nodeID,
            scope: fixture.scope,
            at: fixture.date.addingTimeInterval(1)
        )
        let owner = try await fixture.vault.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT work_item_id FROM action_items WHERE id = 'preserved-donor-action'"
            )
        }
        XCTAssertEqual(owner, firstWorkItemID.rawValue)
    }

    func testProjectionFailureCompensatesDecisionAndRetainsPriorVisibleGraph() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let service = WorkItemGroupingDecisionService(
            vault: fixture.vault,
            project: { _, _ in throw InjectedProjectionError.failed }
        )

        await XCTAssertThrowsErrorAsync {
            try await service.apply(
                .confirmMerge(
                    sourceNodeID: fixture.firstNode.nodeID,
                    destinationNodeID: fixture.secondNode.nodeID,
                    relation: .crossReferences
                ),
                scope: fixture.scope,
                at: fixture.date
            )
        }

        let decisions = try await WorkItemGroupingDecisionRepository(vault: fixture.vault)
            .decisions(for: fixture.scope)
        XCTAssertTrue(decisions.isEmpty)
        let items = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(Set(items.map(\.primaryNodeID)), Set([
            fixture.firstNode.nodeID, fixture.secondNode.nodeID, fixture.thirdNode.nodeID
        ]))
    }

    func testProjectionCancellationCompensatesDecisionAndRetainsPriorVisibleGraph() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let service = WorkItemGroupingDecisionService(
            vault: fixture.vault,
            project: { _, _ in throw CancellationError() }
        )

        await XCTAssertThrowsErrorAsync {
            try await service.apply(
                .confirmMerge(
                    sourceNodeID: fixture.firstNode.nodeID,
                    destinationNodeID: fixture.secondNode.nodeID,
                    relation: .crossReferences
                ),
                scope: fixture.scope,
                at: fixture.date
            )
        }

        let decisions = try await WorkItemGroupingDecisionRepository(vault: fixture.vault)
            .decisions(for: fixture.scope)
        XCTAssertTrue(decisions.isEmpty)
        let items = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(items.count, 3)
    }

    func testSearchRebuildFailureCompensatesCommittedProjection() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let service = WorkItemGroupingDecisionService(
            vault: fixture.vault,
            rebuildSearch: { _ in throw InjectedProjectionError.failed }
        )

        await XCTAssertThrowsErrorAsync {
            try await service.apply(
                .confirmMerge(
                    sourceNodeID: fixture.firstNode.nodeID,
                    destinationNodeID: fixture.secondNode.nodeID,
                    relation: .crossReferences
                ),
                scope: fixture.scope,
                at: fixture.date
            )
        }

        let decisions = try await WorkItemGroupingDecisionRepository(vault: fixture.vault)
            .decisions(for: fixture.scope)
        XCTAssertTrue(decisions.isEmpty)
        let items = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(items.count, 3)
    }

    func testUndoProjectionFailureRestoresTheCurrentDecisionAndVisibleGraph() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await WorkItemGroupingDecisionRepository(vault: fixture.vault).replace(
            [fixture.decision],
            scope: fixture.scope
        )
        try await OrganizationWorkItemGraphProjectionService(vault: fixture.vault)
            .projectAfterNormalizedCommit(for: fixture.scope, at: fixture.date)
        let service = WorkItemGroupingDecisionService(
            vault: fixture.vault,
            project: { _, _ in throw InjectedProjectionError.failed }
        )

        await XCTAssertThrowsErrorAsync {
            try await service.restore(
                [],
                expectedCurrent: [fixture.decision],
                scope: fixture.scope,
                at: fixture.date.addingTimeInterval(1)
            )
        }

        let restoredDecisions = try await WorkItemGroupingDecisionRepository(vault: fixture.vault)
            .decisions(for: fixture.scope)
        XCTAssertEqual(restoredDecisions, [fixture.decision])
        let items = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(items.count, 2)
    }

    func testInterleavedFailurePreservesNewerGroupingDecisionInsteadOfRollingBackOverIt() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let gate = ProjectionGate()
        let failing = WorkItemGroupingDecisionService(
            vault: fixture.vault,
            project: { _, _ in
                await gate.arriveAndWait()
                throw InjectedProjectionError.failed
            }
        )
        let newer = WorkItemGroupingDecisionService(vault: fixture.vault)
        let first = Task {
            try await failing.apply(
                .confirmMerge(
                    sourceNodeID: fixture.firstNode.nodeID,
                    destinationNodeID: fixture.secondNode.nodeID,
                    relation: .crossReferences
                ),
                scope: fixture.scope,
                at: fixture.date
            )
        }
        await gate.waitForArrival()
        let newerHistory = try await newer.apply(
            .keepSeparate(
                sourceNodeID: fixture.firstNode.nodeID,
                destinationNodeID: fixture.secondNode.nodeID,
                relation: .crossReferences
            ),
            scope: fixture.scope,
            at: fixture.date.addingTimeInterval(1)
        )
        await gate.release()

        switch await first.result {
        case .success:
            XCTFail("The injected projection must fail.")
        case let .failure(error):
            XCTAssertEqual(error as? WorkItemGroupingDecisionServiceError, .staleRollbackPreserved)
        }
        XCTAssertEqual(newerHistory.after.map(\.strength), [.userSeparated])
        let persistedStrengths = try await WorkItemGroupingDecisionRepository(vault: fixture.vault)
            .decisions(for: fixture.scope)
            .map(\.strength)
        XCTAssertEqual(persistedStrengths, [.userSeparated])
    }

    func testInterleavedCancellationPreservesNewerGroupingDecisionInsteadOfRollingBackOverIt() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let gate = ProjectionGate()
        let cancelling = WorkItemGroupingDecisionService(
            vault: fixture.vault,
            project: { _, _ in
                await gate.arriveAndWait()
                try Task.checkCancellation()
            }
        )
        let newer = WorkItemGroupingDecisionService(vault: fixture.vault)
        let first = Task {
            try await cancelling.apply(
                .confirmMerge(
                    sourceNodeID: fixture.firstNode.nodeID,
                    destinationNodeID: fixture.secondNode.nodeID,
                    relation: .crossReferences
                ),
                scope: fixture.scope,
                at: fixture.date
            )
        }
        await gate.waitForArrival()
        _ = try await newer.apply(
            .keepSeparate(
                sourceNodeID: fixture.firstNode.nodeID,
                destinationNodeID: fixture.secondNode.nodeID,
                relation: .crossReferences
            ),
            scope: fixture.scope,
            at: fixture.date.addingTimeInterval(1)
        )
        first.cancel()
        await gate.release()

        switch await first.result {
        case .success:
            XCTFail("The cancelled projection must fail.")
        case let .failure(error):
            XCTAssertEqual(error as? WorkItemGroupingDecisionServiceError, .staleRollbackPreserved)
        }
        let persistedStrengths = try await WorkItemGroupingDecisionRepository(vault: fixture.vault)
            .decisions(for: fixture.scope)
            .map(\.strength)
        XCTAssertEqual(persistedStrengths, [.userSeparated])
    }

    func testInterleavedSuccessfulApplyDoesNotOverwriteNewerWindowDecision() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let gate = ProjectionGate()
        let stale = WorkItemGroupingDecisionService(
            vault: fixture.vault,
            beforeInitialInstallation: { _ in
                await gate.arriveAndWait()
            }
        )
        let newer = WorkItemGroupingDecisionService(vault: fixture.vault)

        let first = Task {
            try await stale.apply(
                .confirmMerge(
                    sourceNodeID: fixture.firstNode.nodeID,
                    destinationNodeID: fixture.secondNode.nodeID,
                    relation: .crossReferences
                ),
                scope: fixture.scope,
                at: fixture.date
            )
        }
        await gate.waitForArrival()
        _ = try await newer.apply(
            .keepSeparate(
                sourceNodeID: fixture.firstNode.nodeID,
                destinationNodeID: fixture.secondNode.nodeID,
                relation: .crossReferences
            ),
            scope: fixture.scope,
            at: fixture.date.addingTimeInterval(1)
        )
        await gate.release()

        switch await first.result {
        case .success:
            XCTFail("A stale initial apply must not overwrite a newer window decision.")
        case let .failure(error):
            XCTAssertEqual(error as? WorkItemGroupingDecisionServiceError, .staleRollbackPreserved)
        }
        let persistedStrengths = try await WorkItemGroupingDecisionRepository(vault: fixture.vault)
            .decisions(for: fixture.scope)
            .map(\.strength)
        XCTAssertEqual(persistedStrengths, [.userSeparated])
    }

    func testInterleavedSuccessfulUndoDoesNotOverwriteNewerWindowDecision() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let initial = WorkItemGroupingDecisionService(vault: fixture.vault)
        let history = try await initial.apply(
            .confirmMerge(
                sourceNodeID: fixture.firstNode.nodeID,
                destinationNodeID: fixture.secondNode.nodeID,
                relation: .crossReferences
            ),
            scope: fixture.scope,
            at: fixture.date
        )
        let gate = ProjectionGate()
        let staleUndo = WorkItemGroupingDecisionService(
            vault: fixture.vault,
            beforeInitialInstallation: { _ in
                await gate.arriveAndWait()
            }
        )
        // Deliberately leave the newer write unprojected. The rejected stale
        // undo must rebuild the graph from that current scoped state.
        let newer = WorkItemGroupingDecisionService(
            vault: fixture.vault,
            project: { _, _ in }
        )

        let undo = Task {
            try await staleUndo.restore(
                history.before,
                expectedCurrent: history.after,
                scope: fixture.scope,
                at: fixture.date.addingTimeInterval(1)
            )
        }
        await gate.waitForArrival()
        _ = try await newer.apply(
            .keepSeparate(
                sourceNodeID: fixture.firstNode.nodeID,
                destinationNodeID: fixture.secondNode.nodeID,
                relation: .crossReferences
            ),
            scope: fixture.scope,
            at: fixture.date.addingTimeInterval(2)
        )
        await gate.release()

        switch await undo.result {
        case .success:
            XCTFail("A stale undo must not overwrite a newer window decision.")
        case let .failure(error):
            XCTAssertEqual(error as? WorkItemGroupingDecisionServiceError, .staleRollbackPreserved)
        }
        let persistedStrengths = try await WorkItemGroupingDecisionRepository(vault: fixture.vault)
            .decisions(for: fixture.scope)
            .map(\.strength)
        XCTAssertEqual(persistedStrengths, [.userSeparated])
        let items = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(items.count, 3)
    }

    func testSuccessfulApplyHistoryDoesNotFenceALaterWindowDecisionAsItsOwn() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let gate = ProjectionGate()
        let firstService = WorkItemGroupingDecisionService(
            vault: fixture.vault,
            project: { _, _ in
                await gate.arriveAndWait()
            }
        )
        let newerService = WorkItemGroupingDecisionService(vault: fixture.vault)

        let first = Task {
            try await firstService.apply(
                .confirmMerge(
                    sourceNodeID: fixture.firstNode.nodeID,
                    destinationNodeID: fixture.secondNode.nodeID,
                    relation: .crossReferences
                ),
                scope: fixture.scope,
                at: fixture.date
            )
        }
        await gate.waitForArrival()
        _ = try await newerService.apply(
            .keepSeparate(
                sourceNodeID: fixture.firstNode.nodeID,
                destinationNodeID: fixture.secondNode.nodeID,
                relation: .crossReferences
            ),
            scope: fixture.scope,
            at: fixture.date.addingTimeInterval(1)
        )
        await gate.release()
        let firstHistory = try await first.value

        XCTAssertEqual(firstHistory.after.map(\.strength), [.userConfirmed])
        do {
            try await firstService.restore(
                firstHistory.before,
                expectedCurrent: firstHistory.after,
                scope: fixture.scope,
                at: fixture.date.addingTimeInterval(2)
            )
            XCTFail("Undo must not treat a later window decision as this operation's state.")
        } catch {
            XCTAssertEqual(error as? WorkItemGroupingDecisionServiceError, .staleRollbackPreserved)
        }
        let persistedStrengths = try await WorkItemGroupingDecisionRepository(vault: fixture.vault)
            .decisions(for: fixture.scope)
            .map(\.strength)
        XCTAssertEqual(persistedStrengths, [.userSeparated])
    }

    private enum InjectedProjectionError: Error { case failed }

    private actor ProjectionGate {
        private var arrived = false
        private var arrivalContinuation: CheckedContinuation<Void, Never>?
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func arriveAndWait() async {
            arrived = true
            arrivalContinuation?.resume()
            arrivalContinuation = nil
            await withCheckedContinuation { releaseContinuation = $0 }
        }

        func waitForArrival() async {
            guard !arrived else { return }
            await withCheckedContinuation { arrivalContinuation = $0 }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    func testExplicitCurrentHydrationClosingReferenceMergesWhilePartialCoverageFailsClosed() async throws {
        let accepted = try await Fixture()
        defer { accepted.remove() }
        try await accepted.installClosingPullRequestEvidence(status: .complete)
        try await OrganizationWorkItemGraphProjectionService(vault: accepted.vault)
            .projectAfterNormalizedCommit(for: accepted.scope, at: accepted.date)
        let merged = try await WorkItemRepository(vault: accepted.vault).fetch(
            accountID: accepted.accountID, organizationID: accepted.organizationID
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(
            Set(try XCTUnwrap(merged.first { $0.primaryNodeID == accepted.firstNode.nodeID }).members.map(\.id)),
            Set([accepted.firstNode.nodeID, accepted.secondNode.nodeID])
        )
        let reverse = try await accepted.vault.read { database in
            try Row.fetchOne(database, sql: """
                SELECT relations.subject_node_id, relations.object_node_id,
                       relation_evidence.source_node_id, relation_evidence.raw_snapshot_id
                FROM relations
                JOIN relation_evidence ON relation_evidence.relation_id = relations.id
                WHERE relations.kind = 'closedBy'
                """).map { row in
                    (
                        subject: row["subject_node_id"] as String?,
                        object: row["object_node_id"] as String?,
                        evidenceNode: row["source_node_id"] as String?,
                        snapshotID: row["raw_snapshot_id"] as String?
                    )
                }
        }
        XCTAssertEqual(reverse?.subject, accepted.firstNode.nodeID.rawValue)
        XCTAssertEqual(reverse?.object, accepted.secondNode.nodeID.rawValue)
        XCTAssertEqual(reverse?.evidenceNode, accepted.secondNode.nodeID.rawValue)
        XCTAssertEqual(reverse?.snapshotID, "closing-source-complete")

        let partial = try await Fixture()
        defer { partial.remove() }
        try await partial.installClosingPullRequestEvidence(status: .partial)
        try await OrganizationWorkItemGraphProjectionService(vault: partial.vault)
            .projectAfterNormalizedCommit(for: partial.scope, at: partial.date)
        let unmerged = try await WorkItemRepository(vault: partial.vault).fetch(
            accountID: partial.accountID, organizationID: partial.organizationID
        )
        XCTAssertEqual(unmerged.count, 3)
    }

    func testAuthoritativeWeakContentRelationsStayContextualInProductionProjection() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.installAuthoritativeWeakContentRelations()

        try await OrganizationWorkItemGraphProjectionService(vault: fixture.vault)
            .projectAfterNormalizedCommit(for: fixture.scope, at: fixture.date)

        let items = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(items.count, 3, "Only explicit closing relations may merge these items.")
        let first = try XCTUnwrap(items.first { $0.primaryNodeID == fixture.firstNode.nodeID })
        XCTAssertEqual(
            Set(first.contextLinks.map { "\($0.id.rawValue)\u{0}\($0.relation.rawValue)" }),
            Set([
                "\(fixture.secondNode.nodeID.rawValue)\u{0}\(WorkRelationKind.duplicateOf.rawValue)",
                "\(fixture.secondNode.nodeID.rawValue)\u{0}\(WorkRelationKind.blockedBy.rawValue)",
                "\(fixture.thirdNode.nodeID.rawValue)\u{0}\(WorkRelationKind.crossReferences.rawValue)",
                "\(fixture.thirdNode.nodeID.rawValue)\u{0}\(WorkRelationKind.blocks.rawValue)"
            ])
        )
    }

    func testHydrationResponsibilityRelationsRequireCurrentCompleteRawCoverage() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.installCurrentHydrationResponsibilityEvidence(
            closingIssueNodeID: fixture.firstNode.nodeID
        )

        try await OrganizationWorkItemGraphProjectionService(vault: fixture.vault)
            .projectAfterNormalizedCommit(for: fixture.scope, at: fixture.date)

        let items = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            authorityScope: fixture.scope
        )
        let pullRequest = try XCTUnwrap(items.first { item in
            item.members.contains { $0.id == fixture.secondNode.nodeID }
        })
        let materialized = Set(pullRequest.relations.map { relation in
            "\(relation.kind.rawValue)\u{0}\(relation.objectNodeID?.rawValue ?? "")"
        })
        XCTAssertTrue(materialized.contains("authored\u{0}account-node"))
        XCTAssertTrue(materialized.contains("assigned\u{0}account-node"))
        XCTAssertTrue(materialized.contains("reviewRequestedDirectly\u{0}reviewer-node"))
        XCTAssertTrue(materialized.contains("reviewRequestedFromTeam\u{0}review-team-node"))
        XCTAssertTrue(materialized.contains("awaitingResponse\u{0}reviewer-node"))
        XCTAssertTrue(materialized.contains("closes\u{0}\(fixture.firstNode.nodeID.rawValue)"))
        XCTAssertTrue(pullRequest.relations.allSatisfy {
            $0.evidence.allSatisfy { $0.sourceRevision == fixture.secondNode.sourceRevision }
        })
    }

    func testRoleDiscoveryMentionsMaterializeOnlyForCurrentDirectAndVisibleTeamScopes() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.installCurrentRoleMentionEvidence()

        try await OrganizationWorkItemGraphProjectionService(vault: fixture.vault)
            .projectAfterNormalizedCommit(for: fixture.scope, at: fixture.date)

        let items = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            authorityScope: fixture.scope
        )
        let pullRequest = try XCTUnwrap(items.first { $0.primaryNodeID == fixture.secondNode.nodeID })
        let materialized = Set(pullRequest.relations.map { relation in
            "\(relation.kind.rawValue)\u{0}\(relation.objectNodeID?.rawValue ?? "")"
        })
        XCTAssertTrue(materialized.contains("mentioned\u{0}account-node"))
        XCTAssertTrue(materialized.contains("teamMentioned\u{0}review-team-node"))
    }

    private final class Fixture: @unchecked Sendable {
        let directory: URL
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: "github")!
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let vault: AccountVault
        let firstNode: NormalizedGitHubNode
        let secondNode: NormalizedGitHubNode
        let thirdNode: NormalizedGitHubNode
        let decision: WorkItemGroupingDecision
        let scope: SynchronizationScope

        init() async throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            vault = try await VaultRegistry(rootDirectory: directory).open(
                accountID: accountID,
                vaultKey: try VaultKey.generate()
            )
            scope = SynchronizationScope(
                accountID: accountID,
                organizationID: organizationID,
                credentialRevision: CredentialRevision(rawValue: "credential-1")!,
                capabilityRevision: CapabilityRevision(rawValue: "capability-1")!
            )
            let account = GitHubAccount(
                id: accountID,
                githubUserID: 1,
                nodeID: GitHubNodeID(rawValue: "account-node")!,
                login: "octocat",
                authenticationKind: .oauth,
                credentialID: CredentialID.make(),
                credentialStatus: .active,
                createdAt: date,
                lastValidatedAt: date
            )
            let organization = GitHubOrganization(
                id: organizationID,
                githubOrganizationID: 2,
                nodeID: GitHubNodeID(rawValue: "organization-node")!,
                login: "github"
            )
            let access = OrganizationAccess(
                accountID: accountID,
                organizationID: organizationID,
                state: .available,
                capabilityRevision: CapabilityRevision(rawValue: "capability-1")!,
                capabilities: [],
                checkedAt: date
            )
            let accounts = AccountRepository(vault: vault)
            try await accounts.save(
                account,
                credentialRevision: CredentialRevision(rawValue: "credential-1")!
            )
            try await accounts.save(organization, access: access, selectedAt: date)

            firstNode = Self.makeNode(
                id: GitHubNodeID(rawValue: "first-node")!,
                accountID: accountID,
                organizationID: organizationID,
                date: date
            )
            secondNode = Self.makeNode(
                id: GitHubNodeID(rawValue: "second-node")!,
                accountID: accountID,
                organizationID: organizationID,
                date: date,
                kind: .pullRequest
            )
            thirdNode = Self.makeNode(
                id: GitHubNodeID(rawValue: "third-node")!,
                accountID: accountID,
                organizationID: organizationID,
                date: date
            )
            let nodes = GitHubNodeRepository(vault: vault)
            try await nodes.save(firstNode)
            try await nodes.save(secondNode)
            try await nodes.save(thirdNode)
            let workItems = WorkItemRepository(vault: vault)
            _ = try await workItems.ensureWorkItem(for: firstNode)
            _ = try await workItems.ensureWorkItem(for: secondNode)
            _ = try await workItems.ensureWorkItem(for: thirdNode)
            decision = WorkItemGroupingDecision(
                sourceNodeID: firstNode.nodeID,
                destinationNodeID: secondNode.nodeID,
                relation: .crossReferences,
                strength: .userConfirmed,
                evidence: [
                    EvidenceReference(
                        id: EvidenceID(rawValue: "link-evidence")!,
                        source: .localWorkflow,
                        locator: .localWorkflow("grouping-decision"),
                        authority: .localWorkflow(accountID: accountID, organizationID: organizationID),
                        nodeID: firstNode.nodeID,
                        confidence: .confirmed,
                        confirmation: .confirmed,
                        observedAt: date,
                        excerpt: "Linked pull request closes this issue."
                    )
                ],
                decidedAt: date
            )
            let streamID = SyncStreamID(rawValue: "grouping-projection-timeline")!
            try await SyncStreamRepository(vault: vault).save(
                SyncStream(
                    id: streamID,
                    accountID: accountID,
                    organizationID: organizationID,
                    feature: .timelines,
                    highWater: nil,
                    lastSuccessfulAt: date,
                    lastAttemptAt: date,
                    status: .complete,
                    failureDetail: nil
                )
            )
            try await vault.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO relations (
                            id, account_id, subject_node_id, object_node_id, kind,
                            confidence, observed_at_ms
                        ) VALUES (?, ?, ?, ?, 'crossReferences', 'confirmed', ?)
                        """,
                    arguments: [
                        "grouping-projection-context", accountID.rawValue,
                        firstNode.nodeID.rawValue, thirdNode.nodeID.rawValue,
                        Int64(date.timeIntervalSince1970 * 1_000)
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
                        ) VALUES (?, ?, 'graphQL', 'query', 'grouping-projection',
                                  'github', ?, ?, 'timelines', ?, ?, ?, ?, NULL,
                                  'revision-1', NULL, 'confirmed', 'confirmed', ?, NULL)
                        """,
                    arguments: [
                        "grouping-projection-context", "grouping-projection-evidence",
                        accountID.rawValue, organizationID.rawValue, streamID.rawValue,
                        scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue,
                        firstNode.nodeID.rawValue, Int64(date.timeIntervalSince1970 * 1_000)
                    ]
                )
            }
            try await OrganizationSchedulerStateRepository(vault: vault).save(
                OrganizationSchedulerState(
                    accountID: accountID,
                    organizationID: organizationID,
                    credentialRevision: scope.credentialRevision,
                    capabilityRevision: scope.capabilityRevision,
                    nextIncrementalRefreshAt: date.addingTimeInterval(60),
                    nextFullReconciliationAt: date.addingTimeInterval(3_600),
                    rateLimitedUntil: nil,
                    blockedReason: nil,
                    consecutiveTransientFailureCount: 0,
                    activeAttemptID: nil,
                    lastAttemptAt: date,
                    lastCompletedAt: date,
                    generation: 1,
                    updatedAt: date
                )
            )
        }

        func node(id: GitHubNodeID, accountID: AccountID) -> NormalizedGitHubNode {
            Self.makeNode(id: id, accountID: accountID, organizationID: organizationID, date: date)
        }

        func workItemID(for nodeID: GitHubNodeID) async throws -> WorkItemID {
            let ids = try await WorkItemRepository(vault: vault).identifiers(
                for: [nodeID], accountID: accountID
            )
            return try XCTUnwrap(ids.first)
        }

        func insertAction(workItemID: WorkItemID) async throws {
            try await vault.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO action_items (
                            id, work_item_id, title, detail, origin, state, priority,
                            due_at_ms, source_fingerprint, created_at_ms, updated_at_ms,
                            completed_at_ms, dismissed_at_ms
                        ) VALUES ('preserved-donor-action', ?, 'Preserved action', NULL,
                                  'manual', 'open', 2, NULL, NULL, ?, ?, NULL, NULL)
                        """,
                    arguments: [
                        workItemID.rawValue,
                        Int64(date.timeIntervalSince1970 * 1_000),
                        Int64(date.timeIntervalSince1970 * 1_000)
                    ]
                )
            }
        }

        func installClosingPullRequestEvidence(status: CoverageStatus) async throws {
            let streamID = SyncStreamID(rawValue: "hydration-pull-requests-\(organizationID.rawValue)")!
            try await SyncStreamRepository(vault: vault).save(
                SyncStream(
                    id: streamID,
                    accountID: accountID,
                    organizationID: organizationID,
                    feature: .pullRequests,
                    highWater: nil,
                    lastSuccessfulAt: date,
                    lastAttemptAt: date,
                    status: status,
                    failureDetail: nil
                )
            )
            try await CoverageRepository(vault: vault).save(
                CoverageRecord(
                    accountID: accountID,
                    organizationID: organizationID,
                    repositoryID: nil,
                    feature: .pullRequests,
                    streamID: streamID,
                    intervalStart: nil,
                    intervalEnd: nil,
                    credentialRevision: scope.credentialRevision,
                    capabilityRevision: scope.capabilityRevision,
                    status: status,
                    lastSuccessfulAt: status == .complete ? date : nil,
                    failureDetail: nil
                ),
                attemptedAt: date
            )
            let payload = Data("""
                {"data":{"nodes":[{"id":"\(secondNode.nodeID.rawValue)","closingIssuesReferences":{"nodes":[{"id":"\(firstNode.nodeID.rawValue)"}],"pageInfo":{"hasNextPage":false}}}]}}
                """.utf8)
            try await RawAPISnapshotRepository(vault: vault).save(
                RawAPISnapshot(
                    id: RawAPISnapshotID(rawValue: "closing-source-\(status.rawValue)")!,
                    accountID: accountID,
                    githubNodeID: secondNode.nodeID,
                    endpoint: "graphql:TriageHydrateNodes",
                    eTag: nil,
                    parserVersion: 2,
                    observedAt: date,
                    payload: payload,
                    requestIdentity: ConditionalRequestIdentity(
                        scope: scope,
                        feature: .pullRequests,
                        streamID: streamID,
                        requestKey: "graphql:TriageHydrateNodes/node=\(secondNode.nodeID.rawValue)"
                    )
                )
            )
        }

        func installCurrentHydrationResponsibilityEvidence(
            closingIssueNodeID: GitHubNodeID? = nil
        ) async throws {
            let streamID = SyncStreamID(rawValue: "hydration-pull-requests-\(organizationID.rawValue)")!
            try await SyncStreamRepository(vault: vault).save(
                SyncStream(
                    id: streamID,
                    accountID: accountID,
                    organizationID: organizationID,
                    feature: .pullRequests,
                    highWater: nil,
                    lastSuccessfulAt: date,
                    lastAttemptAt: date,
                    status: .complete,
                    failureDetail: nil
                )
            )
            try await CoverageRepository(vault: vault).save(
                CoverageRecord(
                    accountID: accountID,
                    organizationID: organizationID,
                    repositoryID: nil,
                    feature: .pullRequests,
                    streamID: streamID,
                    intervalStart: nil,
                    intervalEnd: nil,
                    credentialRevision: scope.credentialRevision,
                    capabilityRevision: scope.capabilityRevision,
                    status: .complete,
                    lastSuccessfulAt: date,
                    failureDetail: nil
                ),
                attemptedAt: date
            )
            try await ActorRepository(vault: vault).save(
                ActorSummary(
                    id: ActorID(rawValue: "reviewer-actor")!,
                    nodeID: GitHubNodeID(rawValue: "reviewer-node")!,
                    login: "reviewer",
                    displayName: nil,
                    avatarURL: nil
                ),
                observedAt: date
            )
            try await vault.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO teams (id, organization_id, github_node_id, slug, name, privacy, updated_at_ms)
                        VALUES ('review-team-node', ?, 'review-team-node', 'triage', 'Triage', NULL, ?)
                        """,
                    arguments: [organizationID.rawValue, Int64(date.timeIntervalSince1970 * 1_000)]
                )
                try database.execute(
                    sql: """
                        INSERT INTO team_memberships (account_id, team_id, membership_state, observed_at_ms, expires_at_ms)
                        VALUES (?, 'review-team-node', 'active', ?, NULL)
                        """,
                    arguments: [accountID.rawValue, Int64(date.timeIntervalSince1970 * 1_000)]
                )
            }
            let closingNodes = closingIssueNodeID.map { "{\"id\":\"\($0.rawValue)\"}" } ?? ""
            let payload = Data("""
                {"data":{"nodes":[{"id":"\(secondNode.nodeID.rawValue)","author":{"id":"account-node"},"assignees":{"nodes":[{"id":"account-node"}],"pageInfo":{"hasNextPage":false}},"reviewRequests":{"nodes":[{"requestedReviewer":{"id":"reviewer-node","login":"reviewer"}},{"requestedReviewer":{"id":"review-team-node","slug":"triage"}}],"pageInfo":{"hasNextPage":false}},"closingIssuesReferences":{"nodes":[\(closingNodes)],"pageInfo":{"hasNextPage":false}}}]}}
                """.utf8)
            try await RawAPISnapshotRepository(vault: vault).save(
                RawAPISnapshot(
                    id: RawAPISnapshotID(rawValue: "hydration-responsibility-source")!,
                    accountID: accountID,
                    githubNodeID: secondNode.nodeID,
                    endpoint: "graphql:TriageHydrateNodes",
                    eTag: nil,
                    parserVersion: 2,
                    observedAt: date,
                    payload: payload,
                    requestIdentity: ConditionalRequestIdentity(
                        scope: scope,
                        feature: .pullRequests,
                        streamID: streamID,
                        requestKey: "graphql:TriageHydrateNodes/node=\(secondNode.nodeID.rawValue)"
                    )
                )
            )
        }

        func installCurrentRoleMentionEvidence() async throws {
            let sourceRevision = date.ISO8601Format()
            try await GitHubNodeRepository(vault: vault).save(
                Self.makeNode(
                    id: secondNode.nodeID,
                    accountID: accountID,
                    organizationID: organizationID,
                    date: date,
                    kind: .pullRequest,
                    sourceRevision: sourceRevision
                )
            )
            let streamID = SyncStreamID(rawValue: "role-discovery-\(organizationID.rawValue)-open-direct-mentions")!
            try await SyncStreamRepository(vault: vault).save(
                SyncStream(
                    id: streamID,
                    accountID: accountID,
                    organizationID: organizationID,
                    feature: .roleDiscovery,
                    highWater: nil,
                    lastSuccessfulAt: date,
                    lastAttemptAt: date,
                    status: .complete,
                    failureDetail: nil
                )
            )
            try await CoverageRepository(vault: vault).save(
                CoverageRecord(
                    accountID: accountID,
                    organizationID: organizationID,
                    repositoryID: nil,
                    feature: .roleDiscovery,
                    streamID: streamID,
                    intervalStart: nil,
                    intervalEnd: nil,
                    credentialRevision: scope.credentialRevision,
                    capabilityRevision: scope.capabilityRevision,
                    status: .complete,
                    lastSuccessfulAt: date,
                    failureDetail: nil
                ),
                attemptedAt: date
            )
            try await vault.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO teams (id, organization_id, github_node_id, slug, name, privacy, updated_at_ms)
                        VALUES ('review-team-node', ?, 'review-team-node', 'triage', 'Triage', NULL, ?)
                        """,
                    arguments: [organizationID.rawValue, Int64(date.timeIntervalSince1970 * 1_000)]
                )
                try database.execute(
                    sql: """
                        INSERT INTO team_memberships (account_id, team_id, membership_state, observed_at_ms, expires_at_ms)
                        VALUES (?, 'review-team-node', 'active', ?, NULL)
                        """,
                    arguments: [accountID.rawValue, Int64(date.timeIntervalSince1970 * 1_000)]
                )
            }
            let directQuery = try GitHubIssueSearchQuery(
                organizationLogin: "github",
                userLogin: "octocat",
                state: .open,
                relationship: .mentioned
            )
            try await installRoleMentionPage(
                query: directQuery,
                streamID: streamID,
                snapshotID: "direct-mention-role-source"
            )
            let teamStreamID = SyncStreamID(rawValue: "role-discovery-\(organizationID.rawValue)-open-team-mentions")!
            try await SyncStreamRepository(vault: vault).save(
                SyncStream(
                    id: teamStreamID,
                    accountID: accountID,
                    organizationID: organizationID,
                    feature: .roleDiscovery,
                    highWater: nil,
                    lastSuccessfulAt: date,
                    lastAttemptAt: date,
                    status: .complete,
                    failureDetail: nil
                )
            )
            try await CoverageRepository(vault: vault).save(
                CoverageRecord(
                    accountID: accountID,
                    organizationID: organizationID,
                    repositoryID: nil,
                    feature: .roleDiscovery,
                    streamID: teamStreamID,
                    intervalStart: nil,
                    intervalEnd: nil,
                    credentialRevision: scope.credentialRevision,
                    capabilityRevision: scope.capabilityRevision,
                    status: .complete,
                    lastSuccessfulAt: date,
                    failureDetail: nil
                ),
                attemptedAt: date
            )
            let teamQuery = try GitHubIssueSearchQuery(
                organizationLogin: "github",
                userLogin: "octocat",
                state: .open,
                relationship: .teamMentioned(
                    teamNodeID: GitHubNodeID(rawValue: "review-team-node")!,
                    teamSlug: "triage"
                )
            )
            try await installRoleMentionPage(
                query: teamQuery,
                streamID: teamStreamID,
                snapshotID: "team-mention-role-source"
            )
        }

        private func installRoleMentionPage(
            query: GitHubIssueSearchQuery,
            streamID: SyncStreamID,
            snapshotID: String
        ) async throws {
            let identity = try GitHubIssueSearchRequestIdentity(
                query: query,
                page: 1,
                scope: scope,
                streamID: streamID
            )
            let timestamp = date.ISO8601Format()
            let payload = Data("""
                {"total_count":1,"incomplete_results":false,"items":[{"id":1,"node_id":"\(secondNode.nodeID.rawValue)","number":1,"title":"Grouping node","state":"open","html_url":"https://github.com/github/triage/pull/1","created_at":"\(timestamp)","updated_at":"\(timestamp)","closed_at":null,"pull_request":{"url":"https://api.github.com/repos/github/triage/pulls/1"},"repository_url":"https://api.github.com/repos/github/triage"}]}
                """.utf8)
            let snapshot = RawAPISnapshot(
                id: RawAPISnapshotID(rawValue: snapshotID)!,
                accountID: accountID,
                githubNodeID: nil,
                endpoint: identity.endpoint,
                eTag: "\"\(snapshotID)\"",
                parserVersion: GitHubIssueSearchRequestIdentity.parserVersion,
                observedAt: date,
                payload: payload,
                requestIdentity: ConditionalRequestIdentity(
                    scope: scope,
                    feature: .roleDiscovery,
                    streamID: streamID,
                    requestKey: identity.requestKey
                )
            )
            try await RawAPISnapshotRepository(vault: vault).save(snapshot)
            try await RoleSearchPageReplayRepository(vault: vault).save(
                RoleSearchPageReplay(
                    requestKey: identity.requestKey,
                    accountID: accountID,
                    organizationID: organizationID,
                    streamID: streamID,
                    queryValue: query.value,
                    page: 1,
                    endpoint: identity.endpoint,
                    credentialRevision: scope.credentialRevision,
                    capabilityRevision: scope.capabilityRevision,
                    rawSnapshotID: snapshot.id,
                    eTag: snapshot.eTag,
                    lastModified: nil,
                    parserVersion: GitHubIssueSearchRequestIdentity.parserVersion,
                    lastValidatedAt: date
                )
            )
        }

        func installAuthoritativeWeakContentRelations() async throws {
            let streamID = SyncStreamID(rawValue: "authoritative-weak-content-relations")!
            try await SyncStreamRepository(vault: vault).save(
                SyncStream(
                    id: streamID,
                    accountID: accountID,
                    organizationID: organizationID,
                    feature: .timelines,
                    highWater: nil,
                    lastSuccessfulAt: date,
                    lastAttemptAt: date,
                    status: .complete,
                    failureDetail: nil
                )
            )
            try await CoverageRepository(vault: vault).save(
                CoverageRecord(
                    accountID: accountID,
                    organizationID: organizationID,
                    repositoryID: nil,
                    feature: .timelines,
                    streamID: streamID,
                    intervalStart: nil,
                    intervalEnd: nil,
                    credentialRevision: scope.credentialRevision,
                    capabilityRevision: scope.capabilityRevision,
                    status: .complete,
                    lastSuccessfulAt: date,
                    failureDetail: nil
                ),
                attemptedAt: date
            )
            let snapshotID = RawAPISnapshotID(rawValue: "authoritative-weak-content-snapshot")!
            let requestKey = "GET /repos/github/triage/issues/1/timeline?relation-fixture=1"
            try await RawAPISnapshotRepository(vault: vault).save(
                RawAPISnapshot(
                    id: snapshotID,
                    accountID: accountID,
                    githubNodeID: firstNode.nodeID,
                    endpoint: requestKey.dropFirst(4).description,
                    eTag: nil,
                    parserVersion: 1,
                    observedAt: date,
                    payload: Data("[]".utf8),
                    requestIdentity: ConditionalRequestIdentity(
                        scope: scope,
                        feature: .timelines,
                        streamID: streamID,
                        requestKey: requestKey
                    )
                )
            )
            let authority = RelationReplacementAuthority(
                source: .restTimeline,
                locator: .query(requestKey),
                scope: scope,
                feature: .timelines,
                streamID: streamID,
                repositoryID: nil,
                sourceRevision: firstNode.sourceRevision,
                rawSnapshotID: snapshotID,
                observedAt: date,
                mode: .completeReconciliation
            )
            let specifications: [(WorkRelationKind, GitHubNodeID)] = [
                (.crossReferences, thirdNode.nodeID),
                (.duplicateOf, secondNode.nodeID),
                (.blockedBy, secondNode.nodeID),
                (.blocks, thirdNode.nodeID)
            ]
            let relations = specifications.map { kind, objectNodeID in
                WorkRelation(
                    kind: kind,
                    subjectNodeID: firstNode.nodeID,
                    objectNodeID: objectNodeID,
                    confidence: .confirmed,
                    evidence: [EvidenceReference(
                        id: EvidenceID(rawValue: "weak-content-\(kind.rawValue)-\(objectNodeID.rawValue)")!,
                        source: .restTimeline,
                        locator: .query(requestKey),
                        authority: .github(scope: scope, feature: .timelines, streamID: streamID),
                        nodeID: firstNode.nodeID,
                        sourceRevision: firstNode.sourceRevision,
                        rawSnapshotID: snapshotID,
                        confidence: .confirmed,
                        confirmation: .confirmed,
                        observedAt: date
                    )],
                    observedAt: date
                )
            }
            try await WorkRelationRepository(vault: vault).replace(
                relations,
                accountID: accountID,
                subjectNodeID: firstNode.nodeID,
                authority: authority
            )
        }

        static func makeNode(
            id: GitHubNodeID,
            accountID: AccountID,
            organizationID: OrganizationID,
            date: Date,
            kind: GitHubContentKind = .issue,
            sourceRevision: String = "revision-1"
        ) -> NormalizedGitHubNode {
            NormalizedGitHubNode(
                nodeID: id,
                accountID: accountID,
                organizationID: organizationID,
                repositoryID: nil,
                kind: kind,
                numericID: nil,
                number: nil,
                title: "Grouping node",
                state: .open,
                url: URL(string: "https://github.com/github/triage/issues/1")!,
                bodyMarkdown: nil,
                authorID: nil,
                createdAt: date,
                updatedAt: date,
                closedAt: nil,
                mergedAt: nil,
                sourceRevision: sourceRevision,
                observedAt: date,
                accessibility: .accessible
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
