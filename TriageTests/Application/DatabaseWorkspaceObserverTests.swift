import Foundation
import XCTest
@testable import Triage

final class DatabaseWorkspaceObserverTests: XCTestCase {
    func testSnapshotsRejectsAVaultResolvedForAnotherAccount() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let expectedAccountID = AccountID(rawValue: "expected-account")!
        let resolvedAccountID = AccountID(rawValue: "resolved-account")!
        let vault = try AccountVault(
            accountID: resolvedAccountID,
            vaultKey: VaultKey.generate(),
            rootDirectory: directory
        )
        let observer = DatabaseWorkspaceObserver(resolveVault: { _ in vault })
        let scope = SynchronizationScope(
            accountID: expectedAccountID,
            organizationID: OrganizationID(rawValue: "organization")!,
            credentialRevision: CredentialRevision(rawValue: "credential")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability")!
        )

        do {
            _ = try await observer.snapshots(for: scope)
            XCTFail("Expected a mismatched account vault to be rejected.")
        } catch {
            XCTAssertEqual(
                error as? DatabaseWorkspaceObserverError,
                .resolvedVaultAccountMismatch
            )
        }

        try await vault.close()
        try FileManager.default.removeItem(at: directory)
    }

    func testMenuCountsPreserveObservedSectionsAndFillRemainingDispositions() throws {
        let accountID = AccountID(rawValue: "account")!
        let organizationID = OrganizationID(rawValue: "organization")!
        let now = Date(timeIntervalSince1970: 10_000)
        let items = [
            workItem(id: "inbox", accountID: accountID, organizationID: organizationID, pinned: true, now: now),
            workItem(id: "waiting", accountID: accountID, organizationID: organizationID, status: .waiting, now: now),
            workItem(id: "snoozed", accountID: accountID, organizationID: organizationID, snoozedUntil: now.addingTimeInterval(60), now: now),
            workItem(id: "archived", accountID: accountID, organizationID: organizationID, status: .archived, now: now),
            workItem(id: "resolved", accountID: accountID, organizationID: organizationID, state: .resolved, now: now),
            workItem(id: "informational", accountID: accountID, organizationID: organizationID, now: now),
            workItem(id: "inaccessible", accountID: accountID, organizationID: organizationID, state: .inaccessible, now: now)
        ]

        let counts = try DatabaseWorkspaceObserver.menuCounts(
            observed: WorkspaceMenuCounts(
                inbox: 1,
                myWork: 2,
                reviews: 3,
                waiting: 1,
                snoozed: 1,
                allWork: 7
            ),
            workItems: items,
            at: now
        )

        XCTAssertEqual(counts.inbox, 1)
        XCTAssertEqual(counts.waiting, 1)
        XCTAssertEqual(counts.snoozed, 1)
        XCTAssertEqual(counts.archived, 1)
        XCTAssertEqual(counts.resolved, 1)
        XCTAssertEqual(counts.informational, 1)
        XCTAssertEqual(counts.inaccessible, 1)
        XCTAssertEqual(counts.myWork, 2)
        XCTAssertEqual(counts.reviews, 3)
        XCTAssertEqual(counts.allWork, 7)
    }

    func testMenuCountsRejectsARevisionThatCannotBeReconciled() {
        let accountID = AccountID(rawValue: "account")!
        let organizationID = OrganizationID(rawValue: "organization")!
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertThrowsError(
            try DatabaseWorkspaceObserver.menuCounts(
                observed: WorkspaceMenuCounts(
                    inbox: 1,
                    myWork: 0,
                    reviews: 0,
                    waiting: 0,
                    snoozed: 0,
                    allWork: 2
                ),
                workItems: [workItem(id: "only", accountID: accountID, organizationID: organizationID, now: now)],
                at: now
            )
        ) { error in
            XCTAssertEqual(error as? DatabaseWorkspaceObserverError, .inconsistentMenuCounts)
        }
    }

    private func workItem(
        id: String,
        accountID: AccountID,
        organizationID: OrganizationID,
        state: WorkItemState = .active,
        status: LocalWorkStatus = .active,
        pinned: Bool = false,
        snoozedUntil: Date? = nil,
        now: Date
    ) -> WorkItem {
        WorkItem(
            id: WorkItemID(rawValue: id)!,
            accountID: accountID,
            organizationID: organizationID,
            primaryNodeID: GitHubNodeID(rawValue: "node-\(id)")!,
            title: id,
            state: state,
            sourceKind: .issue,
            sourceURL: URL(string: "https://example.com/\(id)"),
            repository: nil,
            members: [],
            contextLinks: [],
            relations: [],
            attentionReasons: [],
            actionItems: [],
            workflow: WorkflowState(
                status: status,
                isPinned: pinned,
                snoozedUntil: snoozedUntil,
                updatedAt: now
            ),
            freshness: FreshnessState(status: .fresh),
            lastRelevantActivityAt: now,
            score: AttentionScore(value: 0, breakdown: [:])
        )
    }
}
