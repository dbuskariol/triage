import CryptoKit
import Foundation
import Security

enum GitHubOAuthError: Error, Equatable, Sendable {
    case invalidConfiguration
    case randomGenerationFailed(OSStatus)
    case invalidCallback
    case invalidState
    case missingAuthorizationCode
}

struct GitHubOAuthConfiguration: Equatable, Sendable {
    let clientID: String
    let authorizationEndpoint: URL
    let redirectURI: URL
    let scopes: [String]

    init(
        clientID: String,
        authorizationEndpoint: URL = URL(string: "https://github.com/login/oauth/authorize")!,
        redirectURI: URL,
        scopes: [String] = ["repo", "read:org", "offline_access"]
    ) throws {
        guard !clientID.isEmpty,
              authorizationEndpoint.scheme == "https",
              authorizationEndpoint.host == "github.com",
              redirectURI.scheme == "triage",
              redirectURI.host != nil,
              !scopes.isEmpty
        else {
            throw GitHubOAuthError.invalidConfiguration
        }
        self.clientID = clientID
        self.authorizationEndpoint = authorizationEndpoint
        self.redirectURI = redirectURI
        self.scopes = scopes
    }
}

struct OAuthAuthorizationSession: Equatable, Sendable {
    let state: OAuthState
    let verifier: OAuthCodeVerifier
    let authorizationURL: URL

    static func make(
        configuration: GitHubOAuthConfiguration
    ) throws -> OAuthAuthorizationSession {
        let state = try randomURLSafeValue(byteCount: 32)
        let verifier = try randomURLSafeValue(byteCount: 64)
        guard let oauthState = OAuthState(rawValue: state),
              let codeVerifier = OAuthCodeVerifier(rawValue: verifier)
        else {
            throw GitHubOAuthError.invalidConfiguration
        }

        let challenge = SHA256.hash(data: Data(verifier.utf8))
            .withUnsafeBytes { Data($0) }
            .base64URLEncodedString()
        var components = URLComponents(
            url: configuration.authorizationEndpoint,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " "))
        ]
        guard let authorizationURL = components?.url else {
            throw GitHubOAuthError.invalidConfiguration
        }
        return OAuthAuthorizationSession(
            state: oauthState,
            verifier: codeVerifier,
            authorizationURL: authorizationURL
        )
    }

    func authorizationCode(
        from callbackURL: URL,
        redirectURI: URL
    ) throws -> OAuthAuthorizationCode {
        guard callbackURL.scheme == redirectURI.scheme,
              callbackURL.host == redirectURI.host,
              callbackURL.path == redirectURI.path,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value,
              returnedState == state.rawValue
        else {
            throw GitHubOAuthError.invalidState
        }
        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty
        else {
            throw GitHubOAuthError.missingAuthorizationCode
        }
        return OAuthAuthorizationCode(code)
    }

    private static func randomURLSafeValue(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, byteCount, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw GitHubOAuthError.randomGenerationFailed(status)
        }
        return Data(bytes).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
