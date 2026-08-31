import GRDB
import XCTest
@testable import Triage

final class WorkRelationRepositoryTests: XCTestCase {
    func testReplacingRelationsPersistsEvidenceAndRemovesStaleRelations() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let workItemRepository = WorkItemRepository(vault: fixture.vault)
        let workItemID = try await workItemRepository.ensureWorkItem(for: fixture.node)
        let relation = fixture.relation
        let repository = WorkRelationRepository(vault: fixture.vault)

        try await repository.replace(
            [relation],
            accountID: fixture.accountID,
            subjectNodeID: fixture.node.nodeID,
            authority: fixture.authority
        )

        let persisted = try await workItemRepository.fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted[0].id, workItemID)
        XCTAssertEqual(persisted[0].relations, [relation])

        try await repository.replace(
            [],
            accountID: fixture.accountID,
            subjectNodeID: fixture.node.nodeID,
            authority: fixture.authority
        )
        let relationCount = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM relations")
        }
        let evidenceCount = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM relation_evidence")
        }
        XCTAssertEqual(relationCount, 0)
        XCTAssertEqual(evidenceCount, 0)
    }

    func testCompleteReplacementScopesDeletionToItsRelationFamily() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = WorkRelationRepository(vault: fixture.vault)
        let responsibility = fixture.relation
        let closing = fixture.makeRelation(
            for: fixture.authority,
            kind: .closes,
            evidenceID: "closing-1"
        )

        try await repository.replace(
            [responsibility],
            accountID: fixture.accountID,
            subjectNodeID: fixture.node.nodeID,
            authority: fixture.authority,
            replacingKinds: [.assigned]
        )
        try await repository.replace(
            [closing],
            accountID: fixture.accountID,
            subjectNodeID: fixture.node.nodeID,
            authority: fixture.authority,
            replacingKinds: [.closes]
        )

        try await repository.replace(
            [],
            accountID: fixture.accountID,
            subjectNodeID: fixture.node.nodeID,
            authority: fixture.authority,
            replacingKinds: [.closes]
        )
        let kinds = try await fixture.vault.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT kind FROM relations ORDER BY kind"
            )
        }
        XCTAssertEqual(kinds, [WorkRelationKind.assigned.rawValue])
    }

    func testScopedWorkItemPresentationExcludesMixedRevisionAndCrossOrganizationEvidence() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await WorkItemRepository(vault: fixture.vault).ensureWorkItem(for: fixture.node)
        try await WorkRelationRepository(vault: fixture.vault).replace(
            [fixture.relation],
            accountID: fixture.accountID,
            subjectNodeID: fixture.node.nodeID,
            authority: fixture.authority
        )

        let current = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            authorityScope: fixture.scope
        )
        XCTAssertEqual(current.first?.relations, [fixture.relation])

        try await fixture.vault.write { database in
            try database.execute(
                sql: "UPDATE relation_evidence SET authority_credential_revision = 'retired-credential'"
            )
        }
        let retiredCredential = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            authorityScope: fixture.scope
        )
        XCTAssertTrue(retiredCredential.first?.relations.isEmpty ?? false)

        let otherOrganizationID = OrganizationID(rawValue: "another-organization")!
        try await AccountRepository(vault: fixture.vault).save(
            GitHubOrganization(
                id: otherOrganizationID,
                githubOrganizationID: 3,
                nodeID: GitHubNodeID(rawValue: "MDEyOk9yZ2FuaXphdGlvbjI=")!,
                login: "another-organization"
            ),
            access: OrganizationAccess(
                accountID: fixture.accountID,
                organizationID: otherOrganizationID,
                state: .available,
                capabilityRevision: CapabilityRevision(rawValue: "another-capability")!,
                capabilities: [],
                checkedAt: fixture.date
            ),
            selectedAt: nil
        )
        try await fixture.vault.write { database in
            try database.execute(
                sql: """
                    UPDATE relation_evidence
                    SET authority_credential_revision = ?, authority_organization_id = ?
                    """,
                arguments: [fixture.scope.credentialRevision.rawValue, otherOrganizationID.rawValue]
            )
        }
        let crossOrganization = try await WorkItemRepository(vault: fixture.vault).fetch(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            authorityScope: fixture.scope
        )
        XCTAssertTrue(crossOrganization.first?.relations.isEmpty ?? false)
    }

    func testInboxPagePreservesExactScopedRelationEvidenceAuthority() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let workItemID = try await WorkItemRepository(vault: fixture.vault).ensureWorkItem(for: fixture.node)
        try await WorkflowRepository(vault: fixture.vault).save(
            WorkflowState(isPinned: true, updatedAt: fixture.date),
            for: workItemID
        )
        try await WorkRelationRepository(vault: fixture.vault).replace(
            [fixture.relation],
            accountID: fixture.accountID,
            subjectNodeID: fixture.node.nodeID,
            authority: fixture.authority
        )

        let repository = WorkItemRepository(vault: fixture.vault)
        let current = try await repository.fetchInboxPage(
            scope: fixture.scope,
            at: fixture.date,
            freshness: FreshnessState(status: .fresh),
            limit: 50
        )
        XCTAssertEqual(current.first?.relations, [fixture.relation])

        try await fixture.vault.write { database in
            try database.execute(
                sql: "UPDATE relation_evidence SET authority_credential_revision = 'retired-credential'"
            )
        }
        let retired = try await repository.fetchInboxPage(
            scope: fixture.scope,
            at: fixture.date,
            freshness: FreshnessState(status: .partial, detail: "Credential changed."),
            limit: 50
        )
        XCTAssertEqual(retired.count, 1)
        let retiredItem = try XCTUnwrap(retired.first)
        XCTAssertTrue(retiredItem.relations.isEmpty)
        XCTAssertEqual(retiredItem.freshness.status, .partial)
    }

    func testRejectsRelationsForAnotherVaultAccount() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        do {
            try await WorkRelationRepository(vault: fixture.vault).replace(
                [fixture.relation],
                accountID: AccountID.make(),
                subjectNodeID: fixture.node.nodeID,
                authority: fixture.authority
            )
            XCTFail("Expected an account scope mismatch.")
        } catch {
            XCTAssertEqual(error as? WorkRelationRepositoryError, .accountScopeMismatch)
        }
    }

    func testIncrementalEmptyAndOtherSourceOrRevisionCannotDeleteEvidence() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = WorkRelationRepository(vault: fixture.vault)

        try await repository.replace(
            [fixture.relation],
            accountID: fixture.accountID,
            subjectNodeID: fixture.node.nodeID,
            authority: fixture.authority
        )
        let incremental = fixture.replacementAuthority(revision: "revision-1", mode: .incremental)
        try await repository.replace(
            [],
            accountID: fixture.accountID,
            subjectNodeID: fixture.node.nodeID,
            authority: incremental
        )
        let otherSource = fixture.replacementAuthority(
            source: .restSearch,
            revision: "revision-1",
            mode: .completeReconciliation
        )
        try await repository.replace(
            [],
            accountID: fixture.accountID,
            subjectNodeID: fixture.node.nodeID,
            authority: otherSource
        )
        let otherRevision = fixture.replacementAuthority(revision: "revision-2", mode: .completeReconciliation)
        try await repository.replace(
            [],
            accountID: fixture.accountID,
            subjectNodeID: fixture.node.nodeID,
            authority: otherRevision
        )

        let countBeforeExactReplacement = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM relation_evidence")
        }
        XCTAssertEqual(countBeforeExactReplacement, 1)

        try await repository.replace(
            [],
            accountID: fixture.accountID,
            subjectNodeID: fixture.node.nodeID,
            authority: fixture.authority
        )
        let countAfterExactReplacement = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM relations")
        }
        XCTAssertEqual(countAfterExactReplacement, 0)
    }

    func testRejectsRawSnapshotAndObjectNodeOutsideExactAuthorityWithoutMutating() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = WorkRelationRepository(vault: fixture.vault)
        let wrongSnapshotAuthority = RelationReplacementAuthority(
            source: fixture.authority.source,
            locator: fixture.authority.locator,
            scope: fixture.scope,
            feature: fixture.authority.feature,
            streamID: fixture.authority.streamID,
            repositoryID: nil,
            sourceRevision: fixture.authority.sourceRevision,
            rawSnapshotID: RawAPISnapshotID.make(),
            observedAt: fixture.date,
            mode: .completeReconciliation
        )
        do {
            try await repository.replace(
                [fixture.makeRelation(for: wrongSnapshotAuthority)],
                accountID: fixture.accountID,
                subjectNodeID: fixture.node.nodeID,
                authority: wrongSnapshotAuthority
            )
            XCTFail("Expected raw snapshot scope validation.")
        } catch {
            XCTAssertEqual(error as? WorkRelationRepositoryError, .rawSnapshotScopeMismatch)
        }
        let count = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM relations")
        }
        XCTAssertEqual(count, 0)
    }

    func testExactIncrementalEvidenceReplayIsIdempotent() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let authority = fixture.replacementAuthority(revision: "revision-1", mode: .incremental)
        let relation = fixture.makeRelation(for: authority)
        let repository = WorkRelationRepository(vault: fixture.vault)
        try await repository.replace(
            [relation],
            accountID: fixture.accountID,
            subjectNodeID: fixture.node.nodeID,
            authority: authority
        )
        try await repository.replace(
            [relation],
            accountID: fixture.accountID,
            subjectNodeID: fixture.node.nodeID,
            authority: authority
        )
        let count = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM relation_evidence")
        }
        XCTAssertEqual(count, 1)
    }

    func testWorkItemDecodingRejectsCorruptRelationEvidenceAuthority() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await WorkItemRepository(vault: fixture.vault).ensureWorkItem(for: fixture.node)
        try await WorkRelationRepository(vault: fixture.vault).replace(
            [fixture.relation],
            accountID: fixture.accountID,
            subjectNodeID: fixture.node.nodeID,
            authority: fixture.authority
        )
        try await fixture.vault.write { database in
            try database.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try database.execute(
                sql: "UPDATE relation_evidence SET authority_kind = 'legacyUnverified'"
            )
            try database.execute(sql: "PRAGMA ignore_check_constraints = OFF")
        }
        do {
            _ = try await WorkItemRepository(vault: fixture.vault).fetch(
                accountID: fixture.accountID,
                organizationID: fixture.organizationID
            )
            XCTFail("Expected corrupt evidence to fail closed.")
        } catch {
            XCTAssertEqual(error as? WorkItemRepositoryError, .invalidPersistedData)
        }
    }

    func testObjectScopeAcceptsSelectedAccountGlobalActorAndSameOrganizationTeam() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let actorNodeID = GitHubNodeID(rawValue: "MDQ6VXNlcjI=")!
        let teamNodeID = GitHubNodeID(rawValue: "MDQ6VGVhbTE=")!
        try await fixture.vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO actors (
                        id, github_node_id, github_actor_id, login, display_name,
                        avatar_url, kind, updated_at_ms
                    ) VALUES ('actor-2', ?, '2', 'hubot', NULL, NULL, 'user', ?)
                    """,
                arguments: [actorNodeID.rawValue, 100_000]
            )
            try database.execute(
                sql: """
                    INSERT INTO teams (
                        id, organization_id, github_node_id, slug, name, privacy, updated_at_ms
                    ) VALUES ('team-1', ?, ?, 'platform', 'Platform', 'closed', ?)
                    """,
                arguments: [fixture.organizationID.rawValue, teamNodeID.rawValue, 100_000]
            )
        }
        let relations = [
            fixture.makeRelation(
                for: fixture.authority,
                objectNodeID: fixture.accountNodeID,
                kind: .authored,
                evidenceID: "account-object"
            ),
            fixture.makeRelation(
                for: fixture.authority,
                objectNodeID: actorNodeID,
                kind: .assigned,
                evidenceID: "actor-object"
            ),
            fixture.makeRelation(
                for: fixture.authority,
                objectNodeID: teamNodeID,
                kind: .teamMentioned,
                evidenceID: "team-object"
            )
        ]

        try await WorkRelationRepository(vault: fixture.vault).replace(
            relations,
            accountID: fixture.accountID,
            subjectNodeID: fixture.node.nodeID,
            authority: fixture.authority
        )

        let count = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM relations")
        }
        XCTAssertEqual(count, 3)
    }

    func testObjectScopeRejectsCrossOrganizationContentAndTeamWithoutMutation() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let otherOrganizationID = OrganizationID(rawValue: "other")!
        let otherOrganization = GitHubOrganization(
            id: otherOrganizationID,
            githubOrganizationID: 3,
            nodeID: GitHubNodeID(rawValue: "MDEyOk9yZ2FuaXphdGlvbjI=")!,
            login: "other"
        )
        try await AccountRepository(vault: fixture.vault).save(
            otherOrganization,
            access: OrganizationAccess(
                accountID: fixture.accountID,
                organizationID: otherOrganizationID,
                state: .available,
                capabilityRevision: CapabilityRevision(rawValue: "other-capability")!,
                capabilities: [],
                checkedAt: fixture.date
            ),
            selectedAt: nil
        )
        let otherContentNodeID = GitHubNodeID(rawValue: "MDU6SXNzdWUy")!
        try await GitHubNodeRepository(vault: fixture.vault).save(
            NormalizedGitHubNode(
                nodeID: otherContentNodeID,
                accountID: fixture.accountID,
                organizationID: otherOrganizationID,
                repositoryID: nil,
                kind: .issue,
                numericID: "2",
                number: 2,
                title: "Other organization",
                state: .open,
                url: URL(string: "https://github.com/other/repo/issues/2")!,
                bodyMarkdown: nil,
                authorID: nil,
                createdAt: fixture.date,
                updatedAt: fixture.date,
                closedAt: nil,
                mergedAt: nil,
                sourceRevision: "other-revision",
                observedAt: fixture.date,
                accessibility: .accessible
            )
        )
        let otherTeamNodeID = GitHubNodeID(rawValue: "MDQ6VGVhbTI=")!
        try await fixture.vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO teams (
                        id, organization_id, github_node_id, slug, name, privacy, updated_at_ms
                    ) VALUES ('other-team', ?, ?, 'other', 'Other', 'closed', ?)
                    """,
                arguments: [otherOrganizationID.rawValue, otherTeamNodeID.rawValue, 100_000]
            )
        }
        let repository = WorkRelationRepository(vault: fixture.vault)
        for (nodeID, evidenceID) in [
            (otherContentNodeID, "cross-org-content"),
            (otherTeamNodeID, "cross-org-team")
        ] {
            do {
                try await repository.replace(
                    [fixture.makeRelation(
                        for: fixture.authority,
                        objectNodeID: nodeID,
                        kind: .assigned,
                        evidenceID: evidenceID
                    )],
                    accountID: fixture.accountID,
                    subjectNodeID: fixture.node.nodeID,
                    authority: fixture.authority
                )
                XCTFail("Expected cross-organization object rejection.")
            } catch {
                XCTAssertEqual(error as? WorkRelationRepositoryError, .objectNodeScopeMismatch)
            }
        }
        let count = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM relations")
        }
        XCTAssertEqual(count, 0)
    }

    func testHydratedNodeDetailsPersistIssueAndPullRequestFields() async throws {
            let fixture = try await Fixture()
            defer { fixture.remove() }

            let repository = GitHubNodeDetailsRepository(vault: fixture.vault)
            try await repository.save(
                HydratedGitHubNode(
                    node: fixture.node,
                    details: .issue(
                        isLocked: true,
                        commentsCount: 3,
                        assigneeNodeIDs: [GitHubNodeID(rawValue: "MDQ6VXNlcjE=")!],
                        labelNodeIDs: [GitHubNodeID(rawValue: "MDU6TGFiZWwx")!],
                        labelNames: ["bug"]
                    )
                ),
                accountID: fixture.accountID,
                observedAt: fixture.date
            )

            let pullRequest = NormalizedGitHubNode(
                nodeID: GitHubNodeID(rawValue: "MDExOlB1bGxSZXF1ZXN0MQ==")!,
                accountID: fixture.accountID,
                organizationID: fixture.organizationID,
                repositoryID: nil,
                kind: .pullRequest,
                numericID: "2",
                number: 2,
                title: "Add review details",
                state: .open,
                url: URL(string: "https://github.com/github/triage/pull/2")!,
                bodyMarkdown: nil,
                authorID: nil,
                createdAt: fixture.date,
                updatedAt: fixture.date,
                closedAt: nil,
                mergedAt: nil,
                sourceRevision: "revision-2",
                observedAt: fixture.date,
                accessibility: .accessible
            )
            try await repository.save(
                HydratedGitHubNode(
                    node: pullRequest,
                    details: .pullRequest(
                        isDraft: false,
                        mergeableState: "MERGEABLE",
                        headRef: "feature",
                        baseRef: "main",
                        reviewDecision: "APPROVED",
                        assigneeNodeIDs: [],
                        labelNodeIDs: [],
                        labelNames: ["documentation"]
                    )
                ),
                accountID: fixture.accountID,
                observedAt: fixture.date
            )

            let issue = try await fixture.vault.read { database -> (Int?, Int?, Data?, Data?) in
                let row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT locked, comments_count, assignee_node_ids_json, label_names_json
                        FROM issues
                        WHERE github_node_id = ?
                    """,
                    arguments: [fixture.node.nodeID.rawValue]
                )
                let locked: Int? = row?["locked"]
                let commentsCount: Int? = row?["comments_count"]
                let assigneeNodeIDs: Data? = row?["assignee_node_ids_json"]
                let labelNames: Data? = row?["label_names_json"]
                return (locked, commentsCount, assigneeNodeIDs, labelNames)
            }
            XCTAssertEqual(issue.0, 1)
            XCTAssertEqual(issue.1, 3)
            XCTAssertEqual(
                try JSONDecoder().decode([String].self, from: try XCTUnwrap(issue.2)),
                ["MDQ6VXNlcjE="]
            )
            XCTAssertEqual(
                try JSONDecoder().decode([String].self, from: try XCTUnwrap(issue.3)),
                ["bug"]
            )
            let pullRequestRow = try await fixture.vault.read { database -> (String?, String?, String?, String?, Data?) in
                let row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT mergeable_state, head_ref, base_ref, review_decision, label_names_json
                        FROM pull_requests
                        WHERE github_node_id = ?
                    """,
                    arguments: [pullRequest.nodeID.rawValue]
                )
                let mergeableState: String? = row?["mergeable_state"]
                let headRef: String? = row?["head_ref"]
                let baseRef: String? = row?["base_ref"]
                let reviewDecision: String? = row?["review_decision"]
                let labelNames: Data? = row?["label_names_json"]
                return (mergeableState, headRef, baseRef, reviewDecision, labelNames)
            }
            XCTAssertEqual(pullRequestRow.0, "MERGEABLE")
            XCTAssertEqual(pullRequestRow.1, "feature")
            XCTAssertEqual(pullRequestRow.2, "main")
            XCTAssertEqual(pullRequestRow.3, "APPROVED")
            XCTAssertEqual(
                try JSONDecoder().decode([String].self, from: try XCTUnwrap(pullRequestRow.4)),
                ["documentation"]
            )
    }

    func testRejectsRelationsForANodeOutsideTheVaultAccount() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        do {
            try await WorkRelationRepository(vault: fixture.vault).replace(
                [],
                accountID: fixture.accountID,
                subjectNodeID: GitHubNodeID(rawValue: "MDU6SXNzdWU5OTk=")!,
                authority: fixture.authority
            )
            XCTFail("Expected a source node scope mismatch.")
        } catch {
            XCTAssertEqual(error as? WorkRelationRepositoryError, .subjectNodeScopeMismatch)
        }
    }

    func testRawAPISnapshotsRoundTripWithinTheirAccountScope() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let snapshot = RawAPISnapshot(
            id: RawAPISnapshotID.make(),
            accountID: fixture.accountID,
            githubNodeID: fixture.node.nodeID,
            endpoint: "/repos/github/triage/issues/1",
            eTag: "\"revision-1\"",
            parserVersion: 1,
            observedAt: fixture.date,
            payload: Data("{\"number\":1}".utf8)
        )
        let repository = RawAPISnapshotRepository(vault: fixture.vault)
        try await repository.save(snapshot)

        let snapshots = try await repository.snapshots(for: fixture.accountID)
        XCTAssertTrue(snapshots.contains(snapshot))
        XCTAssertTrue(snapshots.contains { $0.id == fixture.rawSnapshotID })

        do {
            try await repository.save(
                RawAPISnapshot(
                    id: RawAPISnapshotID.make(),
                    accountID: AccountID.make(),
                    githubNodeID: fixture.node.nodeID,
                    endpoint: snapshot.endpoint,
                    eTag: nil,
                    parserVersion: 1,
                    observedAt: fixture.date,
                    payload: snapshot.payload
                )
            )
            XCTFail("Expected an account scope mismatch.")
        } catch {
            XCTAssertEqual(error as? RawAPISnapshotRepositoryError, .accountScopeMismatch)
        }
    }

    func testRawAPISnapshotCompactionPreservesReplayAndFailureProvenance() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let repository = RawAPISnapshotRepository(vault: fixture.vault)
        let endpoint = "/repos/github/triage/issues/1"
        let oldest = RawAPISnapshot(
            id: RawAPISnapshotID.make(),
            accountID: fixture.accountID,
            githubNodeID: fixture.node.nodeID,
            endpoint: endpoint,
            eTag: "\"revision-1\"",
            parserVersion: 1,
            observedAt: fixture.date,
            payload: Data("{\"revision\":1}".utf8)
        )
        let failedSnapshot = RawAPISnapshot(
            id: RawAPISnapshotID.make(),
            accountID: fixture.accountID,
            githubNodeID: fixture.node.nodeID,
            endpoint: endpoint,
            eTag: "\"revision-2\"",
            parserVersion: 1,
            observedAt: fixture.date.addingTimeInterval(60),
            payload: Data("{\"revision\":2}".utf8)
        )
        let newest = RawAPISnapshot(
            id: RawAPISnapshotID.make(),
            accountID: fixture.accountID,
            githubNodeID: fixture.node.nodeID,
            endpoint: endpoint,
            eTag: "\"revision-3\"",
            parserVersion: 1,
            observedAt: fixture.date.addingTimeInterval(120),
            payload: Data("{\"revision\":3}".utf8)
        )
        for snapshot in [oldest, failedSnapshot, newest] {
            try await repository.save(snapshot)
        }
        try await NormalizationFailureRepository(vault: fixture.vault).record(
            NormalizationFailure(
                id: UUID(),
                accountID: fixture.accountID,
                rawSnapshotID: failedSnapshot.id,
                githubNodeID: fixture.node.nodeID,
                endpoint: endpoint,
                parserVersion: 1,
                occurredAt: failedSnapshot.observedAt,
                redactedDiagnostic: "Unknown issue state."
            )
        )

        let compactedCount = try await repository.compact(
            accountID: fixture.accountID,
            before: fixture.date.addingTimeInterval(180)
        )
        XCTAssertEqual(compactedCount, 1)
        let snapshots = try await repository.snapshots(for: fixture.accountID)
        XCTAssertTrue(snapshots.contains(newest))
        XCTAssertTrue(snapshots.contains(failedSnapshot))
        XCTAssertTrue(snapshots.contains { $0.id == fixture.rawSnapshotID })
        XCTAssertEqual(snapshots.count, 3)
    }

    func testNormalizationFailuresRetainAccountScopedSnapshotProvenance() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let snapshot = RawAPISnapshot(
            id: RawAPISnapshotID.make(),
            accountID: fixture.accountID,
            githubNodeID: fixture.node.nodeID,
            endpoint: "/repos/github/triage/issues/1",
            eTag: nil,
            parserVersion: 1,
            observedAt: fixture.date,
            payload: Data("{\"number\":1}".utf8)
        )
        try await RawAPISnapshotRepository(vault: fixture.vault).save(snapshot)
        let failure = NormalizationFailure(
            id: UUID(),
            accountID: fixture.accountID,
            rawSnapshotID: snapshot.id,
            githubNodeID: fixture.node.nodeID,
            endpoint: snapshot.endpoint,
            parserVersion: snapshot.parserVersion,
            occurredAt: fixture.date,
            redactedDiagnostic: "Unknown issue state."
        )
        let repository = NormalizationFailureRepository(vault: fixture.vault)
        try await repository.record(failure)

        let failures = try await repository.failures(for: fixture.accountID)
        XCTAssertEqual(failures, [failure])

        do {
            try await repository.record(
                NormalizationFailure(
                    id: UUID(),
                    accountID: fixture.accountID,
                    rawSnapshotID: RawAPISnapshotID.make(),
                    githubNodeID: fixture.node.nodeID,
                    endpoint: failure.endpoint,
                    parserVersion: failure.parserVersion,
                    occurredAt: failure.occurredAt,
                    redactedDiagnostic: failure.redactedDiagnostic
                )
            )
            XCTFail("Expected a snapshot scope mismatch.")
        } catch {
            XCTAssertEqual(error as? NormalizationFailureRepositoryError, .snapshotScopeMismatch)
        }
    }

    func testConditionalRequestValidatorsRoundTripOnlyForExactCurrentAuthorityScope() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let streamID = SyncStreamID(rawValue: "timeline-github-repo-1")!
        let scope = SynchronizationScope(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: CredentialRevision(rawValue: "credential-1")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-1")!
        )
        try await CoverageRepository(vault: fixture.vault).save(
            CoverageRecord(
                accountID: scope.accountID,
                organizationID: scope.organizationID,
                repositoryID: nil,
                feature: .timelines,
                streamID: streamID,
                intervalStart: nil,
                intervalEnd: nil,
                credentialRevision: scope.credentialRevision,
                capabilityRevision: scope.capabilityRevision,
                status: .partial,
                lastSuccessfulAt: nil,
                failureDetail: nil
            ),
            attemptedAt: fixture.date
        )
        let identity = ConditionalRequestIdentity(
            scope: scope,
            feature: .timelines,
            streamID: streamID,
            requestKey: "GET /repos/github/triage/issues/1/timeline?per_page=100&page=1"
        )
        let validator = ConditionalRequestValidator(
            identity: identity,
            eTag: "\"revision-1\"",
            lastModified: "Fri, 28 Aug 2026 00:00:00 GMT",
            observedAt: fixture.date
        )
        let repository = ConditionalRequestCacheRepository(vault: fixture.vault)
        try await repository.save(validator)
        let restoredValidator = try await repository.validator(for: identity)
        XCTAssertEqual(restoredValidator, validator)
        let differentRequest = ConditionalRequestIdentity(
            scope: scope,
            feature: identity.feature,
            streamID: identity.streamID,
            requestKey: identity.requestKey + "&page=2"
        )
        let differentRequestValidator = try await repository.validator(for: differentRequest)
        XCTAssertNil(differentRequestValidator)
        try await repository.remove(for: differentRequest)
        let retainedValidator = try await repository.validator(for: identity)
        XCTAssertEqual(retainedValidator, validator)

        do {
            _ = try await repository.validator(for: ConditionalRequestIdentity(
                scope: SynchronizationScope(
                    accountID: AccountID.make(),
                    organizationID: scope.organizationID,
                    credentialRevision: scope.credentialRevision,
                    capabilityRevision: scope.capabilityRevision
                ),
                feature: identity.feature,
                streamID: identity.streamID,
                requestKey: identity.requestKey
            ))
            XCTFail("Expected an account scope mismatch.")
        } catch {
            XCTAssertEqual(error as? ConditionalRequestCacheRepositoryError, .accountScopeMismatch)
        }

        do {
            _ = try await repository.validator(for: ConditionalRequestIdentity(
                scope: SynchronizationScope(
                    accountID: scope.accountID,
                    organizationID: scope.organizationID,
                    credentialRevision: CredentialRevision(rawValue: "credential-2")!,
                    capabilityRevision: scope.capabilityRevision
                ),
                feature: identity.feature,
                streamID: identity.streamID,
                requestKey: identity.requestKey
            ))
            XCTFail("Expected a credential authority mismatch.")
        } catch {
            XCTAssertEqual(error as? ConditionalRequestCacheRepositoryError, .authorityScopeMismatch)
        }

        do {
            try await repository.save(
                ConditionalRequestValidator(
                    identity: ConditionalRequestIdentity(
                        scope: scope,
                        feature: .reviews,
                        streamID: streamID,
                        requestKey: identity.requestKey
                    ),
                    eTag: "\"foreign-stream\"",
                    lastModified: nil,
                    observedAt: fixture.date
                )
            )
            XCTFail("Expected a stream scope mismatch.")
        } catch {
            XCTAssertEqual(error as? ConditionalRequestCacheRepositoryError, .streamScopeMismatch)
        }

        do {
            _ = try await repository.validator(for: ConditionalRequestIdentity(
                scope: scope,
                feature: .reviews,
                streamID: streamID,
                requestKey: identity.requestKey
            ))
            XCTFail("Expected a stream scope mismatch on lookup.")
        } catch {
            XCTAssertEqual(error as? ConditionalRequestCacheRepositoryError, .streamScopeMismatch)
        }

        do {
            _ = try await repository.validator(for: ConditionalRequestIdentity(
                scope: scope,
                feature: identity.feature,
                streamID: streamID,
                requestKey: identity.requestKey + "\nInjected: true"
            ))
            XCTFail("Expected a control-character request key rejection.")
        } catch {
            XCTAssertEqual(error as? ConditionalRequestCacheRepositoryError, .invalidRequestKey)
        }

        do {
            try await repository.save(
                ConditionalRequestValidator(
                    identity: identity,
                    eTag: "invalid\u{001f}validator",
                    lastModified: nil,
                    observedAt: fixture.date
                )
            )
            XCTFail("Expected a control-character validator rejection.")
        } catch {
            XCTAssertEqual(error as? ConditionalRequestCacheRepositoryError, .invalidValidator)
        }

        try await fixture.vault.write { database in
            try database.execute(
                sql: """
                    UPDATE account_organizations
                    SET capability_revision = 'capability-2'
                    WHERE account_id = ? AND organization_id = ?
                    """,
                arguments: [scope.accountID.rawValue, scope.organizationID.rawValue]
            )
        }
        do {
            _ = try await repository.validator(for: identity)
            XCTFail("Expected a capability authority mismatch.")
        } catch {
            XCTAssertEqual(error as? ConditionalRequestCacheRepositoryError, .authorityScopeMismatch)
        }
        let currentCapabilityIdentity = ConditionalRequestIdentity(
            scope: SynchronizationScope(
                accountID: scope.accountID,
                organizationID: scope.organizationID,
                credentialRevision: scope.credentialRevision,
                capabilityRevision: CapabilityRevision(rawValue: "capability-2")!
            ),
            feature: identity.feature,
            streamID: identity.streamID,
            requestKey: identity.requestKey
        )
        let currentCapabilityValidator = try await repository.validator(for: currentCapabilityIdentity)
        XCTAssertNil(currentCapabilityValidator)
    }

    func testSyncShardsRequireAnAccountOwnedParentStream() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let streamID = SyncStreamID(rawValue: "search-discovery")!
        try await CoverageRepository(vault: fixture.vault).save(
            CoverageRecord(
                accountID: fixture.accountID,
                organizationID: fixture.organizationID,
                repositoryID: nil,
                feature: .issues,
                streamID: streamID,
                intervalStart: fixture.date,
                intervalEnd: fixture.date.addingTimeInterval(60),
                credentialRevision: CredentialRevision(rawValue: "credential-1")!,
                capabilityRevision: CapabilityRevision(rawValue: "capability-1")!,
                status: .partial,
                lastSuccessfulAt: nil,
                failureDetail: nil
            ),
            attemptedAt: fixture.date
        )
        let shard = SyncShard(
            id: SyncShardID.make(),
            streamID: streamID,
            queryKind: "involvement-open",
            intervalStart: fixture.date,
            intervalEnd: fixture.date.addingTimeInterval(60),
            pageCursor: "page:2",
            state: .running,
            completedAt: nil
        )
        let repository = SyncShardRepository(vault: fixture.vault)
        try await repository.save(shard, accountID: fixture.accountID)
        let shards = try await repository.shards(for: streamID, accountID: fixture.accountID)
        XCTAssertEqual(shards, [shard])

        do {
            try await repository.save(shard, accountID: AccountID.make())
            XCTFail("Expected an account scope mismatch.")
        } catch {
            XCTAssertEqual(error as? SyncShardRepositoryError, .accountScopeMismatch)
        }
    }

    func testSyncShardsRejectMalformedCheckpointsAndUnknownStreams() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let streamID = SyncStreamID(rawValue: "search-discovery")!
        try await CoverageRepository(vault: fixture.vault).save(
            CoverageRecord(
                accountID: fixture.accountID,
                organizationID: fixture.organizationID,
                repositoryID: nil,
                feature: .issues,
                streamID: streamID,
                intervalStart: fixture.date,
                intervalEnd: fixture.date.addingTimeInterval(60),
                credentialRevision: CredentialRevision(rawValue: "credential-1")!,
                capabilityRevision: CapabilityRevision(rawValue: "capability-1")!,
                status: .partial,
                lastSuccessfulAt: nil,
                failureDetail: nil
            ),
            attemptedAt: fixture.date
        )
        let repository = SyncShardRepository(vault: fixture.vault)

        do {
            try await repository.save(
                SyncShard(
                    id: SyncShardID.make(),
                    streamID: streamID,
                    queryKind: "involvement-open",
                    intervalStart: fixture.date.addingTimeInterval(60),
                    intervalEnd: fixture.date,
                    pageCursor: nil,
                    state: .pending,
                    completedAt: nil
                ),
                accountID: fixture.accountID
            )
            XCTFail("Expected an invalid interval.")
        } catch {
            XCTAssertEqual(error as? SyncShardRepositoryError, .invalidInterval)
        }

        do {
            try await repository.save(
                SyncShard(
                    id: SyncShardID.make(),
                    streamID: streamID,
                    queryKind: "involvement-open",
                    intervalStart: nil,
                    intervalEnd: nil,
                    pageCursor: nil,
                    state: .running,
                    completedAt: fixture.date
                ),
                accountID: fixture.accountID
            )
            XCTFail("Expected an invalid completion state.")
        } catch {
            XCTAssertEqual(error as? SyncShardRepositoryError, .invalidCompletionState)
        }

        do {
            try await repository.save(
                SyncShard(
                    id: SyncShardID.make(),
                    streamID: SyncStreamID(rawValue: "unknown-stream")!,
                    queryKind: "involvement-open",
                    intervalStart: nil,
                    intervalEnd: nil,
                    pageCursor: nil,
                    state: .pending,
                    completedAt: nil
                ),
                accountID: fixture.accountID
            )
            XCTFail("Expected an unknown stream failure.")
        } catch {
            XCTAssertEqual(error as? SyncShardRepositoryError, .streamScopeMismatch)
        }
    }

    func testSyncStreamsReadAndUpdateAccountOwnedCoverageStream() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let streamID = SyncStreamID(rawValue: "search-discovery")!
        let coverage = CoverageRecord(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            repositoryID: nil,
            feature: .roleDiscovery,
            streamID: streamID,
            intervalStart: fixture.date,
            intervalEnd: fixture.date.addingTimeInterval(60),
            credentialRevision: CredentialRevision(rawValue: "credential-1")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-1")!,
            status: .partial,
            lastSuccessfulAt: nil,
            failureDetail: nil
        )
        try await CoverageRepository(vault: fixture.vault).save(coverage, attemptedAt: fixture.date)

        let repository = SyncStreamRepository(vault: fixture.vault)
        let initialStream = try await repository.stream(withID: streamID, accountID: fixture.accountID)
        let initial = try XCTUnwrap(initialStream)
        XCTAssertEqual(initial.status, .partial)
        XCTAssertNil(initial.highWater)
        XCTAssertEqual(initial.lastAttemptAt, fixture.date)

        let completed = SyncStream(
            id: streamID,
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            feature: .roleDiscovery,
            highWater: fixture.date.addingTimeInterval(120),
            lastSuccessfulAt: fixture.date.addingTimeInterval(120),
            lastAttemptAt: fixture.date.addingTimeInterval(120),
            status: .complete,
            failureDetail: nil
        )
        try await repository.save(completed)
        let storedStream = try await repository.stream(withID: streamID, accountID: fixture.accountID)
        XCTAssertEqual(storedStream, completed)

        do {
            _ = try await repository.stream(withID: streamID, accountID: AccountID.make())
            XCTFail("Expected an account scope mismatch.")
        } catch {
            XCTAssertEqual(error as? SyncStreamRepositoryError, .accountScopeMismatch)
        }
    }

    func testSynchronizationScopeUsesCurrentCredentialAndCapabilityRevisions() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let scope = try await AccountRepository(vault: fixture.vault).synchronizationScope(
            for: fixture.accountID,
            organizationID: fixture.organizationID
        )

        XCTAssertEqual(scope.accountID, fixture.accountID)
        XCTAssertEqual(scope.organizationID, fixture.organizationID)
        XCTAssertEqual(scope.credentialRevision, CredentialRevision(rawValue: "credential-1"))
        XCTAssertEqual(scope.capabilityRevision, CapabilityRevision(rawValue: "capability-1"))
    }

    func testPersistentNotificationLedgerEnforcesVaultAndWorkItemScope() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let workItemID = try await WorkItemRepository(vault: fixture.vault).ensureWorkItem(for: fixture.node)
        let key = NotificationDedupeKey(
            route: NotificationRoute(
                accountID: fixture.accountID,
                organizationID: fixture.organizationID,
                workItemID: workItemID
            ),
            reason: .directAssignment,
            evidenceVersion: "revision-1"
        )
        let ledger = PersistentNotificationDeliveryLedger(vault: fixture.vault)
        try await ledger.record(key)
        let containsKey = try await ledger.contains(key)
        XCTAssertTrue(containsKey)

        let crossAccountKey = NotificationDedupeKey(
            route: NotificationRoute(
                accountID: AccountID.make(),
                organizationID: fixture.organizationID,
                workItemID: workItemID
            ),
            reason: .directAssignment,
            evidenceVersion: "revision-1"
        )
        do {
            _ = try await ledger.contains(crossAccountKey)
            XCTFail("Expected an account scope mismatch.")
        } catch {
            XCTAssertEqual(error as? NotificationDeliveryLedgerError, .accountScopeMismatch)
        }
    }

    private final class Fixture: @unchecked Sendable {
        let directory: URL
        let accountID = AccountID.make()
        let organizationID = OrganizationID(rawValue: "github")!
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let vault: AccountVault
        let node: NormalizedGitHubNode
        let relation: WorkRelation
        let accountNodeID: GitHubNodeID
        let scope: SynchronizationScope
        let authority: RelationReplacementAuthority
        let rawSnapshotID: RawAPISnapshotID

        init() async throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            vault = try await VaultRegistry(rootDirectory: directory).open(
                accountID: accountID,
                vaultKey: try VaultKey.generate()
            )
            accountNodeID = GitHubNodeID(rawValue: "MDQ6VXNlcjE=")!
            let account = GitHubAccount(
                id: accountID,
                githubUserID: 1,
                nodeID: accountNodeID,
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
            let accountRepository = AccountRepository(vault: vault)
            try await accountRepository.save(
                account,
                credentialRevision: CredentialRevision(rawValue: "credential-1")!
            )
            try await accountRepository.save(organization, access: access, selectedAt: date)

            scope = SynchronizationScope(
                accountID: accountID,
                organizationID: organizationID,
                credentialRevision: CredentialRevision(rawValue: "credential-1")!,
                capabilityRevision: CapabilityRevision(rawValue: "capability-1")!
            )

            node = NormalizedGitHubNode(
                nodeID: GitHubNodeID(rawValue: "MDU6SXNzdWUx")!,
                accountID: accountID,
                organizationID: organizationID,
                repositoryID: nil,
                kind: .issue,
                numericID: "1",
                number: 1,
                title: "Fix work item projection",
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
            try await GitHubNodeRepository(vault: vault).save(node)
            let streamID = SyncStreamID(rawValue: "relations-issue-1")!
            let endpoint = "/repos/github/triage/issues/1/timeline?per_page=100&page=1"
            let rawSnapshot = RawAPISnapshot(
                id: RawAPISnapshotID.make(),
                accountID: accountID,
                githubNodeID: node.nodeID,
                endpoint: endpoint,
                eTag: "\"relations-1\"",
                parserVersion: 1,
                observedAt: date,
                payload: Data("[]".utf8),
                requestIdentity: ConditionalRequestIdentity(
                    scope: scope,
                    feature: .timelines,
                    streamID: streamID,
                    requestKey: "GET \(endpoint)"
                )
            )
            rawSnapshotID = rawSnapshot.id
            try await RawAPISnapshotRepository(vault: vault).save(rawSnapshot)
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
            authority = RelationReplacementAuthority(
                source: .restTimeline,
                locator: .endpoint(endpoint),
                scope: scope,
                feature: .timelines,
                streamID: streamID,
                repositoryID: nil,
                sourceRevision: "revision-1",
                rawSnapshotID: rawSnapshot.id,
                observedAt: date,
                mode: .completeReconciliation
            )
            relation = WorkRelation(
                kind: .assigned,
                subjectNodeID: node.nodeID,
                objectNodeID: accountNodeID,
                confidence: .confirmed,
                evidence: [
                    EvidenceReference(
                        id: EvidenceID(rawValue: "assignment-1")!,
                        source: .restTimeline,
                        locator: .endpoint(endpoint),
                        authority: .github(
                            scope: scope,
                            feature: .timelines,
                            streamID: streamID
                        ),
                        nodeID: node.nodeID,
                        sourceRevision: node.sourceRevision,
                        rawSnapshotID: rawSnapshot.id,
                        confidence: .confirmed,
                        confirmation: .confirmed,
                        observedAt: date,
                        excerpt: "assignee:octocat"
                    )
                ],
                observedAt: date
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }

        func replacementAuthority(
            source: EvidenceSource = .restTimeline,
            revision: String,
            mode: RelationReplacementMode
        ) -> RelationReplacementAuthority {
            RelationReplacementAuthority(
                source: source,
                locator: authority.locator,
                scope: scope,
                feature: authority.feature,
                streamID: authority.streamID,
                repositoryID: authority.repositoryID,
                sourceRevision: revision,
                rawSnapshotID: rawSnapshotID,
                observedAt: date,
                mode: mode
            )
        }

        func makeRelation(
            for authority: RelationReplacementAuthority,
            objectNodeID: GitHubNodeID? = nil,
            kind: WorkRelationKind? = nil,
            evidenceID: String? = nil
        ) -> WorkRelation {
            WorkRelation(
                kind: kind ?? relation.kind,
                subjectNodeID: relation.subjectNodeID,
                objectNodeID: objectNodeID ?? relation.objectNodeID,
                confidence: relation.confidence,
                evidence: [
                    EvidenceReference(
                        id: evidenceID.flatMap(EvidenceID.init(rawValue:)) ?? relation.evidence[0].id,
                        source: authority.source,
                        locator: authority.locator,
                        authority: .github(
                            scope: authority.scope,
                            feature: authority.feature,
                            streamID: authority.streamID
                        ),
                        nodeID: relation.subjectNodeID,
                        sourceRevision: authority.sourceRevision,
                        rawSnapshotID: authority.rawSnapshotID,
                        confidence: authority.mode == .completeReconciliation ? .confirmed : .provisional,
                        confirmation: authority.mode == .completeReconciliation ? .confirmed : .provisional,
                        observedAt: authority.observedAt,
                        excerpt: relation.evidence[0].excerpt
                    )
                ],
                observedAt: relation.observedAt
            )
        }
    }
}
