import Foundation

/// What a GitHub response says about the credential that made it.
enum GitHubCredentialObservation: Equatable, Sendable {
    /// GitHub accepted the credential. `expiresAt` comes from the
    /// `GitHub-Authentication-Token-Expiration` header, which GitHub sends for
    /// credentials that expire (personal access tokens with an expiration date
    /// and GitHub App user tokens); `nil` means no expiration.
    case accepted(expiresAt: Date?)
    /// GitHub answered 401: the credential expired, was revoked, or was regenerated.
    case rejected

    static let expirationHeader = "GitHub-Authentication-Token-Expiration"

    init(statusCode: Int, expirationHeader: String?) {
        self = statusCode == 401
            ? .rejected
            : .accepted(expiresAt: Self.expirationDate(from: expirationHeader))
    }

    /// Parses GitHub's `2026-10-11 08:00:00 UTC` or `2026-10-11 08:00:00 +1100` form.
    static func expirationDate(from header: String?) -> Date? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        let normalized = header.hasSuffix(" UTC") ? header.dropLast(4) + " +0000" : Substring(header)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: String(normalized))
    }
}
