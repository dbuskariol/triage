import XCTest
@testable import Triage

final class IdentifierTests: XCTestCase {
    func testOpaqueIdentifiersRejectEmptyAndWhitespace() {
        XCTAssertNil(AccountID(rawValue: ""))
        XCTAssertNil(OrganizationID(rawValue: "octo cat"))
        XCTAssertNil(GitHubNodeID(rawValue: "\nnode"))
        XCTAssertNotNil(RepositoryID(rawValue: "R_kgDOExample"))
    }

    func testGeneratedIdentifiersAreDistinctAndValid() {
        XCTAssertNotEqual(AccountID.make(), AccountID.make())
        XCTAssertNotEqual(WorkItemID.make(), WorkItemID.make())
        XCTAssertNotEqual(ActionItemID.make(), ActionItemID.make())
        XCTAssertNotEqual(AIRequestID.make(), AIRequestID.make())
    }

    func testPKCEVerifierValidatesRFC7636CharacterAndLengthRequirements() {
        XCTAssertNotNil(OAuthCodeVerifier(rawValue: String(repeating: "a", count: 43)))
        XCTAssertNotNil(OAuthCodeVerifier(rawValue: String(repeating: "~", count: 128)))
        XCTAssertNil(OAuthCodeVerifier(rawValue: String(repeating: "a", count: 42)))
        XCTAssertNil(OAuthCodeVerifier(rawValue: String(repeating: "a", count: 129)))
        XCTAssertNil(OAuthCodeVerifier(rawValue: String(repeating: "a ", count: 43)))
    }

    func testSensitiveValuesRedactTheirDescriptions() {
        XCTAssertEqual(SecretValue("token").description, "<redacted>")
        XCTAssertEqual(
            OAuthCodeVerifier(rawValue: String(repeating: "a", count: 43))!.description,
            "<redacted OAuth PKCE verifier>"
        )
    }
}
