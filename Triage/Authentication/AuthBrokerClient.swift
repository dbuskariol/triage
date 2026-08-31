import Foundation
import Security

enum AuthBrokerClientError: Error, Equatable, Sendable {
    case invalidBaseURL
    case invalidApplicationVersion
    case requestControlUnavailable(OSStatus)
    case invalidResponse
    case responseTooLarge
    case broker(AuthBrokerFailure)
}

protocol OAuthTokenRefreshing: Sendable {
    func refresh(
        _ request: AuthBrokerRefreshRequest
    ) async throws -> AuthBrokerTokenResponse
}

actor AuthBrokerClient: OAuthTokenRefreshing {
    private let baseURL: URL
    private let applicationVersion: String
    private let session: any HTTPSession
    private let clock: @Sendable () -> Date

    init(
        baseURL: URL,
        applicationVersion: String,
        clock: @escaping @Sendable () -> Date = Date.init,
        session: any HTTPSession = URLSessionHTTPSession()
    ) throws {
        try Self.validate(baseURL: baseURL)
        guard AuthBrokerProtocol.isValidApplicationVersion(applicationVersion) else {
            throw AuthBrokerClientError.invalidApplicationVersion
        }
        self.baseURL = baseURL
        self.applicationVersion = applicationVersion
        self.clock = clock
        self.session = session
    }

    static func validate(baseURL: URL) throws {
        guard baseURL.scheme == "https",
              baseURL.host != nil,
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil
        else {
            throw AuthBrokerClientError.invalidBaseURL
        }
    }

    func exchange(
        _ request: AuthBrokerExchangeRequest
    ) async throws -> AuthBrokerTokenResponse {
        try await send(
            ExchangeRequestEnvelope(request: request, control: try makeRequestControl()),
            path: "/oauth/exchange"
        )
    }

    func refresh(
        _ request: AuthBrokerRefreshRequest
    ) async throws -> AuthBrokerTokenResponse {
        try await send(
            RefreshRequestEnvelope(request: request, control: try makeRequestControl()),
            path: "/oauth/refresh"
        )
    }

    private func send<Request: Encodable>(
        _ request: Request,
        path: String
    ) async throws -> AuthBrokerTokenResponse {
        let url = try endpointURL(path: path)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        urlRequest.setValue(applicationVersion, forHTTPHeaderField: "X-Triage-Application-Version")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (body, response) = try await boundedData(for: urlRequest)
        guard body.count <= AuthBrokerProtocol.maximumResponseBodyBytes else {
            throw AuthBrokerClientError.responseTooLarge
        }

        if (200...299).contains(response.statusCode) {
            do {
                let response = try JSONDecoder().decode(AuthBrokerTokenResponse.self, from: body)
                guard response.version == AuthBrokerProtocol.version else {
                    throw AuthBrokerClientError.invalidResponse
                }
                return response
            } catch {
                throw AuthBrokerClientError.invalidResponse
            }
        }

        do {
            let failure = try JSONDecoder().decode(AuthBrokerFailure.self, from: body)
            guard failure.version == AuthBrokerProtocol.version else {
                throw AuthBrokerClientError.invalidResponse
            }
            throw AuthBrokerClientError.broker(failure)
        } catch let error as AuthBrokerClientError {
            throw error
        } catch {
            throw AuthBrokerClientError.invalidResponse
        }
    }

    private func endpointURL(path: String) throws -> URL {
        guard path.hasPrefix("/") else {
            throw AuthBrokerClientError.invalidBaseURL
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        guard let url = components?.url else {
            throw AuthBrokerClientError.invalidBaseURL
        }
        return url
    }

    private func boundedData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            if let boundedSession = session as? any BoundedHTTPSession {
                return try await boundedSession.data(
                    for: request,
                    maximumResponseBodyBytes: AuthBrokerProtocol.maximumResponseBodyBytes
                )
            }
            return try await session.data(for: request)
        } catch GitHubTransportError.responseTooLarge {
            throw AuthBrokerClientError.responseTooLarge
        }
    }

    private func makeRequestControl() throws -> AuthBrokerRequestControl {
        var bytes = [UInt8](repeating: 0, count: 32)
        let byteCount = bytes.count
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, byteCount, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw AuthBrokerClientError.requestControlUnavailable(status)
        }
        let issuedAt = Int64((clock().timeIntervalSince1970 * 1_000).rounded(.down))
        guard issuedAt > 0 else {
            throw AuthBrokerClientError.invalidResponse
        }
        return AuthBrokerRequestControl(
            nonce: Data(bytes)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: ""),
            issuedAt: issuedAt,
            expiresAt: issuedAt + AuthBrokerProtocol.requestLifetimeMilliseconds
        )
    }
}

private struct AuthBrokerRequestControl: Encodable, Sendable {
    let nonce: String
    let issuedAt: Int64
    let expiresAt: Int64
}

private struct ExchangeRequestEnvelope: Encodable, Sendable {
    let version: Int
    let authorizationCode: OAuthAuthorizationCode
    let codeVerifier: OAuthCodeVerifier
    let redirectURI: URL
    let nonce: String
    let issuedAt: Int64
    let expiresAt: Int64

    init(request: AuthBrokerExchangeRequest, control: AuthBrokerRequestControl) {
        version = request.version
        authorizationCode = request.authorizationCode
        codeVerifier = request.codeVerifier
        redirectURI = request.redirectURI
        nonce = control.nonce
        issuedAt = control.issuedAt
        expiresAt = control.expiresAt
    }
}

private struct RefreshRequestEnvelope: Encodable, Sendable {
    let version: Int
    let refreshToken: OAuthRefreshToken
    let nonce: String
    let issuedAt: Int64
    let expiresAt: Int64

    init(request: AuthBrokerRefreshRequest, control: AuthBrokerRequestControl) {
        version = request.version
        refreshToken = request.refreshToken
        nonce = control.nonce
        issuedAt = control.issuedAt
        expiresAt = control.expiresAt
    }
}
