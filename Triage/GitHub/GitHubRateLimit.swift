import Foundation

enum GitHubRateLimitResource: String, CaseIterable, Sendable {
    case core
    case search
    case graphql
}

struct GitHubRateLimit: Equatable, Sendable {
    let resource: GitHubRateLimitResource
    let limit: Int?
    let remaining: Int?
    let resetAt: Date?
    let retryAfter: TimeInterval?
    let observedAt: Date

    init?(headers: [String: String], now: Date = .now) {
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        guard let resource = header("X-RateLimit-Resource").flatMap(GitHubRateLimitResource.init(rawValue:)) else {
            return nil
        }
        self.resource = resource
        limit = header("X-RateLimit-Limit").flatMap(Int.init)
        remaining = header("X-RateLimit-Remaining").flatMap(Int.init)
        resetAt = header("X-RateLimit-Reset")
            .flatMap(TimeInterval.init)
            .map { Date(timeIntervalSince1970: $0) }
        retryAfter = header("Retry-After").flatMap(TimeInterval.init)
        if retryAfter == nil, remaining == 0, resetAt == nil {
            return nil
        }
        observedAt = now
    }

    var pauseUntil: Date? {
        if let retryAfter {
            return observedAt.addingTimeInterval(retryAfter)
        }
        guard remaining == 0 else { return nil }
        return resetAt
    }
}

actor GitHubRateLimitController {
    private var limits: [GitHubRateLimitResource: GitHubRateLimit] = [:]

    func record(response: GitHubRESTResponse, now: Date = .now) {
        guard let limit = GitHubRateLimit(headers: response.headers, now: now) else { return }
        limits[limit.resource] = limit
    }

    func pauseUntil(for resource: GitHubRateLimitResource, now: Date = .now) -> Date? {
        guard let pauseUntil = limits[resource]?.pauseUntil, pauseUntil > now else { return nil }
        return pauseUntil
    }
}
