import XCTest
@testable import Triage

final class GitHubDiagnosticsTests: XCTestCase {
    func testClassifierExposesOnlySafeResponseMetadata() {
        let failure = GitHubFailureClassifier.classify(
            response(status: 403, headers: [
                "X-GitHub-Request-Id": "request-id",
                "Retry-After": "60",
                "X-GitHub-SSO": "required; url=https://github.com/orgs/acme/sso"
            ])
        )

        XCTAssertEqual(failure?.kind, .secondaryRateLimited)
        XCTAssertEqual(failure?.statusCode, 403)
        XCTAssertEqual(failure?.requestID, "request-id")
        XCTAssertEqual(failure?.retryAfter, 60)
    }

    func testClassifierClassifiesRateLimitsAndAuthentication() {
        XCTAssertEqual(
            GitHubFailureClassifier.classify(response(status: 401))?.kind,
            .unauthorized
        )
        XCTAssertEqual(
            GitHubFailureClassifier.classify(response(status: 429))?.kind,
            .rateLimited
        )
        XCTAssertEqual(
            GitHubFailureClassifier.classify(response(status: 503))?.kind,
            .serverFailure
        )
        XCTAssertNil(GitHubFailureClassifier.classify(response(status: 200)))
    }

    private func response(
        status: Int,
        headers: [String: String] = [:]
    ) -> GitHubRESTResponse {
        GitHubRESTResponse(
            statusCode: status,
            url: URL(string: "https://api.github.com/user")!,
            headers: headers,
            body: Data("{\"message\":\"private content\"}".utf8)
        )
    }
}
