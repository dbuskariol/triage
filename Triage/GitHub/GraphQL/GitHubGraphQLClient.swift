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
    private let session: any HTTPSession
    private let credential: SecretValue

    init(session: any HTTPSession = URLSessionHTTPSession(), credential: SecretValue) {
        self.session = session
        self.credential = credential
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
        let (body, response) = try await session.data(for: request)
        guard body.count <= GitHubRESTTransport.maximumResponseBodyBytes else {
            throw GitHubGraphQLError.responseTooLarge
        }
        let metadata = GitHubRESTResponse(statusCode: response.statusCode, url: response.url ?? Self.endpoint, headers: [:], body: body)
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
