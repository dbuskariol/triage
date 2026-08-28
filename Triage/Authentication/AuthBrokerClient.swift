import Foundation

enum AuthBrokerClientError: Error, Equatable, Sendable {
    case invalidBaseURL
    case invalidResponse
    case responseTooLarge
    case broker(AuthBrokerFailure)
}

actor AuthBrokerClient {
    private let baseURL: URL
    private let session: any HTTPSession

    init(
        baseURL: URL,
        session: any HTTPSession = URLSessionHTTPSession()
    ) throws {
        guard baseURL.scheme == "https",
              baseURL.host != nil,
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil
        else {
            throw AuthBrokerClientError.invalidBaseURL
        }
        self.baseURL = baseURL
        self.session = session
    }

    func exchange(
        _ request: AuthBrokerExchangeRequest
    ) async throws -> AuthBrokerTokenResponse {
        try await send(request, path: "/oauth/exchange")
    }

    func refresh(
        _ request: AuthBrokerRefreshRequest
    ) async throws -> AuthBrokerTokenResponse {
        try await send(request, path: "/oauth/refresh")
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
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (body, response) = try await session.data(for: urlRequest)
        guard body.count <= AuthBrokerProtocol.maximumResponseBodyBytes else {
            throw AuthBrokerClientError.responseTooLarge
        }

        if (200...299).contains(response.statusCode) {
            do {
                return try JSONDecoder().decode(AuthBrokerTokenResponse.self, from: body)
            } catch {
                throw AuthBrokerClientError.invalidResponse
            }
        }

        do {
            throw AuthBrokerClientError.broker(
                try JSONDecoder().decode(AuthBrokerFailure.self, from: body)
            )
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
}
