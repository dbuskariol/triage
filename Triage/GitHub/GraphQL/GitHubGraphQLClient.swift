import Foundation

enum GitHubGraphQLError: Error, Equatable, Sendable {
    case mutationRejected
    case invalidQuery
    case invalidResponse
    case responseTooLarge
    case partialResponse
    case missingData
    case requestFailed(GitHubFailure)
}

struct GitHubGraphQLQuery: Sendable {
    let document: String
    let operationName: String

    init(document: String, operationName: String) throws {
        let normalized = document.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("query"),
              !normalized.localizedCaseInsensitiveContains("mutation"),
              !normalized.isEmpty,
              !operationName.isEmpty
        else {
            throw GitHubGraphQLError.mutationRejected
        }
        self.document = normalized
        self.operationName = operationName
    }
}

enum GitHubGraphQLErrorPathComponent: Codable, Equatable, Sendable {
    case field(String)
    case index(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let index = try? container.decode(Int.self) {
            self = .index(index)
        } else {
            self = .field(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .field(value):
            try container.encode(value)
        case let .index(value):
            try container.encode(value)
        }
    }
}

struct GitHubGraphQLPartialError: Codable, Equatable, Sendable {
    let message: String
    let path: [GitHubGraphQLErrorPathComponent]?
    let type: String?
    let extensions: Extensions?

    struct Extensions: Codable, Equatable, Sendable {
        let code: String?
        let type: String?
    }
}

struct GitHubGraphQLResponseMetadata: Equatable, Sendable {
    let requestID: String?
    let retryAfter: TimeInterval?
    let ssoHeader: GitHubSSOHeader?
}

struct GitHubGraphQLResponse<Value: Decodable & Sendable>: Sendable {
    let data: Value?
    let errors: [GitHubGraphQLPartialError]
    let payload: Data
    let metadata: GitHubGraphQLResponseMetadata
}

struct GitHubGraphQLUndecodableResponse: Equatable, Sendable {
    let payload: Data
    let errors: [GitHubGraphQLPartialError]
    let metadata: GitHubGraphQLResponseMetadata
}

enum GitHubGraphQLDecodingResult<Value: Decodable & Sendable>: Sendable {
    case response(GitHubGraphQLResponse<Value>)
    case undecodable(GitHubGraphQLUndecodableResponse)
}

actor GitHubGraphQLClient {
    private static let endpoint = URL(string: "https://api.github.com/graphql")!
    private static let maximumResponseBodyBytes = 4 * 1_024 * 1_024
    private let session: any HTTPSession
    private let credential: SecretValue
    private let rateLimitController: GitHubRateLimitController?
    private let requestPriority: GitHubRequestPriority

    init(
        session: any HTTPSession = URLSessionHTTPSession(),
        credential: SecretValue,
        rateLimitController: GitHubRateLimitController? = nil,
        requestPriority: GitHubRequestPriority = .inboxCandidateHydration
    ) {
        self.session = session
        self.credential = credential
        self.rateLimitController = rateLimitController
        self.requestPriority = requestPriority
    }

    func execute<Value: Decodable & Sendable, Variables: Encodable & Sendable>(
        _ query: GitHubGraphQLQuery,
        variables: Variables,
        as type: Value.Type
    ) async throws -> GitHubGraphQLResponse<Value> {
        switch try await executePreservingUndecodableResponse(
            query,
            variables: variables,
            as: type
        ) {
        case let .response(response):
            return response
        case .undecodable:
            throw GitHubGraphQLError.invalidResponse
        }
    }

    func executePreservingUndecodableResponse<
        Value: Decodable & Sendable,
        Variables: Encodable & Sendable
    >(
        _ query: GitHubGraphQLQuery,
        variables: Variables,
        as type: Value.Type
    ) async throws -> GitHubGraphQLDecodingResult<Value> {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential.rawValue)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(GitHubRESTTransport.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.httpBody = try JSONEncoder().encode(
            GraphQLRequest(query: query.document, operationName: query.operationName, variables: variables)
        )
        let (body, response) = try await send(request)
        try Task.checkCancellation()
        guard body.count <= Self.maximumResponseBodyBytes else {
            throw GitHubGraphQLError.responseTooLarge
        }
        let metadata = GitHubRESTResponse(
            statusCode: response.statusCode,
            url: response.url ?? Self.endpoint,
            headers: Self.headers(from: response),
            body: body
        )
        if let failure = GitHubFailureClassifier.classify(metadata) {
            throw GitHubGraphQLError.requestFailed(failure)
        }
        let responseMetadata = GitHubGraphQLResponseMetadata(
            requestID: metadata.header(named: "X-GitHub-Request-Id"),
            retryAfter: metadata.header(named: "Retry-After").flatMap(TimeInterval.init),
            ssoHeader: GitHubSSOHeader(value: metadata.header(named: "X-GitHub-SSO"))
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let decoded = try decoder.decode(GraphQLPayload<Value>.self, from: body)
            return .response(
                GitHubGraphQLResponse(
                    data: decoded.data,
                    errors: decoded.errors ?? [],
                    payload: body,
                    metadata: responseMetadata
                )
            )
        } catch {
            let errors = (try? decoder.decode(GraphQLErrorEnvelope.self, from: body).errors) ?? []
            return .undecodable(
                GitHubGraphQLUndecodableResponse(
                    payload: body,
                    errors: errors,
                    metadata: responseMetadata
                )
            )
        }
    }

    /// Executes a document only when GitHub returned a complete, usable payload.
    /// Synchronizers use this to prevent partial GraphQL data from becoming
    /// authoritative normalized state.
    func executeComplete<Value: Decodable & Sendable, Variables: Encodable & Sendable>(
        _ query: GitHubGraphQLQuery,
        variables: Variables,
        as type: Value.Type
    ) async throws -> Value {
        let response = try await execute(query, variables: variables, as: type)
        guard response.errors.isEmpty else {
            throw GitHubGraphQLError.partialResponse
        }
        guard let data = response.data else {
            throw GitHubGraphQLError.missingData
        }
        return data
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let rateLimitController else {
            return try await boundedData(for: request)
        }
        return try await rateLimitController.execute(
            resource: .graphql,
            priority: requestPriority
        ) {
            let result = try await self.boundedData(for: request)
            let metadata = GitHubRESTResponse(
                statusCode: result.1.statusCode,
                url: result.1.url ?? Self.endpoint,
                headers: Self.headers(from: result.1),
                body: result.0
            )
            try await rateLimitController.record(response: metadata, fallbackResource: .graphql)
            return result
        }
    }

    private static func headers(from response: HTTPURLResponse) -> [String: String] {
        return response.allHeaderFields.reduce(into: [String: String]()) { headers, entry in
            guard let name = entry.key as? String else { return }
            headers[name] = String(describing: entry.value)
        }
    }

    private func boundedData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            if let boundedSession = session as? any BoundedHTTPSession {
                return try await boundedSession.data(
                    for: request,
                    maximumResponseBodyBytes: Self.maximumResponseBodyBytes
                )
            }
            let result = try await session.data(for: request)
            guard result.0.count <= Self.maximumResponseBodyBytes else {
                throw GitHubGraphQLError.responseTooLarge
            }
            return result
        } catch GitHubTransportError.responseTooLarge {
            throw GitHubGraphQLError.responseTooLarge
        }
    }
}

private struct GraphQLRequest<Variables: Encodable>: Encodable {
    let query: String
    let operationName: String
    let variables: Variables
}

private struct GraphQLPayload<Value: Decodable>: Decodable {
    let data: Value?
    let errors: [GitHubGraphQLPartialError]?
}

private struct GraphQLErrorEnvelope: Decodable {
    let errors: [GitHubGraphQLPartialError]
}
