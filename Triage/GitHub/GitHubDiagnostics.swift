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

    init(
        kind: GitHubFailureKind,
        statusCode: Int,
        requestID: String? = nil,
        retryAfter: TimeInterval? = nil,
        ssoHeader: GitHubSSOHeader? = nil
    ) {
        self.kind = kind
        self.statusCode = statusCode
        self.requestID = requestID
        self.retryAfter = retryAfter
        self.ssoHeader = ssoHeader
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
            ssoHeader: GitHubSSOHeader(value: response.header(named: "X-GitHub-SSO"))
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
}

enum GitHubDiagnostics {
    private static let logger = Logger(subsystem: "com.triage.mac", category: "GitHub")

    static func record(_ failure: GitHubFailure) {
        logger.error(
            "GitHub request failed: kind=\(failure.kind.rawValue, privacy: .public), status=\(failure.statusCode, privacy: .public), requestID=\(failure.requestID ?? "none", privacy: .private)"
        )
    }
}
