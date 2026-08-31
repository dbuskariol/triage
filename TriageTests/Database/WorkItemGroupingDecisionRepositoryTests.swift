import GRDB
import XCTest
@testable import Triage

final class WorkItemGroupingDecisionRepositoryTests: XCTestCase {
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

        static func makeNode(
            id: GitHubNodeID,
            accountID: AccountID,
            organizationID: OrganizationID,
            date: Date,
            kind: GitHubContentKind = .issue
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
                sourceRevision: "revision-1",
                observedAt: date,
                accessibility: .accessible
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
