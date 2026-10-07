import XCTest
@testable import Triage

final class GitHubRateLimitTests: XCTestCase {
    func testExpiredPrimaryResetStillPausesWithMissingResourceHeader() async throws {
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let controller = GitHubRateLimitController(now: { observedAt }, jitter: { $0 })
        try await controller.record(response: GitHubRESTResponse(
            statusCode: 403,
            url: URL(string: "https://api.github.com/search/issues")!,
            headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "999"],
            body: Data()
        ), fallbackResource: .search)
        let pause = await controller.pauseUntil(for: .search)
        XCTAssertEqual(pause, observedAt.addingTimeInterval(60))
    }

    func testSecondaryLimitNeverShortensServerRetryAfterToLocalCap() async throws {
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let controller = GitHubRateLimitController(now: { observedAt }, jitter: { $0 })
        try await controller.record(response: GitHubRESTResponse(
            statusCode: 403,
            url: URL(string: "https://api.github.com/search/issues")!,
            headers: ["Retry-After": "1800"],
            body: Data()
        ))
        let pause = await controller.pauseUntil(for: .graphql)
        XCTAssertEqual(pause, observedAt.addingTimeInterval(1_800))
    }

    func testParsesExhaustedSearchLimit() throws {
        let limit = try XCTUnwrap(
            GitHubRateLimit(headers: [
                "X-RateLimit-Resource": "search",
                "X-RateLimit-Limit": "30",
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": "1000"
            ])
        )

        XCTAssertEqual(limit.resource, .search)
        XCTAssertEqual(limit.remaining, 0)
        XCTAssertEqual(limit.resetAt, Date(timeIntervalSince1970: 1000))
    }

    func testRetryAfterTakesPriorityOverCoreReset() {
        let limit = GitHubRateLimit(headers: [
            "X-RateLimit-Resource": "core",
            "X-RateLimit-Remaining": "0",
            "X-RateLimit-Reset": "1000",
            "Retry-After": "60"
        ])!

        XCTAssertNotNil(limit.pauseUntil)
    }

    func testSecondaryLimitPausesEveryResourceWithDeterministicJitter() async throws {
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let controller = GitHubRateLimitController(
            now: { observedAt },
            jitter: { $0 }
        )
        let response = GitHubRESTResponse(
            statusCode: 403,
            url: URL(string: "https://api.github.com/search/issues")!,
            headers: ["Retry-After": "60"],
            body: Data()
        )

        try await controller.record(response: response)

        let corePause = await controller.pauseUntil(for: .core)
        let graphQLPause = await controller.pauseUntil(for: .graphql)
        XCTAssertEqual(corePause, Date(timeIntervalSince1970: 1_060))
        XCTAssertEqual(graphQLPause, Date(timeIntervalSince1970: 1_060))
    }

    func testHeaderlessSecondaryLimitUsesConservativePause() async throws {
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let controller = GitHubRateLimitController(
            now: { observedAt },
            jitter: { $0 }
        )
        let response = GitHubRESTResponse(
            statusCode: 403,
            url: URL(string: "https://api.github.com/graphql")!,
            headers: [:],
            body: Data(#"{"message":"You have exceeded a secondary rate limit."}"#.utf8)
        )

        try await controller.record(response: response, fallbackResource: .graphql)

        let searchPause = await controller.pauseUntil(for: .search)
        XCTAssertEqual(searchPause, Date(timeIntervalSince1970: 1_060))
    }

    func testPrioritizedWaiterRunsBeforeEarlierLowerPriorityWaiter() async throws {
        let controller = GitHubRateLimitController(maximumConcurrency: 1)
        let gate = TestGate()
        let highPriorityGate = TestGate()
        let starts = TestStarts()
        let firstStarted = expectation(description: "first request started")
        let highPriorityStarted = expectation(description: "high-priority request started")
        let lowPriorityStarted = expectation(description: "low-priority request started")

        let first = Task {
            try await controller.execute(resource: .core, priority: .fullReconciliation) {
                await starts.append("first")
                firstStarted.fulfill()
                await gate.wait()
            }
        }
        await fulfillment(of: [firstStarted], timeout: 1)

        let lowPriority = Task {
            try await controller.execute(resource: .core, priority: .inactiveAccountRefresh) {
                await starts.append("low")
                lowPriorityStarted.fulfill()
            }
        }
        let highPriority = Task {
            try await controller.execute(resource: .core, priority: .selectedWorkItemDetail) {
                await starts.append("high")
                highPriorityStarted.fulfill()
                await highPriorityGate.wait()
            }
        }
        await waitForQueuedRequestCount(2, controller: controller)
        await gate.open()

        await fulfillment(of: [highPriorityStarted], timeout: 1)
        let orderedStarts = await starts.values()
        XCTAssertEqual(orderedStarts, ["first", "high"])

        await highPriorityGate.open()
        _ = try await first.value
        _ = try await highPriority.value
        _ = try await lowPriority.value
        await fulfillment(of: [lowPriorityStarted], timeout: 1)
    }

    func testLowerPriorityWaiterEventuallyRunsUnderSustainedHigherPriorityWork() async throws {
        let controller = GitHubRateLimitController(maximumConcurrency: 1)
        let gate = TestGate()
        let starts = TestStarts()
        let firstStarted = expectation(description: "first request started")

        let first = Task {
            try await controller.execute(resource: .core, priority: .fullReconciliation) {
                await starts.append("first")
                firstStarted.fulfill()
                await gate.wait()
            }
        }
        await fulfillment(of: [firstStarted], timeout: 1)

        let lowerPriority = Task {
            try await controller.execute(resource: .core, priority: .fullReconciliation) {
                await starts.append("lower")
            }
        }
        await waitForQueuedRequestCount(1, controller: controller)
        let higherPriority = (0..<9).map { index in
            Task {
                try await controller.execute(resource: .core, priority: .selectedWorkItemDetail) {
                    await starts.append("higher-\(index)")
                }
            }
        }
        await waitForQueuedRequestCount(10, controller: controller)
        await gate.open()

        _ = try await first.value
        _ = try await lowerPriority.value
        for request in higherPriority {
            _ = try await request.value
        }

        let orderedStarts = await starts.values()
        XCTAssertEqual(orderedStarts.first, "first")
        XCTAssertEqual(orderedStarts.count, 11)
        guard orderedStarts.count == 11 else { return }
        XCTAssertEqual(orderedStarts[9], "lower")
    }

    private func waitForQueuedRequestCount(
        _ expectedCount: Int,
        controller: GitHubRateLimitController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let queued = expectation(description: "\(expectedCount) requests queued")
        let observer = Task {
            while !Task.isCancelled {
                if await controller.queuedRequestCount() >= expectedCount {
                    queued.fulfill()
                    return
                }
                await Task.yield()
            }
        }
        await fulfillment(of: [queued], timeout: 1)
        observer.cancel()
        let queuedRequestCount = await controller.queuedRequestCount()
        XCTAssertGreaterThanOrEqual(
            queuedRequestCount,
            expectedCount,
            file: file,
            line: line
        )
    }
}

private actor TestGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        continuations.removeFirst().resume()
    }
}

private actor TestStarts {
    private var recordedValues: [String] = []

    func append(_ value: String) {
        recordedValues.append(value)
    }

    func values() -> [String] {
        recordedValues
    }
}
