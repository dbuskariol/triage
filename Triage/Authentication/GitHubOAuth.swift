import AuthenticationServices
import AppKit
import CryptoKit
import Foundation
import Security

enum GitHubOAuthError: Error, Equatable, Sendable {
    case invalidConfiguration
    case randomGenerationFailed(OSStatus)
    case invalidCallback
    case invalidState
    case missingAuthorizationCode
    case authorizationInProgress
    case failedToStartAuthorization
    case authorizationTimedOut
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
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        else {
            throw GitHubOAuthError.invalidState
        }
        let states = components.queryItems?
            .filter { $0.name == "state" } ?? []
        guard states.count == 1, states[0].value == state.rawValue else {
            throw GitHubOAuthError.invalidState
        }
        let codes = components.queryItems?
            .filter { $0.name == "code" } ?? []
        guard codes.count == 1, let code = codes[0].value, !code.isEmpty
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

@MainActor
protocol OAuthBrowserSession: AnyObject {
    func start() -> Bool
    func cancel()
}

@MainActor
private final class SystemOAuthBrowserSession: OAuthBrowserSession {
    private let session: ASWebAuthenticationSession

    init(
        authorizationURL: URL,
        callbackURLScheme: String?,
        presentationContextProvider: ASWebAuthenticationPresentationContextProviding,
        completion: @escaping @MainActor (URL?, Error?) -> Void
    ) {
        session = ASWebAuthenticationSession(
            url: authorizationURL,
            callbackURLScheme: callbackURLScheme
        ) { callbackURL, error in
            Task { @MainActor in
                completion(callbackURL, error)
            }
        }
        session.presentationContextProvider = presentationContextProvider
    }

    func start() -> Bool {
        session.start()
    }

    func cancel() {
        session.cancel()
    }
}

@MainActor
final class GitHubOAuthAuthorizer: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let authorizationTimeout: Duration = .seconds(10 * 60)

    typealias BrowserSessionFactory = @MainActor (
        URL,
        String?,
        ASWebAuthenticationPresentationContextProviding,
        @escaping @MainActor (URL?, Error?) -> Void
    ) -> any OAuthBrowserSession

    private let sleep: @Sendable (Duration) async throws -> Void
    private let browserSessionFactory: BrowserSessionFactory
    private var activeSession: (any OAuthBrowserSession)?
    private var activeAnchor: ASPresentationAnchor?
    private var continuation: CheckedContinuation<AuthBrokerExchangeRequest, Error>?
    private var authorizationGeneration = OAuthAuthorizationGeneration()
    private var timeoutTask: Task<Void, Never>?

    init(
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        browserSessionFactory: @escaping BrowserSessionFactory = {
            authorizationURL,
            callbackURLScheme,
            presentationContextProvider,
            completion in
            SystemOAuthBrowserSession(
                authorizationURL: authorizationURL,
                callbackURLScheme: callbackURLScheme,
                presentationContextProvider: presentationContextProvider,
                completion: completion
            )
        }
    ) {
        self.sleep = sleep
        self.browserSessionFactory = browserSessionFactory
    }

    func authorize(
        configuration: GitHubOAuthConfiguration,
        presentationAnchor: ASPresentationAnchor
    ) async throws -> AuthBrokerExchangeRequest {
        guard activeSession == nil else {
            throw GitHubOAuthError.authorizationInProgress
        }

        let authorization = try OAuthAuthorizationSession.make(configuration: configuration)
        let authorizationID = authorizationGeneration.begin()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                activeAnchor = presentationAnchor
                let session = browserSessionFactory(
                    authorization.authorizationURL,
                    configuration.redirectURI.scheme,
                    self
                ) { [weak self] callbackURL, error in
                    self?.complete(
                        callbackURL: callbackURL,
                        error: error,
                        authorization: authorization,
                        redirectURI: configuration.redirectURI,
                        authorizationID: authorizationID
                    )
                }
                activeSession = session
                guard session.start() else {
                    finish(
                        with: .failure(GitHubOAuthError.failedToStartAuthorization),
                        authorizationID: authorizationID
                    )
                    return
                }
                scheduleTimeout(for: authorizationID)
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(authorizationID: authorizationID)
            }
        })
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        activeAnchor!
    }

    private func complete(
        callbackURL: URL?,
        error: Error?,
        authorization: OAuthAuthorizationSession,
        redirectURI: URL,
        authorizationID: UUID
    ) {
        guard authorizationGeneration.isCurrent(authorizationID) else { return }
        if let error {
            finish(with: .failure(error), authorizationID: authorizationID)
            return
        }
        guard let callbackURL else {
            finish(
                with: .failure(GitHubOAuthError.invalidCallback),
                authorizationID: authorizationID
            )
            return
        }

        do {
            let request = AuthBrokerExchangeRequest(
                authorizationCode: try authorization.authorizationCode(
                    from: callbackURL,
                    redirectURI: redirectURI
                ),
                codeVerifier: authorization.verifier,
                redirectURI: redirectURI
            )
            finish(with: .success(request), authorizationID: authorizationID)
        } catch {
            finish(with: .failure(error), authorizationID: authorizationID)
        }
    }

    private func cancel(authorizationID: UUID) {
        guard authorizationGeneration.isCurrent(authorizationID) else { return }
        let session = activeSession
        finish(with: .failure(CancellationError()), authorizationID: authorizationID)
        session?.cancel()
    }

    private func scheduleTimeout(for authorizationID: UUID) {
        timeoutTask?.cancel()
        let sleep = sleep
        timeoutTask = Task { [weak self] in
            do {
                try await sleep(Self.authorizationTimeout)
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch {
                return
            }
            self?.timeout(authorizationID: authorizationID)
        }
    }

    private func timeout(authorizationID: UUID) {
        guard authorizationGeneration.isCurrent(authorizationID) else { return }
        let session = activeSession
        finish(
            with: .failure(GitHubOAuthError.authorizationTimedOut),
            authorizationID: authorizationID
        )
        session?.cancel()
    }

    private func finish(
        with result: Result<AuthBrokerExchangeRequest, Error>,
        authorizationID: UUID
    ) {
        guard authorizationGeneration.finish(authorizationID) else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        let continuation = continuation
        self.continuation = nil
        activeSession = nil
        activeAnchor = nil
        continuation?.resume(with: result)
    }
}

/// Keeps delayed system callbacks and cancellation handlers bound to the
/// authorization attempt that created them.  `ASWebAuthenticationSession`
/// invokes callbacks asynchronously, so a stale callback must be unable to
/// finish a later attempt.
struct OAuthAuthorizationGeneration: Sendable {
    private var activeID: UUID?

    mutating func begin() -> UUID {
        let id = UUID()
        activeID = id
        return id
    }

    func isCurrent(_ id: UUID) -> Bool {
        activeID == id
    }

    mutating func finish(_ id: UUID) -> Bool {
        guard activeID == id else { return false }
        activeID = nil
        return true
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
