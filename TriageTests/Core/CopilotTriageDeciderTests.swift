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

private actor FakeTriageHelper: TriageCopilotHelping {
    private let login: String
    private let dropLastDecision: Bool
    private var failNextTriage: Bool
    private var authenticateCount = 0
    private(set) var triageRequestIDs: [UUID] = []

    init(login: String = "me", failFirstTriageWithMissingSession: Bool = false, dropLastDecision: Bool = false) {
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
        return CopilotAuthenticationResponse(
            header: .init(requestID: request.header.requestID, accountID: request.header.accountID,
                          organizationID: request.header.organizationID, status: .authentication),
            authentication: .init(host: "github.com", login: login, authenticationType: "token", isAuthenticated: true)
        )
    }

    func triage(_ request: CopilotTriageRequest) async throws -> CopilotTriageResponse {
        triageRequestIDs.append(request.header.requestID)
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
}
