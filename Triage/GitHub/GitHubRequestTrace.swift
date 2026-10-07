import Foundation
import OSLog

struct GitHubRequestTrace {
    private static let logger = Logger(subsystem: "com.triage.mac", category: "API")
    private let id = UUID().uuidString
    private let started = ContinuousClock.now
    private let operation: String

    /// Call only with a static REST category or a registered GraphQL operation
    /// name, never a URL, query string, header, or response body.
    init(operation: String) {
        self.operation = operation
        let requestID = id
        Self.logger.notice("request=\(requestID, privacy: .public) operation=\(operation, privacy: .public) outcome=started")
    }

    func finish(statusCode: Int, bytes: Int) {
        Self.logger.notice("request=\(id, privacy: .public) operation=\(operation, privacy: .public) outcome=response status=\(statusCode, privacy: .public) bytes=\(bytes, privacy: .public) duration=\(String(describing: started.duration(to: .now)), privacy: .public)")
    }

    func fail(_ error: Error) {
        Self.logger.error("request=\(id, privacy: .public) operation=\(operation, privacy: .public) outcome=failed errorType=\(String(reflecting: type(of: error)), privacy: .public) duration=\(String(describing: started.duration(to: .now)), privacy: .public)")
    }

    static func restCategory(path: String?) -> String {
        guard let path else { return "REST.other" }
        if path == "/search/issues" { return "REST.personal-search" }
        if path == "/user" { return "REST.identity" }
        if path == "/user/teams" { return "REST.personal-teams" }
        if path == "/user/orgs" { return "REST.account-organizations" }
        let parts = path.split(separator: "/")
        if parts.first == "notifications"
            || (parts.first == "repos" && parts.count == 4 && parts.last == "notifications") {
            return "REST.notifications"
        }
        if parts.count >= 4 {
            if parts.last == "timeline" { return "REST.timeline" }
            if parts.last == "reviews" { return "REST.reviews" }
            if parts.last == "comments" { return "REST.comments" }
            if parts.last == "check-runs" || parts.last == "status" { return "REST.status-checks" }
        }
        let resourceIndex = parts.first == "repos" ? 3 : parts.first == "repositories" ? 2 : 0
        if resourceIndex > 0, parts.count > resourceIndex + 1 {
            if parts[resourceIndex] == "issues" { return "REST.issue-details" }
            if parts[resourceIndex] == "pulls" { return "REST.pull-request-details" }
        }
        if path.hasPrefix("/repos/") || path.hasPrefix("/repositories/") { return "REST.repository-metadata" }
        if path.hasPrefix("/orgs/") || path.hasPrefix("/organizations/") { return "REST.organization-access" }
        return "REST.other"
    }
}
