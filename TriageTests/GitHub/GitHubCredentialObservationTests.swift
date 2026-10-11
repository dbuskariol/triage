import Foundation
import Testing
@testable import Triage

struct GitHubCredentialObservationTests {
    @Test func parsesGitHubsUTCAndOffsetExpirationForms() {
        let expected = Date(timeIntervalSince1970: 1_791_100_800) // 2026-10-04 08:00:00 UTC
        #expect(GitHubCredentialObservation.expirationDate(from: "2026-10-04 08:00:00 UTC") == expected)
        #expect(GitHubCredentialObservation.expirationDate(from: "2026-10-04 19:00:00 +1100") == expected)
        #expect(GitHubCredentialObservation.expirationDate(from: nil) == nil)
        #expect(GitHubCredentialObservation.expirationDate(from: "") == nil)
        #expect(GitHubCredentialObservation.expirationDate(from: "soon") == nil)
    }

    @Test func unauthorizedResponsesRejectTheCredential() {
        #expect(GitHubCredentialObservation(statusCode: 401, expirationHeader: "2026-10-04 08:00:00 UTC") == .rejected)
        #expect(GitHubCredentialObservation(statusCode: 200, expirationHeader: nil) == .accepted(expiresAt: nil))
        // A 403 is about access to a resource, not the credential itself.
        #expect(GitHubCredentialObservation(statusCode: 403, expirationHeader: nil) == .accepted(expiresAt: nil))
    }
}
