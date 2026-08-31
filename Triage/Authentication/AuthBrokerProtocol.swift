import Foundation

enum AuthBrokerProtocol {
    static let version = 1
    static let maximumRequestBodyBytes = 16 * 1_024
    static let maximumResponseBodyBytes = 32 * 1_024
    static let requestLifetimeMilliseconds: Int64 = 60_000
    /// JavaScript transports protocol versions as `Number`, so components
    /// must remain exactly representable by the Cloudflare Worker.
    static let maximumApplicationVersionComponent: UInt64 = 9_007_199_254_740_991

    static func isValidApplicationVersion(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else { return false }
        return components.allSatisfy { component in
            guard !component.isEmpty,
                  component.allSatisfy(\.isNumber),
                  let number = UInt64(component)
            else {
                return false
            }
            return number <= maximumApplicationVersionComponent
                && (component == "0" || !component.hasPrefix("0"))
        }
    }
}

struct OAuthAuthorizationCode: Codable, Equatable, Sendable, CustomStringConvertible {
    let value: SecretValue

    init(_ value: String) {
        self.value = SecretValue(value)
    }

    var description: String {
        "<redacted OAuth authorization code>"
    }

    init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value.rawValue)
    }
}

struct OAuthRefreshToken: Codable, Equatable, Sendable, CustomStringConvertible {
    let value: SecretValue

    init(_ value: String) {
        self.value = SecretValue(value)
    }

    var description: String {
        "<redacted OAuth refresh token>"
    }

    init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value.rawValue)
    }
}

struct OAuthAccessToken: Codable, Equatable, Sendable, CustomStringConvertible {
    let value: SecretValue

    init(_ value: String) {
        self.value = SecretValue(value)
    }

    var description: String {
        "<redacted OAuth access token>"
    }

    init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value.rawValue)
    }
}

struct AuthBrokerExchangeRequest: Codable, Equatable, Sendable {
    let version: Int
    let authorizationCode: OAuthAuthorizationCode
    let codeVerifier: OAuthCodeVerifier
    let redirectURI: URL

    init(
        authorizationCode: OAuthAuthorizationCode,
        codeVerifier: OAuthCodeVerifier,
        redirectURI: URL
    ) {
        version = AuthBrokerProtocol.version
        self.authorizationCode = authorizationCode
        self.codeVerifier = codeVerifier
        self.redirectURI = redirectURI
    }
}

struct AuthBrokerRefreshRequest: Codable, Equatable, Sendable {
    let version: Int
    let refreshToken: OAuthRefreshToken

    init(refreshToken: OAuthRefreshToken) {
        version = AuthBrokerProtocol.version
        self.refreshToken = refreshToken
    }
}

struct AuthBrokerTokenResponse: Codable, Equatable, Sendable {
    let version: Int
    let accessToken: OAuthAccessToken
    let refreshToken: OAuthRefreshToken?
    let tokenType: String
    let scope: String?
    let expiresIn: TimeInterval?
    let refreshTokenExpiresIn: TimeInterval?

    init(
        accessToken: OAuthAccessToken,
        refreshToken: OAuthRefreshToken?,
        tokenType: String,
        scope: String?,
        expiresIn: TimeInterval?,
        refreshTokenExpiresIn: TimeInterval?
    ) {
        version = AuthBrokerProtocol.version
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.scope = scope
        self.expiresIn = expiresIn
        self.refreshTokenExpiresIn = refreshTokenExpiresIn
    }
}

struct AuthBrokerFailure: Codable, Equatable, Sendable, Error {
    enum Code: String, Codable, Sendable {
        case invalidRequest
        case authorizationDenied
        case invalidGrant
        case invalidClient
        case temporarilyUnavailable
        case unavailable
    }

    let version: Int
    let code: Code
    let recoveryDescription: String

    init(code: Code, recoveryDescription: String) {
        version = AuthBrokerProtocol.version
        self.code = code
        self.recoveryDescription = recoveryDescription
    }
}
