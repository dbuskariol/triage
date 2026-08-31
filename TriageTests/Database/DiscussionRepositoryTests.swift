import Foundation
import GRDB
import XCTest
@testable import Triage

final class DiscussionRepositoryTests: XCTestCase {
    func testInvalidReplacementPreservesPriorDiscussionAndRawSnapshotsAreStored() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let repository = DiscussionRepository(vault: fixture.vault)
        let valid = fixture.discussion(id: "D_1", title: "Retained")
        let raw = GitHubDiscussionRawPage(
            endpoint: "graphql:TriageRepositoryDiscussions/repository=R_1/page=1",
            requestKey: "graphql:TriageRepositoryDiscussions/repository=R_1/after=none",
            payload: discussionRawPayload()
        )
        try await repository.replace(
            [valid], rawPages: [raw], scope: fixture.scope, accountID: fixture.account.id,
            organization: fixture.organization, repositoryID: fixture.repositoryID,
            repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
            streamID: SyncStreamID(rawValue: "discussions-acme-R_1")!, observedAt: fixture.date
        )

        let invalid = fixture.discussion(id: "D_2", title: "")
        await XCTAssertThrowsErrorAsync {
            try await repository.replace(
                [invalid], rawPages: [raw], scope: fixture.scope, accountID: fixture.account.id,
                organization: fixture.organization, repositoryID: fixture.repositoryID,
                repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
                streamID: SyncStreamID(rawValue: "discussions-acme-R_1")!, observedAt: fixture.date
            )
        }
        let persisted = try await fixture.vault.read { database in
            (
                try String.fetchAll(database, sql: "SELECT title FROM github_nodes WHERE kind = 'discussion'"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")
            )
        }
        XCTAssertEqual(persisted.0, ["Retained"])
        XCTAssertEqual(persisted.1, 1)
    }

    func testIncompleteProjectFieldValuesRetainLastCompleteValues() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let repository = ProjectV2Repository(vault: fixture.vault)
        let project = fixture.project()
        let raw = GitHubProjectV2RawPage(
            endpoint: "graphql:TriageOrganizationProjectsV2/organization=O_2/page=1",
            requestKey: "graphql:TriageOrganizationProjectsV2/organization=O_2/after=none",
            payload: projectInventoryRawPayload()
        )
        try await repository.replaceProjects(
            [project], rawPages: [raw], scope: fixture.scope, accountID: fixture.account.id,
            organization: fixture.organization, streamID: SyncStreamID(rawValue: "projects-acme")!, observedAt: fixture.date
        )
        let complete = fixture.projectItem(project: project, displayValue: "Ready", complete: true)
        let itemRaw = GitHubProjectV2RawPage(
            endpoint: "graphql:TriageProjectV2Items/project=P_1/page=1",
            requestKey: "graphql:TriageProjectV2Items/project=P_1/after=none",
            payload: projectItemsRawPayload()
        )
        let fieldRaw = GitHubProjectV2RawPage(
            endpoint: "graphql:TriageProjectV2ItemFieldValues/item=PVTI_1/page=1",
            requestKey: "graphql:TriageProjectV2ItemFieldValues/item=PVTI_1/after=none",
            payload: projectFieldRawPayload()
        )
        try await repository.replaceItems(
            [complete], project: project, rawPages: [itemRaw, fieldRaw], scope: fixture.scope, accountID: fixture.account.id,
            organization: fixture.organization, streamID: SyncStreamID(rawValue: "project-items-P_1")!, observedAt: fixture.date
        )
        let incomplete = fixture.projectItem(project: project, displayValue: nil, complete: false)
        try await repository.replaceItems(
            [incomplete], project: project, rawPages: [itemRaw, fieldRaw], scope: fixture.scope, accountID: fixture.account.id,
            organization: fixture.organization, streamID: SyncStreamID(rawValue: "project-items-P_1")!, observedAt: fixture.date
        )

        let values = try await fixture.vault.read { database in
            let row = try Row.fetchOne(
                database,
                sql: "SELECT display_value, context FROM project_field_values"
            )
            return (
                row?["display_value"] as String?,
                (row?["context"] as String?) ?? ""
            )
        }
        XCTAssertEqual(values.0, "Ready")
        XCTAssertTrue(values.1.contains("provisional collection observation"))
        XCTAssertTrue(values.1.contains("unsupported union"))
    }

    func testCompleteProjectReplacementRejectsAnEmptyRawTraversal() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let repository = ProjectV2Repository(vault: fixture.vault)
        let coverage = fixture.coverage(
            accountID: fixture.account.id,
            feature: .projects,
            stream: "projects-acme",
            status: .complete
        )

        await XCTAssertThrowsErrorAsync {
            try await repository.replaceProjects(
                [fixture.project()],
                rawPages: [],
                scope: fixture.scope,
                accountID: fixture.account.id,
                organization: fixture.organization,
                streamID: SyncStreamID(rawValue: "projects-acme")!,
                observedAt: fixture.date,
                coverageRecords: [coverage]
            )
        } verify: { error in
            XCTAssertEqual(error as? ProjectV2RepositoryError, .invalidRawAuthority)
        }

        let count = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM projects")!
        }
        XCTAssertEqual(count, 0)
    }

    func testCompleteProjectReplacementRejectsRawMembershipTampering() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let repository = ProjectV2Repository(vault: fixture.vault)
        let fabricated = GitHubProjectV2Record(
            nodeID: GitHubNodeID(rawValue: "P_fabricated")!,
            number: 99,
            title: "Fabricated",
            description: nil,
            url: URL(string: "https://github.com/orgs/acme/projects/99")!,
            updatedAt: fixture.date,
            state: .open
        )
        let coverage = CoverageRecord(
            accountID: fixture.account.id,
            organizationID: fixture.organization.id,
            repositoryID: nil,
            feature: .projects,
            streamID: SyncStreamID(rawValue: "projects-acme")!,
            intervalStart: fixture.date,
            intervalEnd: fixture.date,
            credentialRevision: fixture.scope.credentialRevision,
            capabilityRevision: fixture.scope.capabilityRevision,
            status: .complete,
            lastSuccessfulAt: fixture.date,
            failureDetail: nil
        )

        await XCTAssertThrowsErrorAsync {
            try await repository.replaceProjects(
                [fabricated],
                rawPages: [.init(
                    endpoint: "graphql:TriageOrganizationProjectsV2/organization=O_2/page=1",
                    requestKey: "graphql:TriageOrganizationProjectsV2/organization=O_2/after=none",
                    payload: projectInventoryRawPayload(nodeIDs: ["P_1"])
                )],
                scope: fixture.scope,
                accountID: fixture.account.id,
                organization: fixture.organization,
                streamID: SyncStreamID(rawValue: "projects-acme")!,
                observedAt: fixture.date,
                coverageRecords: [coverage]
            )
        } verify: { error in
            XCTAssertEqual(error as? ProjectV2RepositoryError, .invalidRawAuthority)
        }

        let counts = try await fixture.vault.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM projects")!,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")!,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM coverage_records")!
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 0)
    }

    func testCompleteProjectItemReplacementRejectsRawMembershipTampering() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let repository = ProjectV2Repository(vault: fixture.vault)
        let project = fixture.project()
        try await repository.replaceProjects(
            [project],
            rawPages: [],
            scope: fixture.scope,
            accountID: fixture.account.id,
            organization: fixture.organization,
            streamID: SyncStreamID(rawValue: "projects-acme")!,
            observedAt: fixture.date
        )
        let fabricatedItemID = GitHubNodeID(rawValue: "PVTI_fabricated")!
        let fabricated = GitHubProjectV2ItemRecord(
            nodeID: fabricatedItemID,
            projectNodeID: project.nodeID,
            contentNodeID: nil,
            contentKind: nil,
            updatedAt: fixture.date,
            fieldValues: [],
            fieldValuesComplete: true
        )
        let coverage = CoverageRecord(
            accountID: fixture.account.id,
            organizationID: fixture.organization.id,
            repositoryID: nil,
            feature: .projectItems,
            streamID: SyncStreamID(rawValue: "project-items-P_1")!,
            intervalStart: fixture.date,
            intervalEnd: fixture.date,
            credentialRevision: fixture.scope.credentialRevision,
            capabilityRevision: fixture.scope.capabilityRevision,
            status: .complete,
            lastSuccessfulAt: fixture.date,
            failureDetail: nil
        )

        await XCTAssertThrowsErrorAsync {
            try await repository.replaceItems(
                [fabricated],
                project: project,
                rawPages: [
                    .init(
                        endpoint: "graphql:TriageProjectV2Items/project=P_1/page=1",
                        requestKey: "graphql:TriageProjectV2Items/project=P_1/after=none",
                        payload: projectItemsRawPayload(nodeIDs: ["PVTI_1"])
                    ),
                    .init(
                        endpoint: "graphql:TriageProjectV2ItemFieldValues/item=PVTI_fabricated/page=1",
                        requestKey: "graphql:TriageProjectV2ItemFieldValues/item=PVTI_fabricated/after=none",
                        payload: projectFieldRawPayload(itemNodeID: fabricatedItemID.rawValue)
                    )
                ],
                scope: fixture.scope,
                accountID: fixture.account.id,
                organization: fixture.organization,
                streamID: SyncStreamID(rawValue: "project-items-P_1")!,
                observedAt: fixture.date,
                coverageRecords: [coverage]
            )
        } verify: { error in
            XCTAssertEqual(error as? ProjectV2RepositoryError, .invalidRawAuthority)
        }

        let counts = try await fixture.vault.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM project_items")!,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")!,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM coverage_records WHERE feature = 'projectItems'")!
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 0)
    }

    func testCompleteDiscussionReplacementRejectsAnEmptyRawTraversalAndPreservesPriorContentAndCoverage() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let repository = DiscussionRepository(vault: fixture.vault)
        let streamID = SyncStreamID(rawValue: "discussions-acme-R_1")!
        let coverage = fixture.coverage(
            accountID: fixture.account.id,
            feature: .discussions,
            stream: streamID.rawValue,
            status: .complete
        )
        try await repository.replace(
            [fixture.discussion(id: "D_1", title: "Retained")],
            rawPages: [.init(
                endpoint: "graphql:TriageRepositoryDiscussions/repository=R_1/page=1",
                requestKey: "graphql:TriageRepositoryDiscussions/repository=R_1/after=none",
                payload: discussionRawPayload()
            )],
            scope: fixture.scope,
            accountID: fixture.account.id,
            organization: fixture.organization,
            repositoryID: fixture.repositoryID,
            repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
            streamID: streamID,
            observedAt: fixture.date,
            coverageRecords: [coverage]
        )
        let before = try await fixture.vault.read { database in
            (
                try String.fetchAll(database, sql: "SELECT title FROM github_nodes WHERE kind = 'discussion'"),
                try String.fetchAll(database, sql: "SELECT status FROM coverage_records"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")!
            )
        }

        await XCTAssertThrowsErrorAsync {
            try await repository.replace(
                [],
                rawPages: [],
                scope: fixture.scope,
                accountID: fixture.account.id,
                organization: fixture.organization,
                repositoryID: fixture.repositoryID,
                repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
                streamID: streamID,
                observedAt: fixture.date.addingTimeInterval(60),
                coverageRecords: [fixture.coverage(
                    accountID: fixture.account.id,
                    feature: .discussions,
                    stream: streamID.rawValue,
                    status: .partial
                )]
            )
        } verify: { error in
            XCTAssertEqual(error as? DiscussionRepositoryError, .invalidRawAuthority)
        }

        let after = try await fixture.vault.read { database in
            (
                try String.fetchAll(database, sql: "SELECT title FROM github_nodes WHERE kind = 'discussion'"),
                try String.fetchAll(database, sql: "SELECT status FROM coverage_records"),
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")!
            )
        }
        XCTAssertEqual(after.0, before.0)
        XCTAssertEqual(after.1, before.1)
        XCTAssertEqual(after.2, before.2)
    }

    func testFreshUnsupportedProjectFieldIsRetainedAsExplicitProvisionalContext() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let repository = ProjectV2Repository(vault: fixture.vault)
        let project = fixture.project()
        try await repository.replaceProjects(
            [project], rawPages: [], scope: fixture.scope, accountID: fixture.account.id,
            organization: fixture.organization,
            streamID: SyncStreamID(rawValue: "projects-acme")!, observedAt: fixture.date
        )
        let incomplete = fixture.projectItem(project: project, displayValue: "Observed", complete: false)
        try await repository.replaceItems(
            [incomplete], project: project,
            rawPages: [
                .init(
                    endpoint: "graphql:TriageProjectV2Items/project=P_1/page=1",
                    requestKey: "graphql:TriageProjectV2Items/project=P_1/after=none",
                    payload: projectItemsRawPayload()
                ),
                .init(
                    endpoint: "graphql:TriageProjectV2ItemFieldValues/item=PVTI_1/page=1",
                    requestKey: "graphql:TriageProjectV2ItemFieldValues/item=PVTI_1/after=none",
                    payload: projectFieldRawPayload()
                )
            ],
            scope: fixture.scope, accountID: fixture.account.id,
            organization: fixture.organization,
            streamID: SyncStreamID(rawValue: "project-items-P_1")!, observedAt: fixture.date
        )

        let persisted = try await fixture.vault.read { database in
            let row = try Row.fetchOne(
                database,
                sql: "SELECT display_value, context FROM project_field_values"
            )
            return (row?["display_value"] as String?, (row?["context"] as String?) ?? "")
        }
        XCTAssertEqual(persisted.0, "Observed")
        XCTAssertTrue(persisted.1.contains("provisional collection observation"))
        XCTAssertTrue(persisted.1.contains("unsupported union"))
    }

    func testRedactedProjectItemRetainsPriorContentReferenceAndDowngradesOnlyItemCoverage() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let repository = ProjectV2Repository(vault: fixture.vault)
        let project = fixture.project()
        let contentNodeID = GitHubNodeID(rawValue: "I_redacted")!
        try await fixture.vault.write { database in
            try GitHubNodeRepository.save(
                .init(
                    nodeID: contentNodeID, accountID: fixture.account.id,
                    organizationID: fixture.organization.id, repositoryID: fixture.repositoryID,
                    kind: .issue, numericID: "41", number: 41, title: "Previously visible",
                    state: .open, url: URL(string: "https://github.com/acme/repo/issues/41")!,
                    bodyMarkdown: nil, authorID: nil, createdAt: fixture.date, updatedAt: fixture.date,
                    closedAt: nil, mergedAt: nil, sourceRevision: "visible", observedAt: fixture.date,
                    accessibility: .accessible
                ),
                in: database
            )
        }
        try await repository.replaceProjects(
            [project], rawPages: [], scope: fixture.scope, accountID: fixture.account.id,
            organization: fixture.organization, streamID: SyncStreamID(rawValue: "projects-acme")!, observedAt: fixture.date
        )
        let visible = fixture.projectItem(
            project: project,
            displayValue: "Ready",
            contentNodeID: contentNodeID
        )
        try await repository.replaceItems(
            [visible], project: project, rawPages: [], scope: fixture.scope, accountID: fixture.account.id,
            organization: fixture.organization, streamID: SyncStreamID(rawValue: "project-items-P_1")!, observedAt: fixture.date
        )
        let redacted = GitHubProjectV2ItemRecord(
            nodeID: visible.nodeID, projectNodeID: project.nodeID, contentNodeID: nil, contentKind: nil,
            updatedAt: fixture.date.addingTimeInterval(60), fieldValues: [], fieldValuesComplete: true
        )
        let coverage = CoverageRecord(
            accountID: fixture.account.id, organizationID: fixture.organization.id, repositoryID: nil,
            feature: .projectItems, streamID: SyncStreamID(rawValue: "project-items-P_1")!,
            intervalStart: fixture.date, intervalEnd: fixture.date.addingTimeInterval(60),
            credentialRevision: fixture.scope.credentialRevision, capabilityRevision: fixture.scope.capabilityRevision,
            status: .partial, lastSuccessfulAt: nil,
            failureDetail: "One or more Project items are redacted for the current credential."
        )
        try await repository.replaceItems(
            [redacted], project: project, rawPages: [], scope: fixture.scope, accountID: fixture.account.id,
            organization: fixture.organization, streamID: SyncStreamID(rawValue: "project-items-P_1")!,
            observedAt: fixture.date.addingTimeInterval(60), coverageRecords: [coverage],
            redactedItemNodeIDs: [redacted.nodeID]
        )

        let persisted = try await fixture.vault.read { database in
            let row = try Row.fetchOne(
                database,
                sql: "SELECT content_node_id, content_node_reference, content_kind FROM project_items WHERE github_node_id = ?",
                arguments: [visible.nodeID.rawValue]
            )
            return (
                row?["content_node_id"] as String?,
                row?["content_node_reference"] as String?,
                row?["content_kind"] as String?
            )
        }
        XCTAssertEqual(persisted.0, contentNodeID.rawValue)
        XCTAssertEqual(persisted.1, contentNodeID.rawValue)
        XCTAssertEqual(persisted.2, GitHubContentKind.issue.rawValue)
        let retainedField = try await fixture.vault.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT display_value FROM project_field_values WHERE project_item_node_id = ? AND field_name = ?",
                arguments: [visible.nodeID.rawValue, "Status"]
            )
        }
        XCTAssertEqual(retainedField, "Ready")
        let savedCoverage = try await CoverageRepository(vault: fixture.vault).records(
            for: fixture.account.id,
            organizationID: fixture.organization.id
        )
        XCTAssertEqual(savedCoverage.first?.status, .partial)
        XCTAssertNil(savedCoverage.first?.lastSuccessfulAt)
    }

    func testKnownIncompleteProjectFieldUnionPersistsExplicitProvisionalContext() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let repository = ProjectV2Repository(vault: fixture.vault)
        let project = fixture.project()
        try await repository.replaceProjects(
            [project], rawPages: [], scope: fixture.scope, accountID: fixture.account.id,
            organization: fixture.organization, streamID: SyncStreamID(rawValue: "projects-acme")!, observedAt: fixture.date
        )
        let item = GitHubProjectV2ItemRecord(
            nodeID: GitHubNodeID(rawValue: "PVTI_nested")!, projectNodeID: project.nodeID,
            contentNodeID: nil, contentKind: nil, updatedAt: fixture.date,
            fieldValues: [
                .init(
                    fieldName: "Assignees", valueKind: "ProjectV2ItemFieldUserValue", displayValue: "U_1",
                    dateValue: nil, actorNodeID: GitHubNodeID(rawValue: "U_1")!,
                    context: "nested connection incomplete", isAuthoritative: false
                )
            ],
            fieldValuesComplete: false
        )
        try await repository.replaceItems(
            [item], project: project, rawPages: [], scope: fixture.scope, accountID: fixture.account.id,
            organization: fixture.organization, streamID: SyncStreamID(rawValue: "project-items-P_1")!, observedAt: fixture.date
        )

        let persistedContext = try await fixture.vault.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT context FROM project_field_values WHERE project_item_node_id = ? AND field_name = ?",
                arguments: [item.nodeID.rawValue, "Assignees"]
            )
        }
        XCTAssertTrue(try XCTUnwrap(persistedContext).contains("provisional collection observation"))
        XCTAssertTrue(try XCTUnwrap(persistedContext).contains("nested connection incomplete"))
    }

    func testProjectItemSynchronizationMarksRedactedItemsPartialWithoutErasingTheItem() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let project = fixture.project()
        try await ProjectV2Repository(vault: fixture.vault).replaceProjects(
            [project], rawPages: [], scope: fixture.scope, accountID: fixture.account.id,
            organization: fixture.organization, streamID: SyncStreamID(rawValue: "projects-acme")!, observedAt: fixture.date
        )
        let itemID = GitHubNodeID(rawValue: "PVTI_redacted")!
        let session = ProjectItemSequenceSession(responses: [
            projectItemsInventoryResponse(itemID: itemID.rawValue),
            projectItemEmptyFieldValuesResponse(itemID: itemID.rawValue)
        ])
        let service = ProjectV2SynchronizationService(
            client: GitHubProjectV2Client(
                client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
            ),
            repository: ProjectV2Repository(vault: fixture.vault),
            coverage: CoverageRepository(vault: fixture.vault)
        )

        let result = try await service.refreshItems(
            project: project, scope: fixture.scope, organization: fixture.organization,
            streamID: SyncStreamID(rawValue: "project-items-P_1")!, previousHighWater: fixture.date,
            observedAt: fixture.date.addingTimeInterval(60)
        )

        XCTAssertEqual(result.status, .partial)
        XCTAssertNil(result.lastSuccessfulAt)
        XCTAssertTrue(try XCTUnwrap(result.failureDetail).contains("redacted"))
        XCTAssertEqual(result.intervalStart, fixture.date.addingTimeInterval(-5 * 60))

        let fullSession = ProjectItemSequenceSession(responses: [
            projectItemsInventoryResponse(itemID: itemID.rawValue),
            projectItemEmptyFieldValuesResponse(itemID: itemID.rawValue)
        ])
        let fullService = ProjectV2SynchronizationService(
            client: GitHubProjectV2Client(
                client: GitHubGraphQLClient(session: fullSession, credential: SecretValue("token"))
            ),
            repository: ProjectV2Repository(vault: fixture.vault),
            coverage: CoverageRepository(vault: fixture.vault)
        )
        let fullResult = try await fullService.refreshItems(
            project: project, scope: fixture.scope, organization: fixture.organization,
            streamID: SyncStreamID(rawValue: "project-items-P_1")!, previousHighWater: fixture.date,
            reconciliationIntent: .fullReconciliation,
            observedAt: fixture.date.addingTimeInterval(120)
        )
        XCTAssertEqual(fullResult.status, .partial)
        XCTAssertEqual(fullResult.intervalStart, Date(timeIntervalSince1970: 0))
        let persisted = try await fixture.vault.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM project_items")!,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")!
            )
        }
        XCTAssertEqual(persisted.0, 1)
        XCTAssertEqual(persisted.1, 4)
    }

    func testDiscussionReplacementAndCoverageRollbackTogether() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let repository = DiscussionRepository(vault: fixture.vault)
        let invalidAccountID = AccountID.make()
        let coverage = fixture.coverage(
            accountID: invalidAccountID,
            feature: .discussions,
            stream: "discussions-acme-R_1",
            status: .complete
        )

        await XCTAssertThrowsErrorAsync {
            try await repository.replace(
                [fixture.discussion(id: "D_atomic", title: "Must roll back")],
                rawPages: [.init(
                    endpoint: "graphql:TriageRepositoryDiscussions/repository=R_1/page=1",
                    requestKey: "graphql:TriageRepositoryDiscussions/repository=R_1/after=none",
                    payload: discussionRawPayload()
                )],
                scope: fixture.scope,
                accountID: fixture.account.id,
                organization: fixture.organization,
                repositoryID: fixture.repositoryID,
                repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
                streamID: SyncStreamID(rawValue: "discussions-acme-R_1")!,
                observedAt: fixture.date,
                coverageRecords: [coverage]
            )
        }

        let counts = try await fixture.vault.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM discussions")!,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")!,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM coverage_records")!
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 0)
    }

    func testDiscussionRejectsMalformedRawBindingWithoutReplacingCachedContent() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let repository = DiscussionRepository(vault: fixture.vault)
        let validRaw = GitHubDiscussionRawPage(
            endpoint: "graphql:TriageRepositoryDiscussions/repository=R_1/page=1",
            requestKey: "graphql:TriageRepositoryDiscussions/repository=R_1/after=none",
            payload: discussionRawPayload(marker: "first")
        )
        try await repository.replace(
            [fixture.discussion(id: "D_1", title: "Retained")], rawPages: [validRaw], scope: fixture.scope,
            accountID: fixture.account.id, organization: fixture.organization, repositoryID: fixture.repositoryID,
            repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
            streamID: SyncStreamID(rawValue: "discussions-acme-R_1")!, observedAt: fixture.date
        )

        await XCTAssertThrowsErrorAsync {
            try await repository.replace(
                [fixture.discussion(id: "D_2", title: "Must not persist")], rawPages: [.init(
                    endpoint: "graphql:TriageRepositoryDiscussions/repository=R_1/page=1",
                    requestKey: "graphql:TriageRepositoryDiscussions/repository=R_1/after=not-base64",
                    payload: discussionRawPayload(marker: "second")
                )], scope: fixture.scope, accountID: fixture.account.id, organization: fixture.organization,
                repositoryID: fixture.repositoryID, repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
                streamID: SyncStreamID(rawValue: "discussions-acme-R_1")!, observedAt: fixture.date
            )
        }
        let titles = try await fixture.vault.read { database in
            try String.fetchAll(database, sql: "SELECT title FROM github_nodes WHERE kind = 'discussion'")
        }
        XCTAssertEqual(titles, ["Retained"])
    }

    func testDiscussionRejectsRepositoryIDAndNodeFromDifferentRepositories() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        _ = try await AccountRepository(vault: fixture.vault).save(
            repository: .init(
                id: 4,
                nodeID: "R_2",
                name: "other",
                isPrivate: true,
                isArchived: false,
                hasDiscussions: true,
                htmlURL: URL(string: "https://github.com/acme/other")!,
                updatedAt: fixture.date,
                owner: .init(login: "acme")
            ),
            organizationID: fixture.organization.id,
            accountID: fixture.account.id
        )
        let repository = DiscussionRepository(vault: fixture.vault)

        await XCTAssertThrowsErrorAsync {
            try await repository.replace(
                [fixture.discussion(id: "D_cross_repo", title: "Must not persist")],
                rawPages: [.init(
                    endpoint: "graphql:TriageRepositoryDiscussions/repository=R_2/page=1",
                    requestKey: "graphql:TriageRepositoryDiscussions/repository=R_2/after=none",
                    payload: discussionRawPayload(repositoryNodeID: "R_2")
                )],
                scope: fixture.scope,
                accountID: fixture.account.id,
                organization: fixture.organization,
                repositoryID: fixture.repositoryID,
                repositoryNodeID: GitHubNodeID(rawValue: "R_2")!,
                streamID: SyncStreamID(rawValue: "discussions-acme-R_2")!,
                observedAt: fixture.date
            )
        } verify: { error in
            XCTAssertEqual(error as? DiscussionRepositoryError, .repositoryScopeMismatch)
        }
        let counts = try await fixture.vault.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM discussions")!,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")!
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
    }

    func testDiscussionRejectsTraversalThatStartsAfterACursor() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let cursor = Data("cursor-1".utf8).base64EncodedString()
        await XCTAssertThrowsErrorAsync {
            try await DiscussionRepository(vault: fixture.vault).replace(
                [fixture.discussion(id: "D_cursor", title: "Must not persist")],
                rawPages: [.init(
                    endpoint: "graphql:TriageRepositoryDiscussions/repository=R_1/page=1",
                    requestKey: "graphql:TriageRepositoryDiscussions/repository=R_1/after=\(cursor)",
                    payload: discussionRawPayload()
                )],
                scope: fixture.scope,
                accountID: fixture.account.id,
                organization: fixture.organization,
                repositoryID: fixture.repositoryID,
                repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
                streamID: SyncStreamID(rawValue: "discussions-acme-R_1")!,
                observedAt: fixture.date
            )
        } verify: { error in
            XCTAssertEqual(error as? DiscussionRepositoryError, .invalidRawAuthority)
        }
    }

    func testDiscussionRawObservationsRemainDistinctAcrossTimesAndIdempotentAtOneTime() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let repository = DiscussionRepository(vault: fixture.vault)
        let raw = GitHubDiscussionRawPage(
            endpoint: "graphql:TriageRepositoryDiscussions/repository=R_1/page=1",
            requestKey: "graphql:TriageRepositoryDiscussions/repository=R_1/after=none",
            payload: discussionRawPayload(marker: "same")
        )
        let streamID = SyncStreamID(rawValue: "discussions-acme-R_1")!
        func replace(at observedAt: Date, page: GitHubDiscussionRawPage = raw) async throws {
            try await repository.replace(
                [fixture.discussion(id: "D_observation", title: "Retained")], rawPages: [page], scope: fixture.scope,
                accountID: fixture.account.id, organization: fixture.organization, repositoryID: fixture.repositoryID,
                repositoryNodeID: GitHubNodeID(rawValue: "R_1")!, streamID: streamID, observedAt: observedAt
            )
        }

        try await replace(at: fixture.date)
        try await replace(at: fixture.date) // exact retry is idempotent
        try await replace(at: fixture.date.addingTimeInterval(1)) // later observation is retained
        let persisted = try await fixture.vault.read { database in
            try Row.fetchAll(database, sql: "SELECT id, observed_at_ms FROM raw_api_snapshots ORDER BY observed_at_ms, id")
                .map { (($0["id"] as String), ($0["observed_at_ms"] as Int64)) }
        }
        XCTAssertEqual(persisted.count, 2)
        XCTAssertNotEqual(persisted[0].0, persisted[1].0)
        XCTAssertEqual(persisted.map(\.1), [1_000_000, 1_001_000])

        await XCTAssertThrowsErrorAsync {
            try await replace(at: fixture.date, page: .init(
                endpoint: raw.endpoint, requestKey: raw.requestKey,
                payload: discussionRawPayload(marker: "different")
            ))
        } verify: { error in
            XCTAssertEqual(error as? DiscussionRepositoryError, .conflictingRawPage)
        }
        let countAfterConflict = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")!
        }
        XCTAssertEqual(countAfterConflict, 2)
    }

    func testProjectReplacementRejectsCrossOrganizationScopeBeforeRawPersistence() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let repository = ProjectV2Repository(vault: fixture.vault)
        let crossScope = SynchronizationScope(
            accountID: fixture.account.id,
            organizationID: OrganizationID(rawValue: "other")!,
            credentialRevision: fixture.scope.credentialRevision,
            capabilityRevision: fixture.scope.capabilityRevision
        )

        await XCTAssertThrowsErrorAsync {
            try await repository.replaceProjects(
                [fixture.project()], rawPages: [], scope: crossScope, accountID: fixture.account.id,
                organization: fixture.organization, streamID: SyncStreamID(rawValue: "projects-acme")!, observedAt: fixture.date
            )
        }
        let counts = try await fixture.vault.read { database in
            (try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM projects")!,
             try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")!)
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
    }

    func testProjectItemsRejectFieldPageForUnrelatedItem() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let repository = ProjectV2Repository(vault: fixture.vault)
        let project = fixture.project()
        try await repository.replaceProjects(
            [project], rawPages: [], scope: fixture.scope,
            accountID: fixture.account.id, organization: fixture.organization,
            streamID: SyncStreamID(rawValue: "projects-acme")!, observedAt: fixture.date
        )
        let item = fixture.projectItem(project: project)

        await XCTAssertThrowsErrorAsync {
            try await repository.replaceItems(
                [item],
                project: project,
                rawPages: [
                    .init(
                        endpoint: "graphql:TriageProjectV2Items/project=P_1/page=1",
                        requestKey: "graphql:TriageProjectV2Items/project=P_1/after=none",
                        payload: projectItemsRawPayload()
                    ),
                    .init(
                        endpoint: "graphql:TriageProjectV2ItemFieldValues/item=PVTI_OTHER/page=1",
                        requestKey: "graphql:TriageProjectV2ItemFieldValues/item=PVTI_OTHER/after=none",
                        payload: projectFieldRawPayload(itemNodeID: "PVTI_OTHER")
                    )
                ],
                scope: fixture.scope,
                accountID: fixture.account.id,
                organization: fixture.organization,
                streamID: SyncStreamID(rawValue: "project-items-P_1")!,
                observedAt: fixture.date
            )
        } verify: { error in
            XCTAssertEqual(error as? ProjectV2RepositoryError, .invalidRawAuthority)
        }
        let counts = try await fixture.vault.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM project_items")!,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")!
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
    }

    func testScopedRawSnapshotRejectsContentNodeFromAnotherOrganization() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let discussionRepository = DiscussionRepository(vault: fixture.vault)
        try await discussionRepository.replace(
            [fixture.discussion(id: "D_cross", title: "Source A")], rawPages: [.init(
                endpoint: "graphql:TriageRepositoryDiscussions/repository=R_1/page=1",
                requestKey: "graphql:TriageRepositoryDiscussions/repository=R_1/after=none",
                payload: discussionRawPayload()
            )], scope: fixture.scope,
            accountID: fixture.account.id, organization: fixture.organization, repositoryID: fixture.repositoryID,
            repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
            streamID: SyncStreamID(rawValue: "discussions-acme-R_1")!, observedAt: fixture.date
        )
        let otherOrganization = GitHubOrganization(
            id: OrganizationID(rawValue: "other")!, githubOrganizationID: 44,
            nodeID: GitHubNodeID(rawValue: "O_44")!, login: "other"
        )
        try await AccountRepository(vault: fixture.vault).save(
            otherOrganization,
            access: .init(accountID: fixture.account.id, organizationID: otherOrganization.id, state: .available,
                          capabilityRevision: CapabilityRevision(rawValue: "capability-other")!, capabilities: [], checkedAt: fixture.date)
        )
        let otherScope = SynchronizationScope(
            accountID: fixture.account.id, organizationID: otherOrganization.id,
            credentialRevision: fixture.scope.credentialRevision,
            capabilityRevision: CapabilityRevision(rawValue: "capability-other")!
        )
        let snapshot = RawAPISnapshot(
            id: .make(), accountID: fixture.account.id, githubNodeID: GitHubNodeID(rawValue: "D_cross")!,
            endpoint: "graphql:TriageRepositoryDiscussions/repository=R_1/page=1", eTag: nil,
            parserVersion: 1, observedAt: fixture.date, payload: Data("{}".utf8),
            requestIdentity: .init(
                scope: otherScope, feature: .discussions,
                streamID: SyncStreamID(rawValue: "discussions-other-R_1")!,
                requestKey: "graphql:TriageRepositoryDiscussions/repository=R_1/after=none"
            )
        )

        await XCTAssertThrowsErrorAsync {
            try await RawAPISnapshotRepository(vault: fixture.vault).save(snapshot)
        } verify: { error in
            XCTAssertEqual(error as? RawAPISnapshotRepositoryError, .nodeScopeMismatch)
        }
    }

    func testScopedRawSnapshotRejectsRepositoryWithoutAvailableAccess() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        try await fixture.vault.write { database in
            try database.execute(
                sql: "UPDATE account_repository_access SET access_state = 'inaccessible' WHERE account_id = ? AND repository_id = ?",
                arguments: [fixture.account.id.rawValue, fixture.repositoryID.rawValue]
            )
        }
        let snapshot = RawAPISnapshot(
            id: .make(), accountID: fixture.account.id, githubNodeID: GitHubNodeID(rawValue: "R_1")!,
            endpoint: "graphql:TriageRepositoryDiscussions/repository=R_1/page=1", eTag: nil,
            parserVersion: 1, observedAt: fixture.date, payload: Data("{}".utf8),
            requestIdentity: .init(
                scope: fixture.scope, feature: .discussions,
                streamID: SyncStreamID(rawValue: "discussions-acme-R_1")!,
                requestKey: "graphql:TriageRepositoryDiscussions/repository=R_1/after=none"
            )
        )

        await XCTAssertThrowsErrorAsync {
            try await RawAPISnapshotRepository(vault: fixture.vault).save(snapshot)
        } verify: { error in
            XCTAssertEqual(error as? RawAPISnapshotRepositoryError, .nodeScopeMismatch)
        }
    }

    func testRawSnapshotIDIsImmutableAndExactMillisecondReplayIsIdempotent() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let repository = RawAPISnapshotRepository(vault: fixture.vault)
        let snapshotID = RawAPISnapshotID.make()
        let observedAt = Date(timeIntervalSince1970: 1_000.0004)
        let identity = ConditionalRequestIdentity(
            scope: fixture.scope,
            feature: .projects,
            streamID: SyncStreamID(rawValue: "projects-acme")!,
            requestKey: "graphql:TriageOrganizationProjectsV2/organization=O_2/after=none"
        )
        let snapshot = RawAPISnapshot(
            id: snapshotID,
            accountID: fixture.account.id,
            githubNodeID: fixture.organization.nodeID,
            endpoint: "graphql:TriageOrganizationProjectsV2/organization=O_2/page=1",
            eTag: nil,
            parserVersion: 1,
            observedAt: observedAt,
            payload: projectInventoryRawPayload(marker: "one"),
            requestIdentity: identity
        )

        try await repository.save(snapshot)
        try await repository.save(snapshot)
        let conflicting = RawAPISnapshot(
            id: snapshotID,
            accountID: snapshot.accountID,
            githubNodeID: snapshot.githubNodeID,
            endpoint: snapshot.endpoint,
            eTag: snapshot.eTag,
            parserVersion: snapshot.parserVersion,
            observedAt: snapshot.observedAt,
            payload: projectInventoryRawPayload(marker: "two"),
            requestIdentity: identity
        )
        await XCTAssertThrowsErrorAsync {
            try await repository.save(conflicting)
        } verify: { error in
            XCTAssertEqual(error as? RawAPISnapshotRepositoryError, .immutableSnapshotConflict)
        }
        let persisted = try await repository.snapshots(for: fixture.account.id)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted[0].payload, snapshot.payload)
    }

    func testProjectItemLinksOnlyToAnExistingNodeInTheCurrentScope() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let repository = ProjectV2Repository(vault: fixture.vault)
        let project = fixture.project()
        let contentNodeID = GitHubNodeID(rawValue: "I_1")!
        try await fixture.vault.write { database in
            try GitHubNodeRepository.save(
                .init(
                    nodeID: contentNodeID,
                    accountID: fixture.account.id,
                    organizationID: fixture.organization.id,
                    repositoryID: fixture.repositoryID,
                    kind: .issue,
                    numericID: "9",
                    number: 1,
                    title: "Relevant issue",
                    state: .open,
                    url: URL(string: "https://github.com/acme/repo/issues/1")!,
                    bodyMarkdown: nil,
                    authorID: nil,
                    createdAt: fixture.date,
                    updatedAt: fixture.date,
                    closedAt: nil,
                    mergedAt: nil,
                    sourceRevision: "one",
                    observedAt: fixture.date,
                    accessibility: .accessible
                ),
                in: database
            )
        }
        try await repository.replaceProjects(
            [project], rawPages: [], scope: fixture.scope, accountID: fixture.account.id,
            organization: fixture.organization, streamID: SyncStreamID(rawValue: "projects-acme")!, observedAt: fixture.date
        )
        let item = fixture.projectItem(project: project, contentNodeID: contentNodeID)
        try await repository.replaceItems(
            [item], project: project, rawPages: [], scope: fixture.scope, accountID: fixture.account.id,
            organization: fixture.organization, streamID: SyncStreamID(rawValue: "project-items-P_1")!, observedAt: fixture.date
        )

        let link = try await fixture.vault.read { database in
            let row = try Row.fetchOne(
                database,
                sql: "SELECT content_node_id, content_node_reference FROM project_items"
            )
            return (row?["content_node_id"] as String?, row?["content_node_reference"] as String?)
        }
        XCTAssertEqual(link.0, contentNodeID.rawValue)
        XCTAssertEqual(link.1, contentNodeID.rawValue)
    }

    func testDiscussionSynchronizationPersistsMetadataAndUnavailableNestedCoverageAtomically() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let session = OneShotDiscussionSession(.data(discussionInventoryResponse()))
        let service = DiscussionSynchronizationService(
            client: GitHubDiscussionClient(
                client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
            ),
            repository: DiscussionRepository(vault: fixture.vault),
            coverage: CoverageRepository(vault: fixture.vault)
        )
        let streamID = SyncStreamID(rawValue: "discussions-acme-R_1")!
        let prior = fixture.date.addingTimeInterval(-3_600)

        let result = try await service.refresh(
            scope: fixture.scope,
            organization: fixture.organization,
            repositoryID: fixture.repositoryID,
            repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
            streamID: streamID,
            previousHighWater: prior,
            observedAt: fixture.date
        )

        XCTAssertEqual(result.coverage.status, .complete)
        XCTAssertEqual(result.commentCoverage, .unavailable)
        XCTAssertEqual(result.replyCoverage, .unavailable)
        let coverage = try await CoverageRepository(vault: fixture.vault).records(
            for: fixture.account.id,
            organizationID: fixture.organization.id
        )
        XCTAssertEqual(
            Set(coverage.map(\.feature)),
            [.discussions, .discussionComments, .discussionReplies]
        )
        XCTAssertEqual(
            coverage.first(where: { $0.feature == .discussions })?.intervalStart,
            prior.addingTimeInterval(-5 * 60)
        )
        let stream = try await SyncStreamRepository(vault: fixture.vault)
            .stream(withID: streamID, accountID: fixture.account.id)
        XCTAssertEqual(stream?.highWater, fixture.date)
    }

    func testProjectReferenceBackfillCannotCrossParentProjectOrganization() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let repository = ProjectV2Repository(vault: fixture.vault)
        let contentNodeID = GitHubNodeID(rawValue: "I_scope")!
        try await fixture.vault.write { database in
            try GitHubNodeRepository.save(
                .init(
                    nodeID: contentNodeID, accountID: fixture.account.id,
                    organizationID: fixture.organization.id, repositoryID: fixture.repositoryID,
                    kind: .issue, numericID: "19", number: 19, title: "Scoped issue",
                    state: .open, url: URL(string: "https://github.com/acme/repo/issues/19")!,
                    bodyMarkdown: nil, authorID: nil, createdAt: fixture.date,
                    updatedAt: fixture.date, closedAt: nil, mergedAt: nil,
                    sourceRevision: "scope", observedAt: fixture.date, accessibility: .accessible
                ),
                in: database
            )
        }
        let otherOrganization = GitHubOrganization(
            id: OrganizationID(rawValue: "beta")!, githubOrganizationID: 22,
            nodeID: GitHubNodeID(rawValue: "O_22")!, login: "beta"
        )
        try await AccountRepository(vault: fixture.vault).save(
            otherOrganization,
            access: .init(
                accountID: fixture.account.id, organizationID: otherOrganization.id,
                state: .available,
                capabilityRevision: CapabilityRevision(rawValue: "capability-2")!,
                capabilities: [], checkedAt: fixture.date
            )
        )
        let otherProject = GitHubProjectV2Record(
            nodeID: GitHubNodeID(rawValue: "P_2")!, number: 2, title: "Other",
            description: nil, url: URL(string: "https://github.com/orgs/beta/projects/2")!,
            updatedAt: fixture.date, state: .open
        )
        try await repository.replaceProjects(
            [otherProject], rawPages: [], scope: SynchronizationScope(
                accountID: fixture.account.id, organizationID: otherOrganization.id,
                credentialRevision: CredentialRevision(rawValue: "credential-1")!,
                capabilityRevision: CapabilityRevision(rawValue: "capability-2")!
            ), accountID: fixture.account.id,
            organization: otherOrganization, streamID: SyncStreamID(rawValue: "projects-beta")!, observedAt: fixture.date
        )
        let otherItem = GitHubProjectV2ItemRecord(
            nodeID: GitHubNodeID(rawValue: "PVTI_2")!, projectNodeID: otherProject.nodeID,
            contentNodeID: contentNodeID, contentKind: .issue, updatedAt: fixture.date,
            fieldValues: [], fieldValuesComplete: true
        )
        try await repository.replaceItems(
            [otherItem], project: otherProject, rawPages: [], scope: SynchronizationScope(
                accountID: fixture.account.id, organizationID: otherOrganization.id,
                credentialRevision: CredentialRevision(rawValue: "credential-1")!,
                capabilityRevision: CapabilityRevision(rawValue: "capability-2")!
            ), accountID: fixture.account.id,
            organization: otherOrganization, streamID: SyncStreamID(rawValue: "project-items-P_2")!, observedAt: fixture.date
        )

        try await repository.resolveContentReferences(
            accountID: fixture.account.id,
            organizationID: fixture.organization.id
        )

        let linked = try await fixture.vault.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT content_node_id FROM project_items WHERE github_node_id = 'PVTI_2'"
            )
        }
        XCTAssertNil(linked)
    }

    func testDiscussionSynchronizationCancellationPublishesNoFailureCoverage() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let session = OneShotDiscussionSession(.cancellation)
        let service = DiscussionSynchronizationService(
            client: GitHubDiscussionClient(
                client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
            ),
            repository: DiscussionRepository(vault: fixture.vault),
            coverage: CoverageRepository(vault: fixture.vault)
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await service.refresh(
                scope: fixture.scope,
                organization: fixture.organization,
                repositoryID: fixture.repositoryID,
                repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
                streamID: SyncStreamID(rawValue: "discussions-acme-R_1")!,
                previousHighWater: nil,
                observedAt: fixture.date
            )
        }, verify: { error in
            XCTAssertTrue(error is CancellationError)
        })
        let coverage = try await CoverageRepository(vault: fixture.vault).records(
            for: fixture.account.id,
            organizationID: fixture.organization.id
        )
        XCTAssertTrue(coverage.isEmpty)
    }

    func testDiscussionScopeRotationBeforeNetworkFailureCancelsWithoutFailureCoverage() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let session = RevisionRotatingDiscussionSession(
            accounts: AccountRepository(vault: fixture.vault), account: fixture.account,
            credentialRevision: CredentialRevision(rawValue: "credential-rotated")!
        )
        let service = DiscussionSynchronizationService(
            client: GitHubDiscussionClient(
                client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
            ),
            repository: DiscussionRepository(vault: fixture.vault),
            coverage: CoverageRepository(vault: fixture.vault)
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await service.refresh(
                scope: fixture.scope, organization: fixture.organization, repositoryID: fixture.repositoryID,
                repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
                streamID: SyncStreamID(rawValue: "discussions-acme-R_1")!, previousHighWater: nil,
                observedAt: fixture.date
            )
        }, verify: { error in
            XCTAssertTrue(error is CancellationError)
        })
        let persisted = try await fixture.vault.read { database in
            (try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM coverage_records")!,
             try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")!)
        }
        XCTAssertEqual(persisted.0, 0)
        XCTAssertEqual(persisted.1, 0)
    }

    func testDiscussionMissingDataRetainsRawFailureWithoutAdvancingHighWater() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let session = OneShotDiscussionSession(
            .data(Data(#"{"data":null}"#.utf8))
        )
        let streamID = SyncStreamID(rawValue: "discussions-acme-R_1")!
        let service = DiscussionSynchronizationService(
            client: GitHubDiscussionClient(
                client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
            ),
            repository: DiscussionRepository(vault: fixture.vault),
            coverage: CoverageRepository(vault: fixture.vault)
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await service.refresh(
                scope: fixture.scope, organization: fixture.organization,
                repositoryID: fixture.repositoryID,
                repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
                streamID: streamID, previousHighWater: nil, observedAt: fixture.date
            )
        }, verify: { error in
            guard case GitHubDiscussionClientError.missingData = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        })

        let persisted = try await fixture.vault.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")!,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM normalization_failures")!,
                try String.fetchOne(database, sql: "SELECT github_node_id FROM normalization_failures")
            )
        }
        XCTAssertEqual(persisted.0, 1)
        XCTAssertEqual(persisted.1, 1)
        XCTAssertEqual(persisted.2, "R_1")
        let coverage = try await CoverageRepository(vault: fixture.vault).records(
            for: fixture.account.id, organizationID: fixture.organization.id
        )
        XCTAssertEqual(coverage.first?.status, .partial)
        let stream = try await SyncStreamRepository(vault: fixture.vault).stream(
            withID: streamID, accountID: fixture.account.id
        )
        XCTAssertNil(stream?.highWater)
    }

    func testDiscussionPartialResultsRetainRawEvidenceAndPersistPartialCoverage() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let header = "partial-results; organizations=\(fixture.organization.githubOrganizationID)"
        let session = OneShotDiscussionSession(
            .response(discussionInventoryResponse(), ["X-GitHub-SSO": header])
        )
        let streamID = SyncStreamID(rawValue: "discussions-acme-R_1")!
        let service = DiscussionSynchronizationService(
            client: GitHubDiscussionClient(
                client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
            ),
            repository: DiscussionRepository(vault: fixture.vault),
            coverage: CoverageRepository(vault: fixture.vault)
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await service.refresh(
                scope: fixture.scope,
                organization: fixture.organization,
                repositoryID: fixture.repositoryID,
                repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
                streamID: streamID,
                previousHighWater: nil,
                observedAt: fixture.date
            )
        }, verify: { error in
            guard case let GitHubDiscussionClientError.ssoResponse(pages, parsedHeader) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(parsedHeader, GitHubSSOHeader(value: header))
            XCTAssertEqual(pages.count, 1)
        })

        let persisted = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")!
        }
        XCTAssertEqual(persisted, 1)
        let coverage = try await CoverageRepository(vault: fixture.vault).records(
            for: fixture.account.id,
            organizationID: fixture.organization.id
        )
        XCTAssertEqual(coverage.first?.status, .partial)
        let stream = try await SyncStreamRepository(vault: fixture.vault)
            .stream(withID: streamID, accountID: fixture.account.id)
        XCTAssertNil(stream?.highWater)
    }

    func testDiscussionUndecodableResponseRetainsRawFailureWithoutAdvancingHighWater() async throws {
        let fixture = try await DiscussionFixture()
        defer { fixture.remove() }
        let malformed = Data("{".utf8)
        let session = OneShotDiscussionSession(.data(malformed))
        let streamID = SyncStreamID(rawValue: "discussions-acme-R_1")!
        let service = DiscussionSynchronizationService(
            client: GitHubDiscussionClient(
                client: GitHubGraphQLClient(session: session, credential: SecretValue("token"))
            ),
            repository: DiscussionRepository(vault: fixture.vault),
            coverage: CoverageRepository(vault: fixture.vault)
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await service.refresh(
                scope: fixture.scope, organization: fixture.organization,
                repositoryID: fixture.repositoryID,
                repositoryNodeID: GitHubNodeID(rawValue: "R_1")!,
                streamID: streamID, previousHighWater: nil, observedAt: fixture.date
            )
        }, verify: { error in
            guard case let GitHubDiscussionClientError.undecodableResponse(pages) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(pages.count, 1)
            XCTAssertEqual(pages[0].payload, malformed)
        })

        let persisted = try await fixture.vault.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM raw_api_snapshots")!,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM normalization_failures")!,
                try Data.fetchOne(database, sql: "SELECT payload FROM raw_api_snapshots")
            )
        }
        XCTAssertEqual(persisted.0, 1)
        XCTAssertEqual(persisted.1, 1)
        XCTAssertEqual(persisted.2, malformed)
        let coverage = try await CoverageRepository(vault: fixture.vault).records(
            for: fixture.account.id, organizationID: fixture.organization.id
        )
        XCTAssertEqual(coverage.first?.status, .partial)
        let stream = try await SyncStreamRepository(vault: fixture.vault).stream(
            withID: streamID, accountID: fixture.account.id
        )
        XCTAssertNil(stream?.highWater)
    }
}

private func discussionRawPayload(
    repositoryNodeID: String = "R_1",
    hasNextPage: Bool = false,
    endCursor: String? = nil,
    marker: String = ""
) -> Data {
    graphQLRawPayload(
        nodeID: repositoryNodeID,
        connection: "discussions",
        hasNextPage: hasNextPage,
        endCursor: endCursor,
        marker: marker
    )
}

private func projectInventoryRawPayload(
    organizationNodeID: String = "O_2",
    hasNextPage: Bool = false,
    endCursor: String? = nil,
    marker: String = "",
    nodeIDs: [String] = []
) -> Data {
    graphQLRawPayload(
        nodeID: organizationNodeID,
        connection: "projectsV2",
        hasNextPage: hasNextPage,
        endCursor: endCursor,
        marker: marker,
        nodeIDs: nodeIDs
    )
}

private func projectItemsRawPayload(
    projectNodeID: String = "P_1",
    hasNextPage: Bool = false,
    endCursor: String? = nil,
    marker: String = "",
    nodeIDs: [String] = []
) -> Data {
    graphQLRawPayload(
        nodeID: projectNodeID,
        connection: "items",
        hasNextPage: hasNextPage,
        endCursor: endCursor,
        marker: marker,
        nodeIDs: nodeIDs
    )
}

private func projectFieldRawPayload(
    itemNodeID: String = "PVTI_1",
    hasNextPage: Bool = false,
    endCursor: String? = nil,
    marker: String = ""
) -> Data {
    graphQLRawPayload(
        nodeID: itemNodeID,
        connection: "fieldValues",
        hasNextPage: hasNextPage,
        endCursor: endCursor,
        marker: marker
    )
}

private func graphQLRawPayload(
    nodeID: String,
    connection: String,
    hasNextPage: Bool,
    endCursor: String?,
    marker: String,
    nodeIDs: [String]? = nil
) -> Data {
    let pageInfo: [String: Any] = [
        "hasNextPage": hasNextPage,
        "endCursor": endCursor ?? NSNull()
    ]
    var connectionPayload: [String: Any] = ["pageInfo": pageInfo]
    if let nodeIDs {
        connectionPayload["nodes"] = nodeIDs.map { ["id": $0] }
    }
    return try! JSONSerialization.data(
        withJSONObject: [
            "data": [
                "node": [
                    "id": nodeID,
                    connection: connectionPayload
                ]
            ],
            "marker": marker
        ],
        options: [.sortedKeys]
    )
}

private final class DiscussionFixture: @unchecked Sendable {
    let root: URL
    let vault: AccountVault
    let account: GitHubAccount
    let organization: GitHubOrganization
    let repositoryID = RepositoryID(rawValue: "R_1")!
    let date = Date(timeIntervalSince1970: 1_000)

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".triage-discussion-test-\(UUID().uuidString)", isDirectory: true)
        let accountID = AccountID.make()
        account = .init(id: accountID, githubUserID: 1, nodeID: GitHubNodeID(rawValue: "U_1")!, login: "octocat",
                        authenticationKind: .oauth, credentialID: CredentialID.make(), credentialStatus: .active,
                        createdAt: date, lastValidatedAt: date)
        organization = .init(id: OrganizationID(rawValue: "acme")!, githubOrganizationID: 2,
                             nodeID: GitHubNodeID(rawValue: "O_2")!, login: "acme")
        vault = try await VaultRegistry(rootDirectory: root).open(accountID: accountID, vaultKey: VaultKey.generate())
        let accounts = AccountRepository(vault: vault)
        try await accounts.save(account, credentialRevision: CredentialRevision(rawValue: "credential-1")!)
        try await accounts.save(
            organization,
            access: .init(accountID: accountID, organizationID: organization.id, state: .available,
                          capabilityRevision: CapabilityRevision(rawValue: "capability-1")!, capabilities: [], checkedAt: date)
        )
        _ = try await accounts.save(
            repository: .init(id: 3, nodeID: repositoryID.rawValue, name: "repo", isPrivate: true, isArchived: false,
                              hasDiscussions: true, htmlURL: URL(string: "https://github.com/acme/repo")!, updatedAt: date,
                              owner: .init(login: "acme")),
            organizationID: organization.id, accountID: accountID
        )
    }

    func discussion(id: String, title: String) -> GitHubDiscussionRecord {
        .init(nodeID: GitHubNodeID(rawValue: id)!, number: 1, title: title, body: nil,
              url: URL(string: "https://github.com/acme/repo/discussions/1")!, createdAt: date, updatedAt: date,
              closedAt: nil, state: .open, categoryName: nil, answerCommentNodeID: nil, commentsCount: 0)
    }

    func project() -> GitHubProjectV2Record {
        .init(nodeID: GitHubNodeID(rawValue: "P_1")!, number: 1, title: "Roadmap", description: nil,
              url: URL(string: "https://github.com/orgs/acme/projects/1")!, updatedAt: date, state: .open)
    }

    func projectItem(
        project: GitHubProjectV2Record,
        displayValue: String? = nil,
        complete: Bool = true,
        contentNodeID: GitHubNodeID? = nil
    ) -> GitHubProjectV2ItemRecord {
        .init(
            nodeID: GitHubNodeID(rawValue: "PVTI_1")!, projectNodeID: project.nodeID, contentNodeID: contentNodeID,
            contentKind: contentNodeID == nil ? nil : .issue, updatedAt: date,
            fieldValues: [.init(fieldName: "Status", valueKind: "ProjectV2ItemFieldSingleSelectValue",
                                displayValue: displayValue, dateValue: nil, actorNodeID: nil,
                                context: complete ? "ProjectV2ItemFieldSingleSelectValue" : "unsupported union",
                                isAuthoritative: complete)],
            fieldValuesComplete: complete
        )
    }

    func coverage(
        accountID: AccountID,
        feature: CoverageFeature,
        stream: String,
        status: CoverageStatus
    ) -> CoverageRecord {
        .init(
            accountID: accountID,
            organizationID: organization.id,
            repositoryID: repositoryID,
            feature: feature,
            streamID: SyncStreamID(rawValue: stream)!,
            intervalStart: date,
            intervalEnd: date,
            credentialRevision: CredentialRevision(rawValue: "credential-1")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-1")!,
            status: status,
            lastSuccessfulAt: status == .complete ? date : nil,
            failureDetail: nil
        )
    }

    var scope: SynchronizationScope {
        .init(
            accountID: account.id,
            organizationID: organization.id,
            credentialRevision: CredentialRevision(rawValue: "credential-1")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability-1")!
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line,
    verify: ((Error) -> Void)? = nil
) async {
    do {
        try await expression()
        XCTFail("Expected error.", file: file, line: line)
    } catch {
        verify?(error)
    }
}

private enum OneShotDiscussionResult: Sendable {
    case data(Data)
    case response(Data, [String: String])
    case cancellation
}

private actor OneShotDiscussionSession: HTTPSession {
    private let result: OneShotDiscussionResult

    init(_ result: OneShotDiscussionResult) {
        self.result = result
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let headers: [String: String]?
        switch result {
        case let .data(value):
            data = value
            headers = nil
        case let .response(value, responseHeaders):
            data = value
            headers = responseHeaders
        case .cancellation:
            throw CancellationError()
        }
        return (
            data,
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers
            )!
        )
    }
}

private actor RevisionRotatingDiscussionSession: HTTPSession {
    private let accounts: AccountRepository
    private let account: GitHubAccount
    private let credentialRevision: CredentialRevision

    init(accounts: AccountRepository, account: GitHubAccount, credentialRevision: CredentialRevision) {
        self.accounts = accounts
        self.account = account
        self.credentialRevision = credentialRevision
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await accounts.save(account, credentialRevision: credentialRevision)
        throw URLError(.cannotConnectToHost)
    }
}

private func discussionInventoryResponse() -> Data {
    Data("""
    {"data":{"node":{"id":"R_1","discussions":{"nodes":[{"id":"D_1","number":1,"title":"Discussion","body":null,"url":"https://github.com/acme/repo/discussions/1","createdAt":"1970-01-01T00:16:40Z","updatedAt":"1970-01-01T00:16:40Z","closedAt":null,"isAnswered":false,"category":null,"answer":null,"comments":{"totalCount":0}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}},"rateLimit":{"cost":1,"remaining":4999,"resetAt":"2026-01-02T00:00:00Z"}}}
    """.utf8)
}

private func projectItemsInventoryResponse(itemID: String) -> Data {
    Data("""
    {"data":{"node":{"id":"P_1","items":{"nodes":[{"id":"\(itemID)","type":"REDACTED","updatedAt":"1970-01-01T00:16:40Z","content":null}],"pageInfo":{"hasNextPage":false,"endCursor":null}}},"rateLimit":{"cost":1,"remaining":4999,"resetAt":"2026-01-02T00:00:00Z"}}}
    """.utf8)
}

private func projectItemEmptyFieldValuesResponse(itemID: String) -> Data {
    Data("""
    {"data":{"node":{"id":"\(itemID)","fieldValues":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}},"rateLimit":{"cost":1,"remaining":4998,"resetAt":"2026-01-02T00:00:00Z"}}}
    """.utf8)
}

private actor ProjectItemSequenceSession: HTTPSession {
    private var responses: [Data]

    init(responses: [Data]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !responses.isEmpty else { throw URLError(.resourceUnavailable) }
        return (
            responses.removeFirst(),
            HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}
