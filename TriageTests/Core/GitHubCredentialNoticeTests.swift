import Foundation
import Testing
@testable import Triage

struct GitHubCredentialNoticeTests {
    private let now = Date(timeIntervalSince1970: 1_791_100_800)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func account(
        _ kind: AuthenticationKind = .classicPersonalAccessToken,
        status: CredentialStatus = .active,
        expiresIn: TimeInterval? = nil
    ) -> GitHubAccount {
        GitHubAccount(
            id: AccountID(rawValue: "account-1")!, githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_kgDOExample")!, login: "octocat",
            authenticationKind: kind, credentialID: CredentialID(rawValue: "credential-1")!,
            credentialStatus: status, accessTokenExpiresAt: expiresIn.map { now.addingTimeInterval($0) },
            createdAt: now
        )
    }

    private func notice(_ account: GitHubAccount?, _ problem: TriageStatus.Problem? = nil) -> GitHubCredentialNotice? {
        GitHubCredentialNotice.make(account: account, problem: problem, now: now, calendar: calendar)
    }

    @Test func healthyTokensNeedNoNotice() {
        #expect(notice(account()) == nil)
        #expect(notice(account(expiresIn: 30 * 24 * 3_600)) == nil)
    }

    @Test func tokensExpiringWithinAWeekWarnWithoutBlocking() throws {
        let tomorrow = try #require(notice(account(expiresIn: 24 * 3_600)))
        #expect(!tomorrow.isBlocking)
        #expect(tomorrow.canReplaceToken)
        #expect(tomorrow.message.contains("expires tomorrow"))
        #expect(try #require(notice(account(expiresIn: 3 * 24 * 3_600))).message.contains("on Wednesday"))
    }

    @Test func expiredTokensSayWhen() throws {
        let expired = try #require(notice(account(expiresIn: -3_600), .gitHubCredentialRejected))
        #expect(expired.isBlocking)
        #expect(expired.message.contains("expired on Oct 4, 2026"))
        #expect(expired.actionTitle == "Replace Token…")
    }

    @Test func rejectedTokensWithoutAnExpirationWereRevoked() throws {
        let fromEngine = try #require(notice(account(), .gitHubCredentialRejected))
        #expect(fromEngine.isBlocking)
        #expect(fromEngine.message.contains("revoked or regenerated"))
        #expect(notice(account(status: .revoked)) == fromEngine)
    }

    @Test func gitHubSignInsAreReconnectedNotReplaced() throws {
        let oauth = try #require(notice(account(.oauth), .gitHubCredentialRejected))
        #expect(!oauth.canReplaceToken)
        #expect(oauth.actionTitle == "Open Account Settings")
        // OAuth tokens renew automatically; their short lifetime is never a warning.
        #expect(notice(account(.oauth, expiresIn: 60)) == nil)
    }
}
