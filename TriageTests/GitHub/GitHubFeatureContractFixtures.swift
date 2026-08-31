import Foundation
@testable import Triage

/// Deterministic, network-free response corpus for GitHub source-contract tests.
///
/// These fixtures intentionally model transport evidence rather than normalized
/// records, so tests can verify that failures remain distinguishable from an
/// authoritative empty result.
enum GitHubFeatureContractFixtures {
    struct HTTPResponse: Sendable {
        let statusCode: Int
        let body: Data
        let headers: [String: String]

        init(statusCode: Int = 200, body: Data, headers: [String: String] = [:]) {
            self.statusCode = statusCode
            self.body = body
            self.headers = headers
        }
    }

    actor Session: HTTPSession {
        private var responses: [HTTPResponse]
        private var requests = [URLRequest]()

        init(responses: [HTTPResponse]) {
            self.responses = responses
        }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            guard !responses.isEmpty else { throw URLError(.resourceUnavailable) }
            requests.append(request)
            let response = responses.removeFirst()
            return (
                response.body,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: response.statusCode,
                    httpVersion: nil,
                    headerFields: response.headers
                )!
            )
        }

        func requestedURLs() -> [URL] {
            requests.compactMap(\.url)
        }

        func requestCount() -> Int {
            requests.count
        }
    }

    actor ScopeThatExpiresAfterNetworkResponse {
        private var validations = 0

        func validate() throws {
            validations += 1
            // Discussion traversal validates before request construction, before
            // each request, and after each response. Expiring here models a
            // credential/capability revision becoming stale in flight.
            if validations >= 3 {
                throw CancellationError()
            }
        }
    }

    actor SuspendedSession: HTTPSession {
        private var requestStarted = false
        private var requestWaiter: CheckedContinuation<Void, Never>?
        private var responseWaiter: CheckedContinuation<(Data, HTTPURLResponse), Error>?

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requestStarted = true
            requestWaiter?.resume()
            requestWaiter = nil
            return try await withCheckedThrowingContinuation { continuation in
                responseWaiter = continuation
            }
        }

        func waitForRequest() async {
            guard !requestStarted else { return }
            await withCheckedContinuation { continuation in
                requestWaiter = continuation
            }
        }

        func resume(statusCode: Int = 200, body: Data) {
            let response = HTTPURLResponse(
                url: URL(string: "https://api.github.com/graphql")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            responseWaiter?.resume(returning: (body, response))
            responseWaiter = nil
        }
    }

    static func repository(
        id: UInt64,
        nodeID: String,
        name: String = "repo"
    ) -> String {
        """
        {"id":\(id),"node_id":"\(nodeID)","name":"\(name)","private":true,"archived":false,"has_discussions":true,"html_url":"https://github.com/acme/\(name)","updated_at":"2026-08-30T00:00:00Z","owner":{"login":"acme"}}
        """
    }

    static func repositoryPage(count: Int) -> Data {
        guard count > 0 else { return Data("[]".utf8) }

        var repositories = [String]()
        repositories.reserveCapacity(count)
        for index in 1 ... count {
            let repositoryID = UInt64(index)
            let nodeID = "R_\(index)"
            let name = "repo-\(index)"
            repositories.append(repository(id: repositoryID, nodeID: nodeID, name: name))
        }

        let payload = "[" + repositories.joined(separator: ",") + "]"
        return Data(payload.utf8)
    }

    static func discussionPage(
        repositoryNodeID: String = "R_1",
        discussionNodeID: String = "D_1",
        discussionNumber: Int = 1,
        hasNextPage: Bool,
        endCursor: String?,
        cost: Int = 1
    ) -> Data {
        Data(
            """
            {"data":{"node":{"id":"\(repositoryNodeID)","discussions":{"nodes":[{"id":"\(discussionNodeID)","number":\(discussionNumber),"title":"Fixture discussion","body":null,"url":"https://github.com/acme/repo/discussions/\(discussionNumber)","createdAt":"2026-08-30T00:00:00Z","updatedAt":"2026-08-30T00:00:00Z","closedAt":null,"isAnswered":false,"category":null,"answer":null,"comments":{"totalCount":0}}],"pageInfo":{"hasNextPage":\(hasNextPage),"endCursor":\(endCursor.map { "\"\($0)\"" } ?? "null")}}},"rateLimit":{"cost":\(cost),"remaining":4999,"resetAt":"2026-08-31T00:00:00Z"}}}
            """.utf8
        )
    }

    static let partialGraphQL = Data(
        #"{"data":{"viewer":{"login":"octocat"}},"errors":[{"message":"field unavailable","path":["viewer","email"],"extensions":{"code":"FORBIDDEN"}}]}"#.utf8
    )

    static let malformedJSON = Data(#"{"data":{"viewer":"not-an-object"}"#.utf8)

    static let incompleteSearch = Data(
        #"{"total_count":1001,"incomplete_results":true,"items":[]}"#.utf8
    )
}
