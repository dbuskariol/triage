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
        XCTAssertEqual(OrganizationAccessEvaluator.state(statusCode: 403, ssoHeader: nil), .insufficientPermission)
        XCTAssertEqual(OrganizationAccessEvaluator.state(statusCode: 429, ssoHeader: nil), .unknown)
        XCTAssertEqual(OrganizationAccessEvaluator.state(statusCode: 500, ssoHeader: nil), .unknown)
    }

    func testExplicitRestrictionsAreClassifiedWithoutGuessingGenericForbiddenResponses() {
        XCTAssertEqual(
            OrganizationAccessEvaluator.state(
                statusCode: 403,
                ssoHeader: nil,
                accessRestriction: .organizationApprovalRequired
            ),
            .organizationApprovalRequired
        )
        XCTAssertEqual(
            OrganizationAccessEvaluator.state(
                statusCode: 403,
                ssoHeader: nil,
                accessRestriction: .oauthApplicationApprovalRequired
            ),
            .oauthApplicationApprovalRequired
        )
        XCTAssertEqual(
            OrganizationAccessEvaluator.state(
                statusCode: 403,
                ssoHeader: nil,
                accessRestriction: .organizationPolicyBlocked
            ),
            .organizationPolicyBlocked
        )
        XCTAssertEqual(
            OrganizationAccessEvaluator.state(statusCode: 403, ssoHeader: nil),
            .insufficientPermission
        )
    }

    func testSSORequirementTakesPrecedenceOverAnAccessRestriction() {
        XCTAssertEqual(
            OrganizationAccessEvaluator.state(
                statusCode: 403,
                ssoHeader: .authorizationRequired(URL(string: "https://github.com/orgs/acme/sso")!),
                accessRestriction: .organizationPolicyBlocked
            ),
            .ssoAuthorizationRequired
        )
    }

    func testMalformedSSOHeaderDoesNotImplyAnAccessDecision() {
        XCTAssertEqual(
            OrganizationAccessEvaluator.state(statusCode: 200, ssoHeader: .malformed),
            .unknown
        )
    }
}
