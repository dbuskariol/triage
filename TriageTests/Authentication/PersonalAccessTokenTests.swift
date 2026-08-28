import XCTest
@testable import Triage

final class PersonalAccessTokenTests: XCTestCase {
    func testDetectsFineGrainedTokenWithoutExposingIt() throws {
        let token = try PersonalAccessToken(rawValue: "github_pat_abcdefghijklmnopqrstuvwxyz")

        XCTAssertEqual(token.kind, .fineGrained)
        XCTAssertEqual(token.kind.authenticationKind, .fineGrainedPersonalAccessToken)
        XCTAssertTrue(token.kind.supportsDirectCopilotAuthentication)
        XCTAssertFalse(token.description.contains("abcdefghijklmnopqrstuvwxyz"))
    }

    func testDetectsClassicTokenAndRequiresSeparateCopilotSignIn() throws {
        let token = try PersonalAccessToken(rawValue: "ghp_abcdefghijklmnopqrstuvwxyz")

        XCTAssertEqual(token.kind, .classic)
        XCTAssertEqual(token.kind.authenticationKind, .classicPersonalAccessToken)
        XCTAssertFalse(token.kind.supportsDirectCopilotAuthentication)
    }

    func testRejectsWhitespaceAndUnrecognizedTokenFamilies() {
        XCTAssertThrowsError(try PersonalAccessToken(rawValue: " github_pat_abc"))
        XCTAssertThrowsError(try PersonalAccessToken(rawValue: "github_pat_abc\n"))
        XCTAssertThrowsError(try PersonalAccessToken(rawValue: "gho_not-a-pat"))
    }
}
