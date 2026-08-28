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

    func testClassifierExtractsOnlyExplicitAccessRestrictions() {
        XCTAssertEqual(
            GitHubFailureClassifier.classify(
                response(status: 403, body: #"{"message":"Blocked due to organization policy"}"#)
            )?.accessRestriction,
            .organizationPolicyBlocked
        )
        XCTAssertEqual(
            GitHubFailureClassifier.classify(
                response(
                    status: 403,
                    body: #"{"message":"This organization has enabled OAuth App access restrictions."}"#
                )
            )?.accessRestriction,
            .oauthApplicationApprovalRequired
        )
        XCTAssertEqual(
            GitHubFailureClassifier.classify(
                response(
                    status: 403,
                    body: #"{"message":"This fine-grained personal access token has pending approval."}"#
                )
            )?.accessRestriction,
            .organizationApprovalRequired
        )
        XCTAssertNil(
            GitHubFailureClassifier.classify(
                response(
                    status: 403,
                    body: #"{"message":"Resource not accessible by personal access token"}"#
                )
            )?.accessRestriction
        )
    }

    private func response(
        status: Int,
        headers: [String: String] = [:],
        body: String = #"{"message":"private content"}"#
    ) -> GitHubRESTResponse {
        GitHubRESTResponse(
            statusCode: status,
            url: URL(string: "https://api.github.com/user")!,
            headers: headers,
            body: Data(body.utf8)
        )
    }
}
