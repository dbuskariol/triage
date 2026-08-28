import AppKit
import Foundation

@MainActor
final class SSOAuthorizationCoordinator {
    func authorizeInBrowser(_ header: GitHubSSOHeader) -> Bool {
        guard case let .authorizationRequired(url) = header else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}
