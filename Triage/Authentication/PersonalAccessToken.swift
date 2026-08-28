import Foundation

enum PersonalAccessTokenKind: String, Codable, Sendable {
    case fineGrained
    case classic

    var authenticationKind: AuthenticationKind {
        switch self {
        case .fineGrained: .fineGrainedPersonalAccessToken
        case .classic: .classicPersonalAccessToken
        }
    }

    var supportsDirectCopilotAuthentication: Bool {
        self == .fineGrained
    }
}

enum PersonalAccessTokenError: Error, Equatable, Sendable {
    case unsupportedTokenFormat
}

struct PersonalAccessToken: Equatable, Sendable, CustomStringConvertible {
    let kind: PersonalAccessTokenKind
    let value: SecretValue

    init(rawValue: String) throws {
        guard rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.unicodeScalars.contains(where: \.properties.isWhitespace)
        else {
            throw PersonalAccessTokenError.unsupportedTokenFormat
        }

        if rawValue.hasPrefix("github_pat_") {
            kind = .fineGrained
        } else if rawValue.hasPrefix("ghp_") {
            kind = .classic
        } else {
            throw PersonalAccessTokenError.unsupportedTokenFormat
        }
        value = SecretValue(rawValue)
    }

    var description: String {
        "<redacted \(kind.rawValue) personal access token>"
    }
}
