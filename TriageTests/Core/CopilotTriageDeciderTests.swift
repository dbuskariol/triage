import Foundation
import XCTest
@testable import Triage

final class CopilotTriageDeciderTests: XCTestCase {
    func testAuthenticatesOnceAndReusesTheSessionAcrossBatches() async throws {
        let helper = FakeTriageHelper()
        let decider = makeDecider(helper)

        _ = try await decider.decide([deciderItem("A")], scope: deciderScope, rules: .empty)
        _ = try await decider.decide([deciderItem("B")], scope: deciderScope, rules: .empty)

        let counts = await helper.counts
        XCTAssertEqual(counts.authenticate, 1)
        XCTAssertEqual(counts.triage, 2)
    }

    func testMissingSessionReauthenticatesOnceWithAFreshRequest() async throws {
        let helper = FakeTriageHelper(failFirstTriageWithMissingSession: true)
        let decider = makeDecider(helper)

        let decisions = try await decider.decide([deciderItem("A")], scope: deciderScope, rules: .empty)

        XCTAssertEqual(decisions.map(\.itemID.rawValue), ["A"])
        let counts = await helper.counts
        XCTAssertEqual(counts.authenticate, 2)
        XCTAssertEqual(counts.triage, 2)
        let requestIDs = await helper.triageRequestIDs
        XCTAssertEqual(Set(requestIDs).count, 2)
    }

    func testDroppedConnectionReconnectsOnceWithAFreshHelper() async throws {
        let broken = FakeTriageHelper(failAuthenticateWith: .helperUnavailable)
        let healthy = FakeTriageHelper()
        let helpers = HelperQueue([broken, healthy])
        let decider = CopilotTriageDecider(
            makeHelper: { helpers.next() },
            authorize: { _ in CopilotTriageAuthorization(isConsentGranted: true, selectedModelID: nil) }
        )
        let decisions = try await decider.decide([deciderItem("A")], scope: deciderScope, rules: .empty)
        XCTAssertEqual(decisions.map(\.itemID.rawValue), ["A"])
        let counts = await healthy.counts
        XCTAssertEqual(counts.triage, 1)
    }

    func testLongCommentsAreKeptWholeButClippedForCopilot() async throws {
        let helper = FakeTriageHelper()
        let comment = String(repeating: "word ", count: 400)
        var item = deciderItem("A")
        item = PersonalWorkItem(
            id: item.id, kind: item.kind, repository: item.repository, number: item.number, title: item.title,
            url: item.url, state: item.state, author: item.author, createdAt: item.createdAt, updatedAt: item.updatedAt,
            relationships: item.relationships, labels: [], assignees: [], body: "", pullRequest: nil,
            recentActivity: [ActivityFact(author: "bob", createdAt: .now, excerpt: comment)]
        )
        _ = try await makeDecider(helper).decide([item], scope: deciderScope, rules: .empty)
        let request = await helper.lastTriage
        let sent = try XCTUnwrap(request?.items.first?.recentActivity.first?.excerpt)
        XCTAssertEqual(sent.utf8.count, CopilotTriageActivity.maximumExcerptBytes)
        XCTAssertTrue(comment.hasPrefix(sent))
        XCTAssertEqual(item.recentActivity.first?.excerpt, comment)
    }

    func testPartialResponseKeepsDecidedItems() async throws {
        let helper = FakeTriageHelper(dropLastDecision: true)
        let decisions = try await makeDecider(helper).decide([deciderItem("A"), deciderItem("B")], scope: deciderScope, rules: .empty)
        XCTAssertEqual(decisions.map(\.itemID.rawValue), ["A"])
    }

    func testDifferentSignedInUserPausesAnalysis() async {
        let helper = FakeTriageHelper(login: "someone-else")
        do {
            _ = try await makeDecider(helper).decide([deciderItem("A")], scope: deciderScope, rules: .empty)
            XCTFail("Expected sign-in error")
        } catch {
            XCTAssertEqual(error as? TriageDecisionError, .signInRequired)
            XCTAssertTrue(TriageDecisionError.signInRequired.pausesAnalysis)
        }
    }

    func testDraftSendsGoalAndStyleOnItsOwnSession() async throws {
        let helper = FakeTriageHelper()
        let writer = CopilotDraftWriter(
            makeHelper: { helper },
            authorize: { _ in CopilotTriageAuthorization(isConsentGranted: true, selectedModelID: nil) }
        )
        let draft = try await writer.draft(deciderItem("A"), goal: "Answer @bob", writingStyle: "  Brief.  ", scope: deciderScope)
        XCTAssertEqual(draft, "Thanks @bob, [ETA].")
        let request = await helper.lastDraft
        XCTAssertEqual(request?.goal, "Answer @bob")
        XCTAssertEqual(request?.writingStyle, "Brief.")
        XCTAssertEqual(request?.item.id, "A")
        let counts = await helper.counts
        XCTAssertEqual(counts.authenticate, 1)
    }

    func testDraftRequiresConsent() async {
        let writer = CopilotDraftWriter(
            makeHelper: { FakeTriageHelper() },
            authorize: { _ in CopilotTriageAuthorization(isConsentGranted: false, selectedModelID: nil) }
        )
        do {
            _ = try await writer.draft(deciderItem("A"), goal: nil, writingStyle: nil, scope: deciderScope)
            XCTFail("Expected consent error")
        } catch {
            XCTAssertEqual(error as? TriageDecisionError, .consentRequired)
        }
    }

    private func makeDecider(_ helper: FakeTriageHelper) -> CopilotTriageDecider {
        CopilotTriageDecider(
            makeHelper: { helper },
            authorize: { _ in CopilotTriageAuthorization(isConsentGranted: true, selectedModelID: nil) }
        )
    }
}

private let deciderScope = WorkspaceScope(
    accountID: AccountID(rawValue: "account")!, organizationID: OrganizationID(rawValue: "org")!,
    organizationLogin: "octo", viewerLogin: "me"
)

private func deciderItem(_ id: String) -> PersonalWorkItem {
    PersonalWorkItem(
        id: GitHubNodeID(rawValue: id)!, kind: .issue, repository: "octo/repo", number: 1,
        title: "Item \(id)", url: URL(string: "https://github.com/octo/repo/issues/1")!,
        state: .open, author: "octocat", createdAt: .now, updatedAt: .now,
        relationships: [.assigned], labels: [], assignees: [], body: "",
        pullRequest: nil, recentActivity: []
    )
}

/// Hands out helpers in order, like reconnecting after a dropped connection.
private final class HelperQueue: @unchecked Sendable {
    private var helpers: [FakeTriageHelper]
    private let lock = NSLock()
    init(_ helpers: [FakeTriageHelper]) { self.helpers = helpers }
    func next() -> any TriageCopilotHelping {
        lock.withLock { helpers.count > 1 ? helpers.removeFirst() : helpers[0] }
    }
}

private actor FakeTriageHelper: TriageCopilotHelping {
    private let login: String
    private let dropLastDecision: Bool
    private var failNextTriage: Bool
    private var authenticateCount = 0
    private(set) var triageRequestIDs: [UUID] = []
    private(set) var lastDraft: CopilotDraftRequest?
    private(set) var lastTriage: CopilotTriageRequest?

    private let failAuthenticateWith: CopilotXPCError?

    init(login: String = "me", failFirstTriageWithMissingSession: Bool = false, dropLastDecision: Bool = false,
         failAuthenticateWith: CopilotXPCError? = nil) {
        self.failAuthenticateWith = failAuthenticateWith
        self.login = login
        self.dropLastDecision = dropLastDecision
        failNextTriage = failFirstTriageWithMissingSession
    }

    var counts: (authenticate: Int, triage: Int) { (authenticateCount, triageRequestIDs.count) }

    func health(_: CopilotHealthRequest) async throws -> CopilotHealthResponse { throw CancellationError() }
    func models(_: CopilotModelsRequest) async throws -> CopilotModelsResponse { throw CancellationError() }
    func cancel(_: CopilotCancelRequest) async throws -> CopilotCancelResponse { throw CancellationError() }
    func shutdown(_: CopilotShutdownRequest) async throws -> CopilotShutdownResponse { throw CancellationError() }

    func authenticate(_ request: CopilotAuthenticateRequest) async throws -> CopilotAuthenticationResponse {
        authenticateCount += 1
        if let failAuthenticateWith { throw failAuthenticateWith }
        return CopilotAuthenticationResponse(
            header: .init(requestID: request.header.requestID, accountID: request.header.accountID,
                          organizationID: request.header.organizationID, status: .authentication),
            authentication: .init(host: "github.com", login: login, authenticationType: "token", isAuthenticated: true)
        )
    }

    func triage(_ request: CopilotTriageRequest) async throws -> CopilotTriageResponse {
        triageRequestIDs.append(request.header.requestID)
        lastTriage = request
        if failNextTriage {
            failNextTriage = false
            throw CopilotXPCError.runtimeUnavailable
        }
        return CopilotTriageResponse(
            header: .init(requestID: request.header.requestID, accountID: request.header.accountID,
                          organizationID: request.header.organizationID, status: .triage),
            modelID: "auto",
            decisions: request.items.dropLast(dropLastDecision ? 1 : 0).map {
                CopilotTriageItemDecision(id: $0.id, disposition: .review, priority: 50, confidence: 0.8,
                                          summary: "Summary", reason: "Reason", nextAction: "Next")
            }
        )
    }

    func draft(_ request: CopilotDraftRequest) async throws -> CopilotDraftResponse {
        lastDraft = request
        return CopilotDraftResponse(
            header: .init(requestID: request.header.requestID, accountID: request.header.accountID,
                          organizationID: request.header.organizationID, status: .draft),
            modelID: "auto",
            draft: "Thanks @bob, [ETA]."
        )
    }
}
