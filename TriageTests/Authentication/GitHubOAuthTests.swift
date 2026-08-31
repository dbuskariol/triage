import AppKit
import AuthenticationServices
import XCTest
@testable import Triage

final class GitHubOAuthTests: XCTestCase {
    private let redirectURI = URL(string: "triage://oauth-callback")!

    func testAuthorizationRequestUsesS256PKCEAndRequiredScopes() throws {
        let configuration = try GitHubOAuthConfiguration(
            clientID: "client-id",
            redirectURI: redirectURI
        )
        let session = try OAuthAuthorizationSession.make(configuration: configuration)
        let query = try XCTUnwrap(
            URLComponents(url: session.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems
        )

        XCTAssertEqual(session.authorizationURL.scheme, "https")
        XCTAssertEqual(session.authorizationURL.host, "github.com")
        XCTAssertEqual(query.value(named: "client_id"), "client-id")
        XCTAssertEqual(query.value(named: "redirect_uri"), redirectURI.absoluteString)
        XCTAssertEqual(query.value(named: "code_challenge_method"), "S256")
        XCTAssertEqual(query.value(named: "prompt"), "select_account")
        XCTAssertEqual(query.value(named: "scope"), "repo read:org offline_access")
        XCTAssertEqual(query.value(named: "code_challenge")?.count, 43)
    }

    func testCallbackRequiresTheExactStateAndCallbackRoute() throws {
        let configuration = try GitHubOAuthConfiguration(
            clientID: "client-id",
            redirectURI: redirectURI
        )
        let session = try OAuthAuthorizationSession.make(configuration: configuration)
        let success = URL(
            string: "triage://oauth-callback?code=authorization-code&state=\(session.state.rawValue)"
        )!

        XCTAssertEqual(
            try session.authorizationCode(from: success, redirectURI: redirectURI).value.rawValue,
            "authorization-code"
        )
        XCTAssertThrowsError(
            try session.authorizationCode(
                from: URL(string: "triage://oauth-callback?code=code&state=wrong")!,
                redirectURI: redirectURI
            )
        )
        XCTAssertThrowsError(
            try session.authorizationCode(
                from: URL(string: "triage://different?code=code&state=\(session.state.rawValue)")!,
                redirectURI: redirectURI
            )
        )
    }

    func testCallbackRejectsAmbiguousOrMissingAuthorizationParameters() throws {
        let configuration = try GitHubOAuthConfiguration(
            clientID: "client-id",
            redirectURI: redirectURI
        )
        let session = try OAuthAuthorizationSession.make(configuration: configuration)

        XCTAssertThrowsError(
            try session.authorizationCode(
                from: URL(
                    string: "triage://oauth-callback?code=code&state=\(session.state.rawValue)&state=attacker"
                )!,
                redirectURI: redirectURI
            )
        ) { error in
            XCTAssertEqual(error as? GitHubOAuthError, .invalidState)
        }
        XCTAssertThrowsError(
            try session.authorizationCode(
                from: URL(
                    string: "triage://oauth-callback?code=code&state=\(session.state.rawValue)&state"
                )!,
                redirectURI: redirectURI
            )
        ) { error in
            XCTAssertEqual(error as? GitHubOAuthError, .invalidState)
        }
        XCTAssertThrowsError(
            try session.authorizationCode(
                from: URL(
                    string: "triage://oauth-callback?code=code&code=attacker&state=\(session.state.rawValue)"
                )!,
                redirectURI: redirectURI
            )
        ) { error in
            XCTAssertEqual(error as? GitHubOAuthError, .missingAuthorizationCode)
        }
        XCTAssertThrowsError(
            try session.authorizationCode(
                from: URL(
                    string: "triage://oauth-callback?code=code&code&state=\(session.state.rawValue)"
                )!,
                redirectURI: redirectURI
            )
        ) { error in
            XCTAssertEqual(error as? GitHubOAuthError, .missingAuthorizationCode)
        }
        XCTAssertThrowsError(
            try session.authorizationCode(
                from: URL(string: "triage://oauth-callback?state=\(session.state.rawValue)")!,
                redirectURI: redirectURI
            )
        ) { error in
            XCTAssertEqual(error as? GitHubOAuthError, .missingAuthorizationCode)
        }
    }

    func testConfigurationRejectsASecretlessOrUntrustedAuthorizationEndpoint() {
        XCTAssertThrowsError(
            try GitHubOAuthConfiguration(
                clientID: "",
                redirectURI: redirectURI
            )
        )
        XCTAssertThrowsError(
            try GitHubOAuthConfiguration(
                clientID: "client-id",
                authorizationEndpoint: URL(string: "https://example.com/authorize")!,
                redirectURI: redirectURI
            )
        )
    }

    func testStaleCancellationGenerationCannotFinishNewAuthorization() {
        var generation = OAuthAuthorizationGeneration()
        let cancelledAuthorization = generation.begin()

        XCTAssertTrue(generation.finish(cancelledAuthorization))

        let currentAuthorization = generation.begin()
        XCTAssertFalse(generation.finish(cancelledAuthorization))
        XCTAssertTrue(generation.isCurrent(currentAuthorization))
    }

    @MainActor
    func testAuthorizationTimesOutCancelsBrowserIgnoresLateCallbackAndAllowsRetry() async throws {
        let sleeper = OAuthTimeoutSleeper()
        let sessions = OAuthBrowserSessionFactorySpy()
        let authorizer = GitHubOAuthAuthorizer(
            sleep: { duration in
                try await sleeper.sleep(for: duration)
            },
            browserSessionFactory: { url, scheme, provider, completion in
                sessions.make(
                    authorizationURL: url,
                    callbackURLScheme: scheme,
                    presentationContextProvider: provider,
                    completion: completion
                )
            }
        )
        let configuration = try GitHubOAuthConfiguration(
            clientID: "client-id",
            redirectURI: redirectURI
        )

        let timedOutAuthorization = Task {
            try await authorizer.authorize(
                configuration: configuration,
                presentationAnchor: NSWindow()
            )
        }
        let firstSession = try await sessions.waitForSession(at: 0)
        await sleeper.waitForSleep()
        let timeoutDuration = await sleeper.recordedDuration()
        XCTAssertEqual(timeoutDuration, GitHubOAuthAuthorizer.authorizationTimeout)

        await sleeper.fire()
        do {
            _ = try await timedOutAuthorization.value
            XCTFail("Expected the OAuth authorization to time out.")
        } catch let error as GitHubOAuthError {
            XCTAssertEqual(error, .authorizationTimedOut)
        }
        XCTAssertEqual(firstSession.cancelCount, 1)

        let retryAuthorization = Task {
            try await authorizer.authorize(
                configuration: configuration,
                presentationAnchor: NSWindow()
            )
        }
        let retrySession = try await sessions.waitForSession(at: 1)
        XCTAssertEqual(retrySession.startCount, 1)

        firstSession.complete(firstSession.successfulCallbackURL())
        do {
            _ = try await authorizer.authorize(
                configuration: configuration,
                presentationAnchor: NSWindow()
            )
            XCTFail("A late callback must not finish the active retry.")
        } catch let error as GitHubOAuthError {
            XCTAssertEqual(error, .authorizationInProgress)
        }

        retryAuthorization.cancel()
        do {
            _ = try await retryAuthorization.value
            XCTFail("Expected caller cancellation for the retry.")
        } catch is CancellationError {
            // Expected: the timeout did not leave authorization in progress.
        }
        XCTAssertEqual(retrySession.cancelCount, 1)
    }
}

private actor OAuthTimeoutSleeper {
    private var continuation: CheckedContinuation<Void, Error>?
    private var duration: Duration?
    private var sleepStarted = [CheckedContinuation<Void, Never>]()

    func sleep(for duration: Duration) async throws {
        self.duration = duration
        let waiters = sleepStarted
        sleepStarted.removeAll()
        waiters.forEach { $0.resume() }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        }, onCancel: {
            Task { await self.cancelSleep() }
        })
    }

    func waitForSleep() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { continuation in
            sleepStarted.append(continuation)
        }
    }

    func recordedDuration() -> Duration? {
        duration
    }

    func fire() {
        continuation?.resume()
        continuation = nil
    }

    private func cancelSleep() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

@MainActor
private final class OAuthBrowserSessionFactorySpy {
    private var sessions = [OAuthBrowserSessionSpy]()
    private var waiters: [Int: [CheckedContinuation<OAuthBrowserSessionSpy, Error>]] = [:]

    func make(
        authorizationURL: URL,
        callbackURLScheme: String?,
        presentationContextProvider _: ASWebAuthenticationPresentationContextProviding,
        completion: @escaping @MainActor (URL?, Error?) -> Void
    ) -> any OAuthBrowserSession {
        let session = OAuthBrowserSessionSpy(
            authorizationURL: authorizationURL,
            callbackURLScheme: callbackURLScheme,
            completion: completion
        )
        sessions.append(session)
        let index = sessions.count - 1
        let waiters = waiters.removeValue(forKey: index) ?? []
        waiters.forEach { $0.resume(returning: session) }
        return session
    }

    func waitForSession(at index: Int) async throws -> OAuthBrowserSessionSpy {
        if sessions.indices.contains(index) {
            return sessions[index]
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters[index, default: []].append(continuation)
        }
    }
}

@MainActor
private final class OAuthBrowserSessionSpy: OAuthBrowserSession {
    let authorizationURL: URL
    let callbackURLScheme: String?
    private let completion: @MainActor (URL?, Error?) -> Void
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    init(
        authorizationURL: URL,
        callbackURLScheme: String?,
        completion: @escaping @MainActor (URL?, Error?) -> Void
    ) {
        self.authorizationURL = authorizationURL
        self.callbackURLScheme = callbackURLScheme
        self.completion = completion
    }

    func start() -> Bool {
        startCount += 1
        return true
    }

    func cancel() {
        cancelCount += 1
        completion(successfulCallbackURL(), nil)
    }

    func complete(_ callbackURL: URL) {
        completion(callbackURL, nil)
    }

    func successfulCallbackURL() -> URL {
        let state = URLComponents(
            url: authorizationURL,
            resolvingAgainstBaseURL: false
        )?.queryItems?.first(where: { $0.name == "state" })?.value
        return URL(string: "triage://oauth-callback?code=code&state=\(state!)")!
    }
}

private extension Array where Element == URLQueryItem {
    func value(named name: String) -> String? {
        first(where: { $0.name == name })?.value
    }
}
