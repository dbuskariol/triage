import Foundation

enum GitHubGraphQLError: Error, Equatable, Sendable {
    case mutationRejected
    case invalidQuery
    case invalidResponse
    case responseTooLarge
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

struct GitHubGraphQLPartialError: Codable, Equatable, Sendable {
    let message: String
    let path: [String]?
}

struct GitHubGraphQLResponse<Value: Decodable & Sendable>: Sendable {
    let data: Value?
    let errors: [GitHubGraphQLPartialError]
}

actor GitHubGraphQLClient {
    private static let endpoint = URL(string: "https://api.github.com/graphql")!
    private static let maximumResponseBodyBytes = 4 * 1_024 * 1_024
    private let session: any HTTPSession
    private let credential: SecretValue
    private let rateLimitController: GitHubRateLimitController?

    init(
        session: any HTTPSession = URLSessionHTTPSession(),
        credential: SecretValue,
        rateLimitController: GitHubRateLimitController? = nil
    ) {
        self.session = session
        self.credential = credential
        self.rateLimitController = rateLimitController
    }

    func execute<Value: Decodable & Sendable, Variables: Encodable & Sendable>(
        _ query: GitHubGraphQLQuery,
        variables: Variables,
        as type: Value.Type
    ) async throws -> GitHubGraphQLResponse<Value> {
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
        do {
            let decoded = try JSONDecoder().decode(GraphQLPayload<Value>.self, from: body)
            return GitHubGraphQLResponse(data: decoded.data, errors: decoded.errors ?? [])
        } catch {
            throw GitHubGraphQLError.invalidResponse
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let rateLimitController else {
            return try await boundedData(for: request)
        }
        return try await rateLimitController.execute(
            resource: .graphql,
            priority: .inboxCandidateHydration
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
