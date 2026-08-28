import XCTest
@testable import Triage

final class OrganizationAccessEvaluatorTests: XCTestCase {
    func testSSOHeadersOverrideAmbiguousForbiddenStatus() {
        XCTAssertEqual(
            OrganizationAccessEvaluator.state(
                statusCode: 403,
                ssoHeader: .authorizationRequired(URL(string: "https://github.com/orgs/acme/sso")!)
            ),
            .ssoAuthorizationRequired
        )
        XCTAssertEqual(
            OrganizationAccessEvaluator.state(
                statusCode: 200,
                ssoHeader: .partialResults(Set([1]))
            ),
            .partialSSOAuthorization
        )
    }

    func testHTTPFailuresRemainExplicit() {
        XCTAssertEqual(OrganizationAccessEvaluator.state(statusCode: 200, ssoHeader: nil), .available)
        XCTAssertEqual(OrganizationAccessEvaluator.state(statusCode: 401, ssoHeader: nil), .credentialExpired)
        XCTAssertEqual(OrganizationAccessEvaluator.state(statusCode: 404, ssoHeader: nil), .inaccessible)
    }
}
