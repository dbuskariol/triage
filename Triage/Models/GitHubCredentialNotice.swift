import Foundation

/// What the workspace tells the user about the selected account's GitHub token.
struct GitHubCredentialNotice: Equatable, Sendable {
    let message: String
    /// The token no longer works; GitHub data can't refresh until it's replaced.
    let isBlocking: Bool
    /// Personal access tokens are replaced in place; GitHub sign-ins are reconnected.
    let canReplaceToken: Bool

    var actionTitle: String { canReplaceToken ? "Replace Token…" : "Open Account Settings" }

    static func make(
        account: GitHubAccount?,
        problem: TriageStatus.Problem?,
        now: Date,
        calendar: Calendar = .current
    ) -> Self? {
        guard let account else {
            return problem?.isCredentialRejected == true
                ? Self(message: "GitHub no longer accepts this account's token.", isBlocking: true, canReplaceToken: false)
                : nil
        }
        let isPersonalAccessToken = account.authenticationKind != .oauth
        let rejected = problem?.isCredentialRejected == true
            || account.credentialStatus == .revoked
            || account.credentialStatus == .expired
        let expiresAt = isPersonalAccessToken ? account.accessTokenExpiresAt : nil
        let token = isPersonalAccessToken ? "Your GitHub token" : "Your GitHub sign-in"
        let replace = isPersonalAccessToken
            ? "Replace it to keep your work up to date."
            : "Reconnect the account to keep your work up to date."

        if let expiresAt, expiresAt <= now {
            let date = expiresAt.formatted(Self.style(calendar, date: .abbreviated))
            return Self(message: "\(token) expired on \(date). \(replace)", isBlocking: true, canReplaceToken: isPersonalAccessToken)
        }
        if rejected {
            return Self(
                message: "GitHub no longer accepts \(isPersonalAccessToken ? "your token" : "your sign-in"). It may have been revoked or regenerated. \(replace)",
                isBlocking: true,
                canReplaceToken: isPersonalAccessToken
            )
        }
        if let expiresAt, expiresAt <= now.addingTimeInterval(CredentialLifecycle.personalAccessTokenWarningInterval) {
            return Self(
                message: "\(token) expires \(Self.relativeDay(expiresAt, now: now, calendar: calendar)). Replace it before then to avoid an interruption.",
                isBlocking: false,
                canReplaceToken: true
            )
        }
        return nil
    }

    /// "today at 5:00 PM", "tomorrow at 9:00 AM", "on Friday", or "on Oct 19, 2026".
    private static func relativeDay(_ date: Date, now: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let time = Self.style(calendar, time: .shortened)
        switch days {
        case ...0: return "today at \(date.formatted(time))"
        case 1: return "tomorrow at \(date.formatted(time))"
        case 2...5:
            let weekday = Self.style(calendar).weekday(.wide)
            return "on \(date.formatted(weekday))"
        default:
            return "on \(date.formatted(Self.style(calendar, date: .abbreviated)))"
        }
    }

    private static func style(
        _ calendar: Calendar, date: Date.FormatStyle.DateStyle? = nil, time: Date.FormatStyle.TimeStyle? = nil
    ) -> Date.FormatStyle {
        Date.FormatStyle(
            date: date, time: time, locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone
        )
    }
}
