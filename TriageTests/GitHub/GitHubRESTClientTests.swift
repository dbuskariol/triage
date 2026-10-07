import XCTest
import Synchronization
@testable import Triage

final class GitHubRESTClientTests: XCTestCase {
    func testInterruptedReadRetriesWithoutCancellingRefresh() async throws {
        let session = InterruptedReadSession(cancelCaller: false)
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(session: session),
            credential: SecretValue("token"), rateLimitController: GitHubRateLimitController()
        )
        let value = try await client.get(OrganizationDTO.self, request: GitHubRESTRequest(path: "/user"))
        XCTAssertEqual(value.id, 1)
        let count = await session.requestCount
        XCTAssertEqual(count, 2)
    }

    func testCallerCancellationDoesNotRetryInterruptedRead() async throws {
        let session = InterruptedReadSession(cancelCaller: true)
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(session: session),
            credential: SecretValue("token"), rateLimitController: GitHubRateLimitController()
        )
        let task = Task {
            try await client.get(OrganizationDTO.self, request: GitHubRESTRequest(path: "/user"))
        }
        do {
            _ = try await task.value
            XCTFail("Expected caller cancellation.")
        } catch is CancellationError {}
        let count = await session.requestCount
        XCTAssertEqual(count, 1)
    }

    func testPrimary403WaitsForResetAndRetriesWithoutPermissionFailure() async throws {
        let clock = RetryClock()
        let session = RetrySession(
            statuses: [403, 200],
            failureHeaders: ["X-RateLimit-Resource": "core", "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1060"],
            failureMessage: "API rate limit exceeded"
        )
        let controller = GitHubRateLimitController(
            now: { clock.now }, sleep: { clock.advance($0) }, jitter: { $0 }
        )
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(session: session),
            credential: SecretValue("token"), rateLimitController: controller
        )
        let response = try await client.get(OrganizationDTO.self, request: GitHubRESTRequest(path: "/user"))
        XCTAssertEqual(response.id, 1)
        XCTAssertEqual(clock.delays, [60])
        let requests = await session.urls
        XCTAssertEqual(requests.count, 2)
    }

    func testPermission403IsNotRetried() async throws {
        let session = RetrySession(statuses: [403, 200], failureMessage: "Resource not accessible")
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(session: session),
            credential: SecretValue("token"), rateLimitController: GitHubRateLimitController()
        )
        do {
            _ = try await client.get(OrganizationDTO.self, request: GitHubRESTRequest(path: "/user"))
            XCTFail("Expected permission failure.")
        } catch let failure as GitHubFailure {
            XCTAssertEqual(failure.kind, .forbidden)
        }
        let requests = await session.urls
        XCTAssertEqual(requests.count, 1)
    }

    func testSecondaryLimitRetriesSamePageAfterAccountBackoff() async throws {
        let clock = RetryClock()
        let session = RetrySession(statuses: [403, 200])
        let controller = GitHubRateLimitController(
            now: { clock.now }, sleep: { clock.advance($0) }, jitter: { $0 }
        )
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(session: session),
            credential: SecretValue("token"), rateLimitController: controller
        )
        let response = try await client.get(
            OrganizationDTO.self, request: GitHubRESTRequest(path: "/user")
        )
        XCTAssertEqual(response.id, 1)
        let requests = await session.urls
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first, requests.last)
        XCTAssertEqual(clock.delays, [60])
    }

    func testSecondaryLimitRetriesAreBoundedAndIncreaseBackoff() async throws {
        let clock = RetryClock()
        let session = RetrySession(statuses: [403, 403, 403])
        let controller = GitHubRateLimitController(
            now: { clock.now }, sleep: { clock.advance($0) }, jitter: { $0 }
        )
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(session: session),
            credential: SecretValue("token"), rateLimitController: controller
        )
        do {
            _ = try await client.get(OrganizationDTO.self, request: GitHubRESTRequest(path: "/user"))
            XCTFail("Persistent rate limiting must remain an explicit failure.")
        } catch let failure as GitHubFailure {
            XCTAssertEqual(failure.kind, .secondaryRateLimited)
        }
        let requests = await session.urls
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(clock.delays, [60, 120])
    }

    func testCancellationDuringSecondaryBackoffDoesNotResend() async throws {
        let session = RetrySession(statuses: [403, 200])
        let controller = GitHubRateLimitController(sleep: { _ in throw CancellationError() })
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(session: session),
            credential: SecretValue("token"), rateLimitController: controller
        )
        do {
            _ = try await client.get(OrganizationDTO.self, request: GitHubRESTRequest(path: "/user"))
            XCTFail("Expected cancellation.")
        } catch is CancellationError {}
        let requests = await session.urls
        XCTAssertEqual(requests.count, 1)
    }

    func testClientDecodesAPageAndPreservesGitHubNextLink() async throws {
        let nextPage = "https://api.github.com/user/orgs?page=2"
        let session = StubSession(
            body: Data(#"[{"id":1,"login":"github"}]"#.utf8),
            headers: [
                "Link": "<\(nextPage)>; rel=\"next\", <https://api.github.com/user/orgs?page=3>; rel=\"last\"",
                "ETag": "\"etag\"",
                "Last-Modified": "Tue, 01 Sep 2026 00:00:00 GMT",
                "X-GitHub-SSO": "partial-results; organizations=21955855"
            ]
        )
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(session: session),
            credential: SecretValue("token")
        )

        let page = try await client.getPage(
            OrganizationDTO.self,
            request: try GitHubRESTRequest(path: "/user/orgs")
        )

        XCTAssertEqual(page.values, [OrganizationDTO(id: 1, login: "github")])
        XCTAssertEqual(page.nextPageURL?.absoluteString, nextPage)
        XCTAssertEqual(page.etag, "\"etag\"")
        XCTAssertEqual(page.lastModified, "Tue, 01 Sep 2026 00:00:00 GMT")
        XCTAssertEqual(page.ssoHeader, .partialResults(Set([21_955_855])))
    }

    func testClientDoesNotExposePrivateErrorBodies() async throws {
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(
                session: StubSession(statusCode: 401, body: Data(#"{"message":"private"}"#.utf8))
            ),
            credential: SecretValue("token")
        )

        do {
            _ = try await client.get(
                OrganizationDTO.self,
                request: try GitHubRESTRequest(path: "/user")
            )
            XCTFail("Expected authentication failure.")
        } catch let error as GitHubFailure {
            XCTAssertEqual(error.kind, .unauthorized)
            XCTAssertEqual(error.statusCode, 401)
        }
    }

    func testClientPreservesSuccessfulRawPayloadForProvenance() async throws {
        let payload = Data(#"{"id":1,"login":"github"}"#.utf8)
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(session: StubSession(body: payload)),
            credential: SecretValue("token")
        )

        let response = try await client.getResponse(
            OrganizationDTO.self,
            request: try GitHubRESTRequest(path: "/user")
        )

        XCTAssertEqual(response.value, OrganizationDTO(id: 1, login: "github"))
        XCTAssertEqual(response.payload, payload)
    }

    func testNextPageMustRemainOnGitHubAPI() {
        XCTAssertThrowsError(
            try GitHubRESTRequest(
                nextPageURL: URL(string: "https://example.com/user/orgs?page=2")!
            )
        )
    }

    func testClientRejectsMalformedPayloadWithoutReturningAnEmptyPage() async throws {
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(session: StubSession(body: Data("{".utf8))),
            credential: SecretValue("token")
        )

        do {
            _ = try await client.getPage(
                OrganizationDTO.self,
                request: try GitHubRESTRequest(path: "/user/orgs")
            )
            XCTFail("Expected malformed response failure.")
        } catch let error as GitHubRESTClientError {
            XCTAssertEqual(error, .invalidJSON)
        }
    }

    func testProvenancePageAPIPreservesMalformedPayloadWithoutExposingItAsAnError() async throws {
        let payload = Data(#"{"token":"ghp_privateMalformedPayload""#.utf8)
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(session: StubSession(
                body: payload,
                headers: [
                    "ETag": "malformed-etag",
                    "Last-Modified": "Tue, 01 Sep 2026 00:00:00 GMT"
                ]
            )),
            credential: SecretValue("token")
        )

        let result = try await client.getPagePreservingUndecodablePayload(
            OrganizationDTO.self,
            request: GitHubRESTRequest(path: "/user/orgs")
        )

        guard case let .undecodable(page) = result else {
            return XCTFail("Malformed JSON must remain distinguishable from an authoritative empty page.")
        }
        XCTAssertEqual(page.payload, payload)
        XCTAssertEqual(page.etag, "malformed-etag")
        XCTAssertEqual(page.lastModified, "Tue, 01 Sep 2026 00:00:00 GMT")
    }

    func testProvenanceResponseAPIPreservesMalformedPayloadWithoutTreatingItAsEmpty() async throws {
        let payload = Data(#"{"token":"ghp_privateMalformedResponse""#.utf8)
        let client = GitHubRESTClient(
            transport: try GitHubRESTTransport(session: StubSession(
                body: payload,
                headers: [
                    "ETag": "malformed-response-etag",
                    "Last-Modified": "Tue, 01 Sep 2026 00:00:00 GMT"
                ]
            )),
            credential: SecretValue("token")
        )

        let result = try await client.getResponsePreservingUndecodablePayload(
            OrganizationDTO.self,
            request: GitHubRESTRequest(path: "/user")
        )

        guard case let .undecodable(response) = result else {
            return XCTFail("Malformed JSON must remain distinguishable from an authoritative object.")
        }
        XCTAssertEqual(response.payload, payload)
        XCTAssertEqual(response.etag, "malformed-response-etag")
        XCTAssertEqual(response.lastModified, "Tue, 01 Sep 2026 00:00:00 GMT")
    }
}

private struct OrganizationDTO: Codable, Equatable, Sendable {
    let id: UInt64
    let login: String
}

private final class RetryClock: Sendable {
    private let state = Mutex((date: Date(timeIntervalSince1970: 1_000), delays: [TimeInterval]()))
    var now: Date { state.withLock { $0.date } }
    var delays: [TimeInterval] { state.withLock { $0.delays } }
    func advance(_ duration: TimeInterval) {
        state.withLock {
            $0.date.addTimeInterval(duration)
            $0.delays.append(duration)
        }
    }
}

private actor RetrySession: HTTPSession {
    let statuses: [Int]
    let failureHeaders: [String: String]
    let failureMessage: String
    private(set) var urls: [URL] = []
    init(statuses: [Int], failureHeaders: [String: String] = [:], failureMessage: String = "secondary rate limit") {
        self.statuses = statuses
        self.failureHeaders = failureHeaders
        self.failureMessage = failureMessage
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let status = statuses[min(urls.count, statuses.count - 1)]
        urls.append(request.url!)
        return (
            status == 200
                ? Data(#"{"id":1,"login":"github"}"#.utf8)
                : try JSONSerialization.data(withJSONObject: ["message": failureMessage]),
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: status == 200 ? [:] : failureHeaders)!
        )
    }
}

private actor InterruptedReadSession: HTTPSession {
    let cancelCaller: Bool
    private(set) var requestCount = 0

    init(cancelCaller: Bool) { self.cancelCaller = cancelCaller }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        if requestCount == 1 {
            if cancelCaller { withUnsafeCurrentTask { $0?.cancel() } }
            throw URLError(.cancelled)
        }
        return (
            Data(#"{"id":1,"login":"github"}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

private actor StubSession: HTTPSession {
    private let statusCode: Int
    private let body: Data
    private let headers: [String: String]

    init(
        statusCode: Int = 200,
        body: Data = Data(),
        headers: [String: String] = [:]
    ) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (
            body,
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            )!
        )
    }
}
