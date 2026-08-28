import XCTest
@testable import Triage

final class GitHubSearchNormalizerTests: XCTestCase {
    func testNormalizesPullRequestDiscoveryWithStableRevision() throws {
        let updatedAt = Date(timeIntervalSince1970: 1_000)
        let item = GitHubIssueSearchItem(
            id: 1,
            nodeID: "I_kwDOExample",
            number: 42,
            title: "Fix Triage",
            state: "open",
            htmlURL: URL(string: "https://github.com/octo/repo/pull/42")!,
            createdAt: Date(timeIntervalSince1970: 900),
            updatedAt: updatedAt,
            closedAt: nil,
            pullRequest: .init(url: nil)
        )

        let node = try GitHubSearchNormalizer.normalize(
            item,
            accountID: AccountID(rawValue: "account")!,
            organizationID: OrganizationID(rawValue: "organization")!,
            repositoryID: nil,
            observedAt: updatedAt
        )

        XCTAssertEqual(node.kind, .pullRequest)
        XCTAssertEqual(node.state, .open)
        XCTAssertEqual(node.sourceRevision, updatedAt.ISO8601Format())
    }
}
