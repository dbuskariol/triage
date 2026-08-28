import XCTest
@testable import Triage

final class GitHubSSOHeaderTests: XCTestCase {
    func testParsesGitHubProvidedAuthorizationURL() {
        let header = GitHubSSOHeader(
            value: "required; url=https://github.com/orgs/acme/sso?authorization_request=opaque"
        )

        XCTAssertEqual(
            header,
            .authorizationRequired(
                URL(string: "https://github.com/orgs/acme/sso?authorization_request=opaque")!
            )
        )
    }

    func testParsesPartialResultsOrganizationIDs() {
        XCTAssertEqual(
            GitHubSSOHeader(value: "partial-results; organizations=21955855,20582480"),
            .partialResults(Set([21_955_855, 20_582_480]))
        )
    }

    func testRejectsUntrustedAndMalformedHeaders() {
        XCTAssertNil(GitHubSSOHeader(value: nil))
        XCTAssertEqual(GitHubSSOHeader(value: "required; url=https://example.com/sso"), .malformed)
        XCTAssertEqual(GitHubSSOHeader(value: "partial-results; organizations=abc"), .malformed)
        XCTAssertEqual(GitHubSSOHeader(value: "unknown"), .malformed)
    }
}
