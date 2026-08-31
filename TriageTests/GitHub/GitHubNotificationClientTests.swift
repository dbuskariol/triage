import XCTest
@testable import Triage

final class GitHubNotificationClientTests: XCTestCase {
    func testNotificationsUseExactLinkPaginationAndPreserveImmutablePages() async throws {
        let second = "https://api.github.com/notifications?all=true&participating=false&per_page=100&page=2"
        let session = NotificationPagingSession(responses: [
            "/notifications?all=true&participating=false&per_page=100": (
                Data("[\(notification(id: "n-1", reason: "review_requested"))]".utf8),
                ["Link": "<\(second)>; rel=\"next\"", "ETag": "\"notice-v1\""],
                200
            ),
            "/notifications?all=true&participating=false&per_page=100&page=2": (
                Data("[\(notification(id: "n-2", reason: "comment"))]".utf8),
                [:],
                200
            )
        ])

        let inventory = try await notificationClient(session: session).allNotifications()

        XCTAssertEqual(inventory.notifications.map(\.id), ["n-1", "n-2"])
        XCTAssertEqual(inventory.notifications.map(\.knownReason), [.reviewRequested, .comment])
        XCTAssertEqual(inventory.pages.map(\.endpoint), [
            "/notifications?all=true&participating=false&per_page=100",
            "/notifications?all=true&participating=false&per_page=100&page=2"
        ])
        XCTAssertEqual(inventory.pages.first?.page.etag, "\"notice-v1\"")
        let requestCount = await session.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testConditionalNotificationsUseETagPrecedenceAndDoNotInventEmptySuccess() async throws {
        let session = NotificationPagingSession(responses: [
            "/notifications?all=true&participating=false&per_page=100": (Data(), [:], 304)
        ])
        let result = try await notificationClient(session: session).fetchNotifications(
            validators: try GitHubHTTPValidators(
                eTag: "\"notice-v1\"",
                lastModified: "Wed, 21 Oct 2015 07:28:00 GMT"
            )
        )

        guard case .notModified = result else {
            return XCTFail("304 is a conditional source state, never an empty notification success.")
        }
        let eTag = await session.header(named: "If-None-Match")
        let lastModified = await session.header(named: "If-Modified-Since")
        XCTAssertEqual(eTag, "\"notice-v1\"")
        XCTAssertNil(lastModified)
    }

    func testAllNotificationsRejectsUnsolicitedNotModified() async throws {
        let session = NotificationPagingSession(responses: [
            "/notifications?all=true&participating=false&per_page=100": (Data(), [:], 304)
        ])

        do {
            _ = try await notificationClient(session: session).allNotifications()
            XCTFail("An unsolicited 304 has no local notification replay authority.")
        } catch {
            XCTAssertEqual(error as? GitHubNotificationClientError, .unexpectedNotModified)
        }
    }

    func testInvalidPaginationCannotBroadenNotificationQuery() async throws {
        let invalidLinks = [
            "https://api.github.com/notifications?all=false&participating=false&per_page=100&page=2",
            "https://api.github.com/notifications?all=true&participating=true&per_page=100&page=2",
            "https://api.github.com/notifications?all=true&participating=false&per_page=99&page=2",
            "https://api.github.com/notifications?all=true&participating=false&per_page=100&page=3",
            "https://api.github.com/notifications?all=true&participating=false&per_page=100&page=02",
            "https://api.github.com/notifications?all=true&participating=false&per_page=100&page=2&since=2026-01-01",
            "https://api.github.com/user/notifications?all=true&participating=false&per_page=100&page=2"
        ]
        for link in invalidLinks {
            let session = NotificationPagingSession(responses: [
                "/notifications?all=true&participating=false&per_page=100": (
                    Data("[\(notification(id: "n-1", reason: "comment"))]".utf8),
                    ["Link": "<\(link)>; rel=\"next\""],
                    200
                )
            ])
            do {
                _ = try await notificationClient(session: session).allNotifications()
                XCTFail("Invalid notification pagination must fail closed: \(link)")
            } catch {
                XCTAssertTrue(
                    error as? GitHubNotificationClientError == .invalidPaginationLink
                        || error as? GitHubNotificationClientError == .paginationLoop,
                    "Unexpected error for \(link): \(error)"
                )
            }
            let requestCount = await session.requestCount()
            XCTAssertEqual(requestCount, 1)
        }
    }

    func testDuplicateNotificationIDsFailClosedRatherThanCollapsingEvidence() async throws {
        let second = "https://api.github.com/notifications?all=true&participating=false&per_page=100&page=2"
        let session = NotificationPagingSession(responses: [
            "/notifications?all=true&participating=false&per_page=100": (
                Data("[\(notification(id: "n-1", reason: "comment"))]".utf8),
                ["Link": "<\(second)>; rel=\"next\""],
                200
            ),
            "/notifications?all=true&participating=false&per_page=100&page=2": (
                Data("[\(notification(id: "n-1", reason: "comment"))]".utf8),
                [:],
                200
            )
        ])

        do {
            _ = try await notificationClient(session: session).allNotifications()
            XCTFail("Duplicate IDs cannot be silently collapsed in immutable source provenance.")
        } catch {
            XCTAssertEqual(error as? GitHubNotificationClientError, .duplicateNotification)
        }
    }

    func testNotificationsRejectAnOverLimitLaterPageBeforeReturningInventory() async throws {
        let second = "https://api.github.com/notifications?all=true&participating=false&per_page=100&page=2"
        let overLimitPage = (1 ... 101).map { index in
            notification(id: "n-\(index)", reason: "comment")
        }.joined(separator: ",")
        let firstPayload = Data(("[" + notification(id: "n-first", reason: "comment") + "]").utf8)
        let session = NotificationPagingSession(responses: [
            "/notifications?all=true&participating=false&per_page=100": (
                firstPayload,
                ["Link": "<\(second)>; rel=\"next\""],
                200
            ),
            "/notifications?all=true&participating=false&per_page=100&page=2": (
                Data("[\(overLimitPage)]".utf8),
                [:],
                200
            )
        ])

        do {
            _ = try await notificationClient(session: session).allNotifications()
            XCTFail("An over-limit later page must not produce an inventory.")
        } catch {
            XCTAssertEqual(error as? GitHubNotificationClientError, .pageObjectLimitExceeded)
        }
        let requestCount = await session.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testUnknownServerReasonIsPreservedAsDiscoveryMetadata() async throws {
        let session = NotificationPagingSession(responses: [
            "/notifications?all=true&participating=false&per_page=100": (
                Data("[\(notification(id: "n-1", reason: "new_reason"))]".utf8),
                [:],
                200
            )
        ])

        let inventory = try await notificationClient(session: session).allNotifications()

        XCTAssertEqual(inventory.notifications.single?.reason, "new_reason")
        XCTAssertNil(inventory.notifications.single?.knownReason)
    }

    private func notificationClient(session: NotificationPagingSession) throws -> GitHubNotificationClient {
        GitHubNotificationClient(client: GitHubRESTClient(
            transport: try GitHubRESTTransport(session: session),
            credential: SecretValue("token")
        ))
    }

    private func notification(id: String, reason: String) -> String {
        """
        {"id":"\(id)","unread":true,"reason":"\(reason)","updated_at":"2026-08-30T12:00:00Z",
        "last_read_at":null,"repository":{"id":1,"node_id":"R_1","name":"widget","full_name":"acme/widget","owner":{"login":"acme"}},
        "subject":{"title":"Review requested","url":"https://api.github.com/repos/acme/widget/pulls/1","latest_comment_url":null,"type":"PullRequest"}}
        """
    }
}

private actor NotificationPagingSession: HTTPSession {
    private let responses: [String: (Data, [String: String], Int)]
    private var requests = [URLRequest]()

    init(responses: [String: (Data, [String: String], Int)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        requests.append(request)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        let key = [url.path, query].compactMap { $0 }.joined(separator: "?")
        guard let response = responses[key] else { throw URLError(.resourceUnavailable) }
        return (
            response.0,
            HTTPURLResponse(url: url, statusCode: response.2, httpVersion: nil, headerFields: response.1)!
        )
    }

    func requestCount() -> Int { requests.count }

    func header(named name: String) -> String? {
        requests.last?.value(forHTTPHeaderField: name)
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
