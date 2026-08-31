import Foundation
import XCTest
@testable import Triage

final class WorkDetailRepositoryTests: XCTestCase {
    func testSourceReturnsOnlyExactAccountOrganizationAndPrimaryNodeWithMetadata() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = WorkDetailRepository(vault: fixture.vault)

        let source = try await repository.source(for: fixture.item)

        XCTAssertEqual(source?.bodyMarkdown, "Authoritative **local** body")
        XCTAssertEqual(source?.sourceRevision, "source-r1")
        XCTAssertEqual(source?.updatedAt, fixture.updatedAt)
        XCTAssertEqual(source?.observedAt, fixture.observedAt)
        let foreignAccount = try await repository.source(
            for: fixture.scopedItem(replacingAccountID: AccountID.make())
        )
        let foreignOrganization = try await repository.source(
            for: fixture.scopedItem(replacingOrganizationID: OrganizationID(rawValue: "foreign")!)
        )
        let foreignNode = try await repository.source(
            for: fixture.scopedItem(replacingPrimaryNodeID: GitHubNodeID(rawValue: "foreign-node")!)
        )
        XCTAssertNil(foreignAccount)
        XCTAssertNil(foreignOrganization)
        XCTAssertNil(foreignNode)
    }

    func testTimelineUsesStableLimitPlusOneCursorWithoutRepeats() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.saveTimeline(id: "event-a", seconds: 1, body: "First")
        try await fixture.saveTimeline(id: "event-b", seconds: 1, body: "Second")
        try await fixture.saveTimeline(id: "event-c", seconds: 2, body: "Third")
        let repository = WorkDetailRepository(vault: fixture.vault)

        let first = try await repository.timelinePage(for: fixture.item, after: nil, limit: 2)
        let second = try await repository.timelinePage(for: fixture.item, after: first.nextCursor, limit: 2)

        XCTAssertEqual(first.entries.map(\.id.rawValue), ["event-a", "event-b"])
        XCTAssertEqual(first.nextCursor?.eventID.rawValue, "event-b")
        XCTAssertEqual(second.entries.map(\.id.rawValue), ["event-c"])
        XCTAssertNil(second.nextCursor)
        XCTAssertEqual(first.entries.map(\.sourceRevision), ["timeline-event-a", "timeline-event-b"])
    }

    func testTimelineRejectsPayloadWhoseAuthorityDoesNotMatchStoredSubject() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let invalid = TimelineEventSummary(
            id: GitHubEventID(rawValue: "invalid-event")!,
            subjectNodeID: GitHubNodeID(rawValue: "other-node")!,
            kind: .commented,
            actor: nil,
            occurredAt: fixture.updatedAt,
            url: nil,
            body: "Untrusted"
        )
        try await fixture.vault.write { database in
            try database.execute(
                sql: """
                    INSERT INTO timeline_events (
                        github_event_id, subject_node_id, actor_id, kind, occurred_at_ms, payload_json, source_revision
                    ) VALUES (?, ?, NULL, ?, ?, ?, ?)
                    """,
                arguments: [
                    invalid.id.rawValue,
                    fixture.nodeID.rawValue,
                    invalid.kind.rawValue,
                    Int64((invalid.occurredAt.timeIntervalSince1970 * 1_000).rounded()),
                    try JSONEncoder().encode(invalid),
                    "invalid-r1"
                ]
            )
        }

        do {
            _ = try await WorkDetailRepository(vault: fixture.vault).timelinePage(for: fixture.item, after: nil, limit: 1)
            XCTFail("Expected mismatched timeline payload authority to be rejected.")
        } catch {
            XCTAssertEqual(error as? WorkDetailRepositoryError, .invalidTimelineRecord)
        }
    }

    func testCancelledReadFailsBeforeOpeningLocalDetailQuery() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = WorkDetailRepository(vault: fixture.vault)
        let gate = CancellationGate()
        let task = Task {
            await gate.wait()
            return try await repository.timelinePage(for: fixture.item, after: nil, limit: 1)
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected: a detail view that disappears must not apply a page.
        }
    }
}

private actor CancellationGate {
    private var isOpen = false
    private var entered: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        entered?.resume()
        entered = nil
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func waitUntilEntered() async {
        guard waiter == nil else { return }
        await withCheckedContinuation { entered = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

private final class Fixture: @unchecked Sendable {
    let directory: URL
    let vault: AccountVault
    let accountID = AccountID.make()
    let organizationID = OrganizationID(rawValue: "organization")!
    let nodeID = GitHubNodeID(rawValue: "primary-node")!
    let updatedAt = Date(timeIntervalSinceReferenceDate: 1_000)
    let observedAt = Date(timeIntervalSinceReferenceDate: 1_100)
    let item: WorkItem

    init() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-detail-\(UUID().uuidString)", isDirectory: true)
        vault = try await VaultRegistry(rootDirectory: directory).open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        let account = GitHubAccount(
            id: accountID,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "account-node")!,
            login: "account",
            authenticationKind: .oauth,
            credentialID: CredentialID.make(),
            credentialStatus: .active,
            createdAt: updatedAt
        )
        let organization = GitHubOrganization(
            id: organizationID,
            githubOrganizationID: 2,
            nodeID: GitHubNodeID(rawValue: "organization-node")!,
            login: "organization"
        )
        try await AccountRepository(vault: vault).save(account, credentialRevision: CredentialRevision(rawValue: "credential-r1")!)
        try await AccountRepository(vault: vault).save(
            organization,
            access: OrganizationAccess(
                accountID: accountID,
                organizationID: organizationID,
                state: .available,
                capabilityRevision: CapabilityRevision(rawValue: "capability-r1")!,
                capabilities: [],
                checkedAt: updatedAt
            ),
            selectedAt: updatedAt
        )
        let node = NormalizedGitHubNode(
            nodeID: nodeID,
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: nil,
            kind: .issue,
            numericID: "1",
            number: 1,
            title: "Local detail",
            state: .open,
            url: URL(string: "https://github.com/organization/repository/issues/1")!,
            bodyMarkdown: "Authoritative **local** body",
            authorID: nil,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            closedAt: nil,
            mergedAt: nil,
            sourceRevision: "source-r1",
            observedAt: observedAt,
            accessibility: .accessible
        )
        // `ensureWorkItem` intentionally assumes its normalized primary node
        // is already persisted by the synchronization boundary. Seed that
        // production invariant so the work-item FK is valid under SQLCipher.
        try await GitHubNodeRepository(vault: vault).save(node)
        let workItems = WorkItemRepository(vault: vault)
        let workItemID = try await workItems.ensureWorkItem(for: node)
        guard let item = try await workItems.fetch(accountID: accountID, organizationID: organizationID)
            .first(where: { $0.id == workItemID })
        else { throw FixtureError.missingWorkItem }
        self.item = item
    }

    func saveTimeline(id: String, seconds: TimeInterval, body: String) async throws {
        try await TimelineRepository(vault: vault).save(
            TimelineEventSummary(
                id: GitHubEventID(rawValue: id)!,
                subjectNodeID: nodeID,
                kind: .commented,
                actor: nil,
                occurredAt: updatedAt.addingTimeInterval(seconds),
                url: nil,
                body: body
            ),
            sourceRevision: "timeline-\(id)"
        )
    }

    func scopedItem(
        replacingAccountID accountID: AccountID? = nil,
        replacingOrganizationID organizationID: OrganizationID? = nil,
        replacingPrimaryNodeID primaryNodeID: GitHubNodeID? = nil
    ) -> WorkItem {
        WorkItem(
            id: item.id,
            accountID: accountID ?? item.accountID,
            organizationID: organizationID ?? item.organizationID,
            primaryNodeID: primaryNodeID ?? item.primaryNodeID,
            title: item.title,
            state: item.state,
            sourceKind: item.sourceKind,
            sourceURL: item.sourceURL,
            repository: item.repository,
            members: item.members,
            contextLinks: item.contextLinks,
            relations: item.relations,
            attentionReasons: item.attentionReasons,
            actionItems: item.actionItems,
            workflow: item.workflow,
            freshness: item.freshness,
            lastRelevantActivityAt: item.lastRelevantActivityAt,
            score: item.score
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private enum FixtureError: Error { case missingWorkItem }
}
