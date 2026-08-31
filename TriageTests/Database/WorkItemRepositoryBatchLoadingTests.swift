import Foundation
import GRDB
import XCTest
@testable import Triage

final class WorkItemRepositoryBatchLoadingTests: XCTestCase {
    func testFetchBatchesGraphQueriesAndPreservesChildCollections() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let counter = QueryCounter()
        let repository = WorkItemRepository(vault: fixture.vault) {
            counter.increment()
        }

        let items = try await repository.fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )

        XCTAssertEqual(items.count, fixture.itemCount)
        XCTAssertEqual(items.map(\.title), (0..<fixture.itemCount).reversed().map { "Work \($0)" })
        for item in items {
            XCTAssertEqual(item.members.count, 1)
            XCTAssertEqual(item.attentionReasons.map(\.ruleID), ["direct"])
            XCTAssertEqual(item.actionItems.map(\.title), ["Action \(item.id.rawValue)"])
            XCTAssertTrue(item.contextLinks.isEmpty)
            XCTAssertTrue(item.relations.isEmpty)
        }

        // Root rows plus bounded set reads for attention reasons/evidence,
        // actions/evidence, members, context links, member content, and
        // relations. The absent relation-evidence query is deliberately not
        // issued. This must not grow with `itemCount`.
        XCTAssertEqual(counter.value, 9)
    }

    func testInboxKeysetPagesMatchFullGraphWithoutDuplicatesOrGaps() async throws {
        let fixture = try await Fixture(itemCount: 501)
        defer { fixture.remove() }
        let repository = WorkItemRepository(vault: fixture.vault)
        let now = Date()
        let freshness = FreshnessState(status: .partial, detail: "Coverage is refreshing.")
        let fullGraph = try await repository.fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            authorityScope: fixture.scope
        )
        let expected = WorkListPresentation.items(from: fullGraph, section: .inbox, at: now)

        var cursor: InboxPageCursor?
        var received: [WorkItem] = []
        repeat {
            let page = try await repository.fetchInboxPage(
                scope: fixture.scope,
                at: now,
                freshness: freshness,
                limit: 47,
                after: cursor
            )
            XCTAssertEqual(page.hasMore, page.nextCursor != nil)
            XCTAssertTrue(page.items.allSatisfy { $0.freshness == freshness })
            received += page.items
            cursor = page.nextCursor
        } while cursor != nil

        XCTAssertEqual(received.map(\.id), expected.map(\.id))
        XCTAssertEqual(Set(received.map(\.id)).count, received.count)
    }

    func testInboxKeysetStitchesMixedDueBucketsIDTiesAndCorruptPriority() async throws {
        let fixture = try await Fixture(itemCount: 6)
        defer { fixture.remove() }
        let repository = WorkItemRepository(vault: fixture.vault)
        let initial = try await repository.fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            authorityScope: fixture.scope
        )
        let identifiersByTitle = Dictionary(uniqueKeysWithValues: initial.map { ($0.title, $0.id.rawValue) })
        let tiedIDs = [identifiersByTitle["Work 2"]!, identifiersByTitle["Work 3"]!].sorted()

        let dueDates: [(String, Int64?)] = [
            ("Work 1", 200),
            ("Work 2", 100),
            ("Work 3", 100),
            ("Work 5", 300)
        ]
        try await fixture.vault.write { database in
            for (title, dueAt) in dueDates {
                try database.execute(
                    sql: "UPDATE action_items SET due_at_ms = ? WHERE work_item_id = ?",
                    arguments: [dueAt, identifiersByTitle[title]!]
                )
            }
            try database.execute(
                sql: "UPDATE work_items SET last_relevant_activity_at_ms = 1000 WHERE id IN (?, ?)",
                arguments: [identifiersByTitle["Work 2"]!, identifiersByTitle["Work 3"]!]
            )
            try database.execute(
                sql: """
                    INSERT INTO workflow_states (
                        work_item_id, status, pinned, priority, snoozed_until_ms,
                        follow_up_at_ms, local_note, updated_at_ms
                    ) VALUES (?, 'active', 0, 99, NULL, NULL, NULL, 1)
                    """,
                arguments: [identifiersByTitle["Work 0"]!]
            )
        }

        let now = Date()
        let fullGraph = try await repository.fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            authorityScope: fixture.scope
        )
        let expected = WorkListPresentation.items(from: fullGraph, section: .inbox, at: now)
        var cursor: InboxPageCursor?
        var received: [WorkItem] = []
        repeat {
            let page = try await repository.fetchInboxPage(
                scope: fixture.scope,
                at: now,
                freshness: FreshnessState(status: .fresh),
                limit: 2,
                after: cursor
            )
            received += page.items
            cursor = page.nextCursor
        } while cursor != nil

        XCTAssertEqual(received.map(\.id), expected.map(\.id))
        XCTAssertEqual(
            received.filter { $0.title == "Work 2" || $0.title == "Work 3" }.map(\.id.rawValue),
            tiedIDs
        )
        XCTAssertEqual(received.first(where: { $0.title == "Work 0" })?.workflow.priority, .normal)
        XCTAssertTrue(received.contains { $0.openActionItems.contains { $0.dueAt == nil } })
        XCTAssertTrue(received.contains { $0.openActionItems.contains { $0.dueAt != nil } })
    }

    func testInboxKeysetCursorRejectsDifferentAuthorityScope() async throws {
        let fixture = try await Fixture(itemCount: 3)
        defer { fixture.remove() }
        let repository = WorkItemRepository(vault: fixture.vault)
        let initial = try await repository.fetchInboxPage(
            scope: fixture.scope,
            at: Date(),
            freshness: FreshnessState(status: .fresh),
            limit: 1,
            after: nil
        )
        let cursor = try XCTUnwrap(initial.nextCursor)
        let otherScope = SynchronizationScope(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: CredentialRevision(rawValue: "credential-2")!,
            capabilityRevision: fixture.scope.capabilityRevision
        )
        let mismatchedCursor = InboxPageCursor(
            scope: otherScope,
            isPinned: cursor.isPinned,
            priority: cursor.priority,
            score: cursor.score,
            earliestOpenActionDueAt: cursor.earliestOpenActionDueAt,
            lastRelevantActivityAt: cursor.lastRelevantActivityAt,
            workItemID: cursor.workItemID
        )

        do {
            _ = try await repository.fetchInboxPage(
                scope: fixture.scope,
                at: Date(),
                freshness: FreshnessState(status: .fresh),
                limit: 1,
                after: mismatchedCursor
            )
            XCTFail("Expected a mismatched cursor scope to be rejected.")
        } catch let error as WorkItemRepositoryError {
            XCTAssertEqual(error, .inboxPageCursorScopeMismatch)
        }
    }

    func testFetchKeepsGraphQueryBudgetBoundedAcrossSQLiteBatchBoundary() async throws {
        let fixture = try await Fixture(itemCount: 501)
        defer { fixture.remove() }

        let counter = QueryCounter()
        let repository = WorkItemRepository(vault: fixture.vault) {
            counter.increment()
        }

        let items = try await repository.fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )

        XCTAssertEqual(items.count, fixture.itemCount)
        XCTAssertEqual(items.first?.title, "Work 500")
        XCTAssertEqual(items.last?.title, "Work 0")
        let identifiers = try await repository.identifiers(
            for: Set(items.map(\.primaryNodeID)),
            accountID: fixture.accountID
        )
        XCTAssertEqual(Set(identifiers), Set(items.map(\.id)))

        // One root query plus two batches for each of the eight graph query
        // shapes. This stays O(query shapes × batches), not O(work items).
        XCTAssertEqual(counter.value, 17)
    }

    func testCancelledFetchStopsBeforeOpeningTheGraphQueries() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let counter = QueryCounter()
        let repository = WorkItemRepository(vault: fixture.vault) {
            counter.increment()
        }
        let gate = FetchGate()
        let task = Task {
            await gate.wait()
            _ = try await repository.fetch(
                accountID: fixture.accountID,
                organizationID: fixture.organizationID
            )
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()

        do {
            _ = try await task.value
            XCTFail("Expected a cancelled fetch.")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(counter.value, 0)
    }

    func testTransferredPrimaryKeepsItsIDAndDropsFormerOrganizationMemberships() async throws {
        let fixture = try await Fixture(itemCount: 2)
        defer { fixture.remove() }
        let repository = WorkItemRepository(vault: fixture.vault)
        let sourceItems = try await repository.fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        let original = try XCTUnwrap(sourceItems.first)
        let destinationOrganizationID = OrganizationID(rawValue: "transferred")!
        let destinationScope = SynchronizationScope(
            accountID: fixture.accountID,
            organizationID: destinationOrganizationID,
            credentialRevision: fixture.scope.credentialRevision,
            capabilityRevision: fixture.scope.capabilityRevision
        )
        let accounts = AccountRepository(vault: fixture.vault)
        try await accounts.save(
            GitHubOrganization(
                id: destinationOrganizationID,
                githubOrganizationID: 3,
                nodeID: GitHubNodeID(rawValue: "MDEyOk9yZ2FuaXphdGlvbjM=")!,
                login: "transferred"
            ),
            access: OrganizationAccess(
                accountID: fixture.accountID,
                organizationID: destinationOrganizationID,
                state: .available,
                capabilityRevision: fixture.scope.capabilityRevision,
                capabilities: [],
                checkedAt: fixture.date
            ),
            selectedAt: fixture.date
        )
        let staleNodeID = try XCTUnwrap(sourceItems.last?.primaryNodeID)
        try await fixture.vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO work_item_members (work_item_id, github_node_id, role)
                    VALUES (?, ?, 'linkedIssue')
                    """,
                arguments: [original.id.rawValue, staleNodeID.rawValue]
            )
            try database.execute(
                sql: """
                    INSERT INTO work_item_context_links (work_item_id, github_node_id, relation)
                    VALUES (?, ?, 'crossReferences')
                    """,
                arguments: [original.id.rawValue, staleNodeID.rawValue]
            )
            try database.execute(
                sql: """
                    INSERT INTO workflow_states (
                        work_item_id, status, pinned, priority, snoozed_until_ms,
                        follow_up_at_ms, local_note, updated_at_ms
                    ) VALUES (?, 'active', 1, 3, NULL, NULL, 'Keep local workflow', 1)
                    ON CONFLICT(work_item_id) DO UPDATE SET
                        pinned = 1, priority = 3, local_note = 'Keep local workflow'
                    """,
                arguments: [original.id.rawValue]
            )
            try database.execute(
                sql: """
                    INSERT INTO work_item_group_memberships (
                        account_id, organization_id, constituent_work_item_id, canonical_work_item_id,
                        credential_revision, capability_revision, source_revision, projected_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 1)
                    """,
                arguments: [
                    fixture.accountID.rawValue,
                    fixture.organizationID.rawValue,
                    sourceItems.last!.id.rawValue,
                    original.id.rawValue,
                    fixture.scope.credentialRevision.rawValue,
                    fixture.scope.capabilityRevision.rawValue,
                    String(repeating: "a", count: 64)
                ]
            )
        }

        let transferredNode = NormalizedGitHubNode(
            nodeID: original.primaryNodeID,
            accountID: fixture.accountID,
            organizationID: destinationOrganizationID,
            repositoryID: nil,
            kind: .issue,
            numericID: "0",
            number: 0,
            title: original.title,
            state: .open,
            url: URL(string: "https://github.com/transferred/triage/issues/0")!,
            bodyMarkdown: nil,
            authorID: nil,
            createdAt: fixture.date,
            updatedAt: fixture.date.addingTimeInterval(1),
            closedAt: nil,
            mergedAt: nil,
            sourceRevision: "transfer-revision",
            observedAt: fixture.date.addingTimeInterval(1),
            accessibility: .accessible
        )
        try await GitHubNodeRepository(vault: fixture.vault).save(transferredNode)
        let transferredID = try await repository.ensureWorkItem(for: transferredNode)

        XCTAssertEqual(transferredID, original.id)
        let remainingSource = try await repository.fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        let sourceStillContainsTransferredItem = remainingSource.contains { $0.id == original.id }
        XCTAssertFalse(sourceStillContainsTransferredItem)
        let destinationItems = try await repository.fetch(
            accountID: fixture.accountID,
            organizationID: destinationOrganizationID,
            authorityScope: destinationScope
        )
        let transferred = try XCTUnwrap(destinationItems.first)
        XCTAssertEqual(transferred.members.map(\.id), [original.primaryNodeID])
        XCTAssertTrue(transferred.contextLinks.isEmpty)
        XCTAssertTrue(transferred.workflow.isPinned)
        XCTAssertEqual(transferred.workflow.priority, .high)
        XCTAssertEqual(transferred.workflow.localNote, "Keep local workflow")

        let groupMemberships = try await fixture.vault.read { database in
            try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*) FROM work_item_group_memberships
                    WHERE constituent_work_item_id = ? OR canonical_work_item_id = ?
                    """,
                arguments: [original.id.rawValue, original.id.rawValue]
            )
        }
        XCTAssertEqual(groupMemberships, 0)
    }

    func testInboxPageMatchesFullGraphEligibilityAndPersistedRankOrder() async throws {
        let fixture = try await Fixture(itemCount: 501)
        defer { fixture.remove() }
        let scope = fixture.scope
        let now = Date()
        let initial = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            authorityScope: scope
        )
        let identifiersByTitle = Dictionary(uniqueKeysWithValues: initial.map { ($0.title, $0.id.rawValue) })
        let inaccessibleID = identifiersByTitle["Work 500"]!
        let resolvedID = identifiersByTitle["Work 495"]!
        let wakeUpID = identifiersByTitle["Work 496"]!
        let workflows: [(id: String, status: String, pinned: Int, priority: Int, snoozedUntil: Int64?)] = [
            (identifiersByTitle["Work 499"]!, "active", 0, 2, Int64((now.addingTimeInterval(3_600).timeIntervalSince1970 * 1_000).rounded())),
            (identifiersByTitle["Work 498"]!, "archived", 0, 2, nil),
            (identifiersByTitle["Work 497"]!, "waiting", 0, 2, nil),
            (wakeUpID, "waiting", 0, 2, nil),
            (identifiersByTitle["Work 0"]!, "active", 1, 3, nil)
        ]

        try await fixture.vault.write { database in
            try database.execute(
                sql: "UPDATE work_items SET state = 'inaccessible' WHERE id = ?",
                arguments: [inaccessibleID]
            )
            try database.execute(
                sql: "UPDATE work_items SET state = 'resolved' WHERE id = ?",
                arguments: [resolvedID]
            )
            for workflow in workflows {
                try database.execute(
                    sql: """
                        INSERT INTO workflow_states (
                            work_item_id, status, pinned, priority, snoozed_until_ms,
                            follow_up_at_ms, local_note, updated_at_ms
                        ) VALUES (?, ?, ?, ?, ?, NULL, NULL, ?)
                        ON CONFLICT(work_item_id) DO UPDATE SET
                            status = excluded.status,
                            pinned = excluded.pinned,
                            priority = excluded.priority,
                            snoozed_until_ms = excluded.snoozed_until_ms,
                            updated_at_ms = excluded.updated_at_ms
                        """,
                    arguments: [
                        workflow.id,
                        workflow.status,
                        workflow.pinned,
                        workflow.priority,
                        workflow.snoozedUntil,
                        1
                    ]
                )
            }
            try database.execute(
                sql: """
                    INSERT INTO attention_reasons (
                        id, work_item_id, rule_id, rule_version, category, strength,
                        title, explanation, evaluated_at_ms
                    ) VALUES ('waiting-wakeup', ?, 'awaitedActorResponded', 1,
                              'waiting', 1, 'Wake up', 'Wake up', 1)
                """,
                arguments: [wakeUpID]
            )
            // The page query and full graph both publish only the current
            // derived run. Bind this fixture's wake-up rule to the exact
            // aggregate revision rather than a syntactically valid stale
            // placeholder, so the assertion exercises eligibility parity.
            let sourceRevision = try DerivedIntelligenceRepository.currentSourceRevision(
                scope: fixture.scope,
                in: database
            )
            try database.execute(
                sql: """
                    INSERT INTO derived_intelligence_runs (
                        account_id, organization_id, credential_revision, capability_revision,
                        source_revision, evaluated_at_ms, coverage_state, freshness_status,
                        is_provisional, freshness_last_successful_at_ms,
                        freshness_next_retry_at_ms, freshness_detail, missing_coverage_json
                    ) VALUES (?, ?, ?, ?, ?, 1, 'trusted', 'fresh', 0, 1, NULL, NULL, ?)
                    """,
                arguments: [
                    fixture.accountID.rawValue,
                    fixture.organizationID.rawValue,
                    fixture.scope.credentialRevision.rawValue,
                    fixture.scope.capabilityRevision.rawValue,
                    sourceRevision,
                    Data("[]".utf8)
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO rule_evaluations (
                        id, account_id, organization_id, work_item_id,
                        credential_revision, capability_revision, source_revision,
                        rule_id, rule_version, category, strength, title, explanation,
                        evaluated_at_ms
                    ) VALUES ('waiting-wakeup', ?, ?, ?, ?, ?, ?, 'awaitedActorResponded', 1,
                              'waiting', 1, 'Wake up', 'Wake up', 1)
                    """,
                arguments: [
                    fixture.accountID.rawValue,
                    fixture.organizationID.rawValue,
                    wakeUpID,
                    fixture.scope.credentialRevision.rawValue,
                    fixture.scope.capabilityRevision.rawValue,
                    sourceRevision
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO rule_evaluation_evidence (
                        rule_evaluation_id, evidence_id, source, source_locator_kind,
                        source_locator, authority_kind, authority_account_id,
                        authority_organization_id, authority_feature,
                        authority_stream_id, authority_credential_revision,
                        authority_capability_revision, source_node_id, source_event_id,
                        source_revision, raw_snapshot_id, confidence, confirmation,
                        observed_at_ms, excerpt
                    ) VALUES ('waiting-wakeup', 'waiting-wakeup-evidence',
                              'localWorkflow', 'localWorkflow', 'workflow://waiting',
                              'localWorkflow', ?, ?, NULL, NULL, NULL, NULL, NULL, NULL,
                              'local', NULL, 'confirmed', 'confirmed', 1, NULL)
                    """,
                arguments: [fixture.accountID.rawValue, fixture.organizationID.rawValue]
            )
        }

        let fullGraph = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            authorityScope: scope
        )
        let expected = Array(
            WorkListPresentation.items(from: fullGraph, section: .inbox, at: now).prefix(50)
        )
        let freshness = FreshnessState(status: .partial, detail: "Coverage is refreshing.")
        let page = try await WorkItemRepository(vault: fixture.vault).fetchInboxPage(
            scope: scope,
            at: now,
            freshness: freshness,
            limit: 50
        )

        XCTAssertEqual(page.map(\.id), expected.map(\.id))
        XCTAssertEqual(page.count, 50)
        XCTAssertTrue(page.allSatisfy { $0.freshness == freshness })
        XCTAssertFalse(page.contains { $0.title == "Work 500" || $0.title == "Work 499" || $0.title == "Work 498" || $0.title == "Work 497" })
        XCTAssertTrue(page.contains { $0.title == "Work 496" })
        XCTAssertTrue(page.contains { $0.title == "Work 495" })
        XCTAssertEqual(page.first?.title, "Work 0")
    }

    func testInboxPageGraphQueryBudgetIsBoundedByTheRequestedPage() async throws {
        let fixture = try await Fixture(itemCount: 501)
        defer { fixture.remove() }
        let counter = QueryCounter()
        let repository = WorkItemRepository(vault: fixture.vault) {
            counter.increment()
        }

        let page = try await repository.fetchInboxPage(
            scope: fixture.scope,
            at: Date(),
            freshness: FreshnessState(status: .fresh),
            limit: 50
        )

        XCTAssertEqual(page.count, 50)
        // One page-root query plus the bounded child graph reads needed by
        // these selected 50 roots. No current rule rows exist in this fixture,
        // so the empty attention-reason batch does not issue a second evidence
        // query. The 501-row fixture still guards against regressing to a full
        // graph followed by `prefix(50)`.
        XCTAssertEqual(counter.value, 8)
    }

    func testInboxPageUsesConstituentActionsForCanonicalGroupEligibilityAndRank() async throws {
        let fixture = try await Fixture(itemCount: 3)
        defer { fixture.remove() }
        let repository = WorkItemRepository(vault: fixture.vault)
        let fullGraph = try await repository.fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            authorityScope: fixture.scope
        )
        let identifiersByTitle = Dictionary(uniqueKeysWithValues: fullGraph.map { ($0.title, $0.id.rawValue) })
        let canonicalID = try XCTUnwrap(identifiersByTitle["Work 0"])
        let constituentID = try XCTUnwrap(identifiersByTitle["Work 1"])

        try await fixture.vault.write { database in
            try database.execute(
                sql: "DELETE FROM attention_reasons WHERE work_item_id = ?",
                arguments: [canonicalID]
            )
            try database.execute(
                sql: "UPDATE action_items SET state = 'completed' WHERE work_item_id = ?",
                arguments: [canonicalID]
            )
            try database.execute(
                sql: "UPDATE action_items SET due_at_ms = 1 WHERE work_item_id = ?",
                arguments: [constituentID]
            )
            try database.execute(
                sql: """
                    INSERT INTO work_item_group_memberships (
                        account_id, organization_id, constituent_work_item_id, canonical_work_item_id,
                        credential_revision, capability_revision, source_revision, projected_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 1)
                    """,
                arguments: [
                    fixture.accountID.rawValue,
                    fixture.organizationID.rawValue,
                    constituentID,
                    canonicalID,
                    fixture.scope.credentialRevision.rawValue,
                    fixture.scope.capabilityRevision.rawValue,
                    String(repeating: "a", count: 64)
                ]
            )
        }

        let expectedGraph = try await repository.fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            authorityScope: fixture.scope
        )
        let expected = WorkListPresentation.items(from: expectedGraph, section: .inbox, at: Date())
        let page = try await repository.fetchInboxPage(
            scope: fixture.scope,
            at: Date(),
            freshness: FreshnessState(status: .fresh),
            limit: 50,
            after: nil
        )

        XCTAssertEqual(page.items.map(\.id), expected.map(\.id))
        XCTAssertEqual(page.items.first?.id.rawValue, canonicalID)
        XCTAssertTrue(page.items.first?.actionItems.contains(where: { $0.workItemID.rawValue == constituentID }) == true)
    }

    func testInboxPageMatchesFullGraphAtSubmillisecondSnoozeBoundary() async throws {
        let fixture = try await Fixture(itemCount: 3)
        defer { fixture.remove() }
        let repository = WorkItemRepository(vault: fixture.vault)
        let initial = try await repository.fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            authorityScope: fixture.scope
        )
        let snoozedID = try XCTUnwrap(initial.first(where: { $0.title == "Work 0" })?.id.rawValue)
        let now = Date(timeIntervalSince1970: 1_000.0006)

        try await fixture.vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO workflow_states (
                        work_item_id, status, pinned, priority, snoozed_until_ms,
                        follow_up_at_ms, local_note, updated_at_ms
                    ) VALUES (?, 'active', 0, 2, 1000001, NULL, NULL, 1)
                    """,
                arguments: [snoozedID]
            )
        }

        let expectedGraph = try await repository.fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            authorityScope: fixture.scope
        )
        let expected = WorkListPresentation.items(from: expectedGraph, section: .inbox, at: now)
        let page = try await repository.fetchInboxPage(
            scope: fixture.scope,
            at: now,
            freshness: FreshnessState(status: .fresh),
            limit: 50,
            after: nil
        )

        XCTAssertEqual(page.items.map(\.id), expected.map(\.id))
        XCTAssertFalse(page.items.contains { $0.id.rawValue == snoozedID })
    }

    func testInboxPageNormalizesCorruptPriorityLikeWorkItemDecoding() async throws {
        let fixture = try await Fixture(itemCount: 3)
        defer { fixture.remove() }
        let repository = WorkItemRepository(vault: fixture.vault)
        let initial = try await repository.fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            authorityScope: fixture.scope
        )
        let corruptPriorityID = try XCTUnwrap(initial.first(where: { $0.title == "Work 0" })?.id.rawValue)

        try await fixture.vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO workflow_states (
                        work_item_id, status, pinned, priority, snoozed_until_ms,
                        follow_up_at_ms, local_note, updated_at_ms
                    ) VALUES (?, 'active', 0, 99, NULL, NULL, NULL, 1)
                    """,
                arguments: [corruptPriorityID]
            )
        }

        let expectedGraph = try await repository.fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            authorityScope: fixture.scope
        )
        let expected = WorkListPresentation.items(from: expectedGraph, section: .inbox, at: Date())
        let page = try await repository.fetchInboxPage(
            scope: fixture.scope,
            at: Date(),
            freshness: FreshnessState(status: .fresh),
            limit: 50,
            after: nil
        )

        XCTAssertEqual(page.items.map(\.id), expected.map(\.id))
        XCTAssertEqual(page.items.first?.title, "Work 2")
    }
}

private actor FetchGate {
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

private final class QueryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class Fixture: @unchecked Sendable {
    let itemCount: Int

    let directory: URL
    let vault: AccountVault
    let accountID = AccountID.make()
    let organizationID = OrganizationID(rawValue: "github")!
    let date = Date(timeIntervalSinceReferenceDate: 1_000)

    var scope: SynchronizationScope {
        SynchronizationScope(
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: CredentialRevision(rawValue: "credential-1")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-1")!
        )
    }

    init(itemCount: Int = 12) async throws {
        self.itemCount = itemCount
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )

        let account = GitHubAccount(
            id: accountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "MDQ6VXNlcjE=")!,
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
            nodeID: GitHubNodeID(rawValue: "MDEyOk9yZ2FuaXphdGlvbjE=")!,
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
        try await accounts.save(account, credentialRevision: CredentialRevision(rawValue: "credential-1")!)
        try await accounts.save(organization, access: access, selectedAt: date)

        let workItems = WorkItemRepository(vault: vault)
        for index in 0..<itemCount {
            let node = NormalizedGitHubNode(
                nodeID: GitHubNodeID(rawValue: "MDU6SXNzdWUx\(index)")!,
                accountID: accountID,
                organizationID: organizationID,
                repositoryID: nil,
                kind: .issue,
                numericID: "\(index)",
                number: index,
                title: "Work \(index)",
                state: .open,
                url: URL(string: "https://github.com/github/triage/issues/\(index)")!,
                bodyMarkdown: nil,
                authorID: nil,
                createdAt: date,
                updatedAt: date.addingTimeInterval(TimeInterval(index)),
                closedAt: nil,
                mergedAt: nil,
                sourceRevision: "revision-\(index)",
                observedAt: date.addingTimeInterval(TimeInterval(index)),
                accessibility: .accessible
            )
            try await GitHubNodeRepository(vault: vault).save(node)
            let workItemID = try await workItems.ensureWorkItem(for: node)
            try await vault.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO attention_reasons (
                            id, work_item_id, rule_id, rule_version, category, strength,
                            title, explanation, evaluated_at_ms
                        ) VALUES (?, ?, 'direct', 1, 'directResponsibility', 10,
                                  'Direct', 'Direct', ?)
                        """,
                    arguments: ["reason-\(index)", workItemID.rawValue, Int64(index)]
                )
            }
            try await WorkflowRepository(vault: vault).save(
                ActionItem(
                    id: ActionItemID.make(),
                    workItemID: workItemID,
                    title: "Action \(workItemID.rawValue)",
                    origin: .manual,
                    state: .open,
                    priority: .normal,
                    createdAt: date,
                    updatedAt: date
                )
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
