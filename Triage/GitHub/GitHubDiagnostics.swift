import Foundation
import OSLog

enum GitHubFailureKind: String, Codable, Sendable {
    case unauthorized
    case forbidden
    case notFound
    case rateLimited
    case secondaryRateLimited
    case serverFailure
    case unexpectedResponse
}

struct GitHubFailure: Error, Equatable, Sendable {
    let kind: GitHubFailureKind
    let statusCode: Int
    let requestID: String?
    let retryAfter: TimeInterval?
    let ssoHeader: GitHubSSOHeader?
    let accessRestriction: GitHubAccessRestriction?

    init(
        kind: GitHubFailureKind,
        statusCode: Int,
        requestID: String? = nil,
        retryAfter: TimeInterval? = nil,
        ssoHeader: GitHubSSOHeader? = nil,
        accessRestriction: GitHubAccessRestriction? = nil
    ) {
        self.kind = kind
        self.statusCode = statusCode
        self.requestID = requestID
        self.retryAfter = retryAfter
        self.ssoHeader = ssoHeader
        self.accessRestriction = accessRestriction
    }
}

enum GitHubFailureClassifier {
    static func classify(_ response: GitHubRESTResponse) -> GitHubFailure? {
        guard !(200...299).contains(response.statusCode) else { return nil }

        let retryAfter = response.header(named: "Retry-After").flatMap(TimeInterval.init)
        let kind: GitHubFailureKind
        switch response.statusCode {
        case 401:
            kind = .unauthorized
        case 403 where isSecondaryRateLimited(response):
            kind = .secondaryRateLimited
        case 403 where response.header(named: "X-RateLimit-Remaining") == "0":
            kind = .rateLimited
        case 403:
            kind = .forbidden
        case 404:
            kind = .notFound
        case 429:
            kind = .rateLimited
        case 500...599:
            kind = .serverFailure
        default:
            kind = .unexpectedResponse
        }

        return GitHubFailure(
            kind: kind,
            statusCode: response.statusCode,
            requestID: response.header(named: "X-GitHub-Request-Id"),
            retryAfter: retryAfter,
            ssoHeader: GitHubSSOHeader(value: response.header(named: "X-GitHub-SSO")),
            accessRestriction: accessRestriction(in: response)
        )
    }

    static func isSecondaryRateLimited(_ response: GitHubRESTResponse) -> Bool {
        guard response.statusCode == 403 else { return false }
        if response.header(named: "Retry-After") != nil {
            return true
        }
        guard let message = String(data: response.body, encoding: .utf8)?.lowercased() else {
            return false
        }
        return message.contains("secondary rate limit") || message.contains("abuse detection")
    }

    private static func accessRestriction(in response: GitHubRESTResponse) -> GitHubAccessRestriction? {
        guard response.statusCode == 403,
              let payload = try? JSONDecoder().decode(GitHubErrorPayload.self, from: response.body)
        else {
            return nil
        }
        let message = payload.message.lowercased()
        if message.contains("blocked due to organization policy") {
            return .organizationPolicyBlocked
        }
        if message.contains("oauth app access restrictions")
            || message.contains("oauth application approval") {
            return .oauthApplicationApprovalRequired
        }
        if message.contains("personal access token") && message.contains("pending approval") {
            return .organizationApprovalRequired
        }
        return nil
    }
}

private struct GitHubErrorPayload: Decodable {
    let message: String
}

enum GitHubDiagnostics {
    private static let logger = Logger(subsystem: "com.triage.mac", category: "GitHub")

    enum WorkspaceSnapshotAssemblyOutcome: String, Sendable {
        case accepted
        case revisionRejected = "revision-rejected"
    }

    /// Records one completed full-graph assembly using aggregate-only values.
    /// In particular, this must never receive scope, work-item, or revision
    /// identifiers because OSLog output can be collected for support.

    static func recordRatePause(resource: GitHubRateLimitResource, seconds: TimeInterval) {
        logger.notice("GitHub rate-limit pause: resource=\(resource.rawValue, privacy: .public), seconds=\(seconds, privacy: .public)")
    }


    static func recordReadRetry(code: Int) {
        logger.notice("Retrying interrupted GitHub read: transportCode=\(code, privacy: .public)")
    }



    static func recordDecodingFailure(_ error: DecodingError) {
        let kind: String
        let key: String?
        switch error {
        case let .keyNotFound(missing, _): kind = "keyNotFound"; key = missing.stringValue
        case let .valueNotFound(_, context): kind = "valueNotFound"; key = context.codingPath.last?.stringValue
        case let .typeMismatch(_, context): kind = "typeMismatch"; key = context.codingPath.last?.stringValue
        case let .dataCorrupted(context): kind = "dataCorrupted"; key = context.codingPath.last?.stringValue
        @unknown default: kind = "unknown"; key = nil
        }
        let allowed: Set<String> = [
            "data", "nodes", "id", "number", "title", "body", "url", "state",
            "createdAt", "updatedAt", "closedAt", "mergedAt", "isDraft", "locked",
            "comments", "totalCount", "author", "repository", "assignees", "labels",
            "reviewRequests", "requestedReviewer", "closingIssuesReferences", "isAnswered",
            "category", "isAnswerable", "rateLimit", "cost", "remaining", "resetAt"
        ]
        let field = key.flatMap { allowed.contains($0) ? $0 : nil } ?? "other"
        logger.error("GitHub response decoding failed: kind=\(kind, privacy: .public), field=\(field, privacy: .public)")
    }

    static func record(_ failure: GitHubFailure) {
        if failure.statusCode == 304 {
            logger.debug("GitHub conditional response: not modified")
            return
        }
        logger.error(
            "GitHub request failed: kind=\(failure.kind.rawValue, privacy: .public), status=\(failure.statusCode, privacy: .public), requestID=\(failure.requestID ?? "none", privacy: .private)"
        )
    }


}
