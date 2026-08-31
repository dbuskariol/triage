import Foundation
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
