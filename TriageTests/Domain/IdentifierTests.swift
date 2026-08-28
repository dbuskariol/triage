import XCTest
@testable import Triage

final class IdentifierTests: XCTestCase {
    func testOpaqueIdentifiersRejectEmptyAndWhitespace() {
        XCTAssertNil(AccountID(rawValue: ""))
        XCTAssertNil(OrganizationID(rawValue: "octo cat"))
        XCTAssertNil(GitHubNodeID(rawValue: "\nnode"))
        XCTAssertNotNil(RepositoryID(rawValue: "R_kgDOExample"))
    }

    func testOpaqueIdentifiersRejectInvalidPersistedValues() throws {
        let decoder = JSONDecoder()
        let invalidValues = [
            "\"\"",
            "\"with space\"",
            "\"with\\nnewline\""
        ]

        for value in invalidValues {
            XCTAssertThrowsError(
                try decoder.decode(AccountID.self, from: Data(value.utf8)),
                "Expected \(value) to be rejected."
            )
        }
    }

    func testOpaqueIdentifiersRoundTripAsSingleValues() throws {
        let accountID = AccountID(rawValue: "account-1")!
        let encoded = try JSONEncoder().encode(accountID)

        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"account-1\"")
        XCTAssertEqual(try JSONDecoder().decode(AccountID.self, from: encoded), accountID)
    }

    func testEveryOpaqueIdentifierUsesValidatedSingleValueCoding() throws {
        try assertRoundTrip(AccountID.self, rawValue: "account-1")
        try assertRoundTrip(OrganizationID.self, rawValue: "organization-1")
        try assertRoundTrip(RepositoryID.self, rawValue: "repository-1")
        try assertRoundTrip(ActorID.self, rawValue: "actor-1")
        try assertRoundTrip(TeamID.self, rawValue: "team-1")
        try assertRoundTrip(GitHubNodeID.self, rawValue: "node-1")
        try assertRoundTrip(GitHubEventID.self, rawValue: "event-1")
        try assertRoundTrip(WorkItemID.self, rawValue: "work-1")
        try assertRoundTrip(ActionItemID.self, rawValue: "action-1")
        try assertRoundTrip(EvidenceID.self, rawValue: "evidence-1")
        try assertRoundTrip(SyncStreamID.self, rawValue: "stream-1")
        try assertRoundTrip(AIRequestID.self, rawValue: "request-1")
        try assertRoundTrip(CredentialID.self, rawValue: "credential-1")
        try assertRoundTrip(CredentialRevision.self, rawValue: "credential-revision-1")
        try assertRoundTrip(CapabilityRevision.self, rawValue: "capability-revision-1")
        try assertRoundTrip(OAuthState.self, rawValue: "state-1")
    }

    func testPKCEVerifierRejectsInvalidPersistedData() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(OAuthCodeVerifier.self, from: Data("\"short\"".utf8))
        )
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

    private func assertRoundTrip<T: TriageIdentifier & Equatable>(
        _ type: T.Type,
        rawValue: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let identifier = try XCTUnwrap(T(rawValue: rawValue), file: file, line: line)
        let encoded = try JSONEncoder().encode(identifier)
        XCTAssertEqual(
            try JSONDecoder().decode(T.self, from: encoded),
            identifier,
            file: file,
            line: line
        )
    }
}
