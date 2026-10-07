import Foundation
import XCTest
@testable import Triage

final class GRDBTriageStoreTests: XCTestCase {
    func testReplaceDeactivatesAndOrdersItemsNeedingAnalysis() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let first = item(id: "first", relationship: .assigned, updatedAt: Date(timeIntervalSince1970: 100))
        let second = item(id: "second", relationship: .reviewRequested, updatedAt: Date(timeIntervalSince1970: 50))

        try await fixture.store.replaceItems([first, second], scope: fixture.scope, at: Date(timeIntervalSince1970: 200))
        let initial = try await fixture.store.itemsNeedingAnalysis(scope: fixture.scope, rulesDigest: "", at: Date(), limit: 10)
        XCTAssertEqual(initial.map(\.id), [second.id, first.id])

        try await fixture.store.replaceItems([first], scope: fixture.scope, at: Date(timeIntervalSince1970: 201))
        let replacement = try await fixture.store.itemsNeedingAnalysis(scope: fixture.scope, rulesDigest: "", at: Date(), limit: 10)
        XCTAssertEqual(replacement.map(\.id), [first.id])
    }

    func testDecisionFailureAndLocalStateFollowCurrentFingerprint() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let work = item(id: "item", relationship: .assigned, updatedAt: Date())
        try await fixture.store.replaceItems([work], scope: fixture.scope, at: Date())

        try await fixture.store.recordAnalysisFailure(
            itemIDs: [work.id], reason: "unavailable", retryAt: .distantFuture, scope: fixture.scope
        )
        let gated = try await fixture.store.itemsNeedingAnalysis(scope: fixture.scope, rulesDigest: "", at: Date(), limit: 10)
        XCTAssertTrue(gated.isEmpty)

        let decision = TriageDecision(
            itemID: work.id, disposition: .act, priority: 100, confidence: 1,
            summary: "Summary.", reason: "Reason.", nextAction: "Act.",
            fingerprint: work.fingerprint, modelID: "test", decidedAt: Date()
        )
        try await fixture.store.saveDecisions([decision], scope: fixture.scope)
        let decided = try await fixture.store.itemsNeedingAnalysis(scope: fixture.scope, rulesDigest: "", at: Date(), limit: 10)
        XCTAssertTrue(decided.isEmpty)

        try await fixture.store.setLocalStatus(.done(fingerprint: work.fingerprint), itemID: work.id, scope: fixture.scope)
        let stream = try await fixture.store.entries(scope: fixture.scope)
        var iterator = stream.makeAsyncIterator()
        let next = try await iterator.next()
        let entry = try XCTUnwrap(next)
        XCTAssertEqual(entry.first?.analysis, .current)
        XCTAssertEqual(entry.first?.local, .done(fingerprint: work.fingerprint))
        XCTAssertFalse(entry.first!.isVisible(at: Date()))
    }

    func testEntriesStreamPublishesDecisionsSavedAfterSubscription() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let work = item(id: "item", relationship: .assigned, updatedAt: Date())
        try await fixture.store.replaceItems([work], scope: fixture.scope, at: Date())

        let stream = try await fixture.store.entries(scope: fixture.scope)
        let collector = Task { () -> [[AnalysisState]] in
            var values: [[AnalysisState]] = []
            for try await entries in stream {
                values.append(entries.map(\.analysis))
                if values.count == 2 { break }
            }
            return values
        }
        try await Task.sleep(for: .milliseconds(300))
        try await fixture.store.saveDecisions([TriageDecision(
            itemID: work.id, disposition: .act, priority: 90, confidence: 1,
            summary: "Summary.", reason: "Reason.", nextAction: nil,
            fingerprint: work.fingerprint, modelID: "test", decidedAt: Date()
        )], scope: fixture.scope)
        try await Task.sleep(for: .seconds(2))
        collector.cancel()
        let values = try await collector.value
        XCTAssertEqual(values, [[.pending], [.current]])
    }

    func testRulesPersistPerOrganizationAndStaleDigestReanalyzes() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let rules = TriageRules(instructions: "Security first.", rules: [.quick(.mute, .author, "bot")])
        try await fixture.store.saveRules(rules, scope: fixture.scope)
        let saved = try await fixture.store.rules(scope: fixture.scope)
        XCTAssertEqual(saved, rules)
        let other = WorkspaceScope(
            accountID: fixture.scope.accountID, organizationID: OrganizationID(rawValue: "other")!,
            organizationLogin: "other", viewerLogin: "me"
        )
        let otherRules = try await fixture.store.rules(scope: other)
        XCTAssertEqual(otherRules, .empty)

        let work = item(id: "item", relationship: .assigned, updatedAt: Date())
        try await fixture.store.replaceItems([work], scope: fixture.scope, at: Date())
        try await fixture.store.saveDecisions([TriageDecision(
            itemID: work.id, disposition: .act, priority: 90, confidence: 1, summary: "s", reason: "r",
            nextAction: nil, fingerprint: work.fingerprint, modelID: "m", decidedAt: Date(), rulesDigest: rules.digest
        )], scope: fixture.scope)
        let current = try await fixture.store.itemsNeedingAnalysis(scope: fixture.scope, rulesDigest: rules.digest, at: Date(), limit: 10)
        XCTAssertTrue(current.isEmpty)
        let stale = try await fixture.store.itemsNeedingAnalysis(scope: fixture.scope, rulesDigest: "changed", at: Date(), limit: 10)
        XCTAssertEqual(stale.map(\.id), [work.id])
    }

    func testMarkHandledNeverOverridesAStatusYouSet() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let work = item(id: "item", relationship: .assigned, updatedAt: Date())
        try await fixture.store.replaceItems([work], scope: fixture.scope, at: Date())
        let marked = try await fixture.store.markHandled(
            itemID: work.id, fingerprint: work.fingerprint, evidence: "You replied.", at: Date(), scope: fixture.scope
        )
        XCTAssertTrue(marked)
        let again = try await fixture.store.markHandled(
            itemID: work.id, fingerprint: work.fingerprint, evidence: "Other.", at: Date(), scope: fixture.scope
        )
        XCTAssertFalse(again)
        var iterator = try await fixture.store.entries(scope: fixture.scope).makeAsyncIterator()
        let entries = try await iterator.next()
        XCTAssertEqual(entries?.first?.handledEvidence, "You replied.")
    }

    private func makeFixture() async throws -> (directory: URL, store: GRDBTriageStore, scope: WorkspaceScope) {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".triage-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let accountID = AccountID.make()
        let vault = try await VaultRegistry(rootDirectory: directory).open(accountID: accountID, vaultKey: VaultKey.generate())
        let account = GitHubAccount(
            id: accountID, githubUserID: 1, nodeID: GitHubNodeID(rawValue: "account-node")!,
            login: "me", authenticationKind: .oauth, credentialID: CredentialID(rawValue: "credential")!,
            credentialStatus: .active, createdAt: Date()
        )
        try await AccountRepository(vault: vault).save(
            account, credentialRevision: CredentialRevision(rawValue: "revision")!
        )
        return (
            directory,
            GRDBTriageStore(vault: vault),
            WorkspaceScope(
                accountID: accountID, organizationID: OrganizationID(rawValue: "org")!,
                organizationLogin: "octo", viewerLogin: "me"
            )
        )
    }

    private func item(id: String, relationship: WorkRelationship, updatedAt: Date) -> PersonalWorkItem {
        PersonalWorkItem(
            id: GitHubNodeID(rawValue: id)!, kind: .issue, repository: "octo/repo", number: 1,
            title: id, url: URL(string: "https://example.com/\(id)")!, state: .open, author: "other",
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: updatedAt, relationships: [relationship],
            labels: [], assignees: [], body: "", pullRequest: nil, recentActivity: []
        )
    }
}
