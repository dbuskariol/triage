import XCTest
@testable import Triage

final class GitHubIssueSearchTests: XCTestCase {
    func testBuildsRoleQualifiedOpenSearch() throws {
        let query = try GitHubIssueSearchQuery(
            organizationLogin: "github",
            userLogin: "octocat",
            state: .open,
            relationship: .reviewRequested
        )

        XCTAssertEqual(
            query.value,
            "org:github is:open review-requested:octocat"
        )
    }

    func testSearchRejectsUntrustedQualifierInputs() {
        XCTAssertThrowsError(
            try GitHubIssueSearchQuery(
                organizationLogin: "github org",
                userLogin: "octocat",
                state: .open,
                relationship: .involves
            )
        )
        XCTAssertThrowsError(
            try GitHubIssueSearchQuery(
                organizationLogin: "github",
                userLogin: "octocat is:closed",
                state: .open,
                relationship: .involves
            )
        )
    }
}
