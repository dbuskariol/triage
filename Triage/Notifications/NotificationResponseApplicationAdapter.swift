import Foundation

/// Main-actor boundary between macOS notification responses and application
/// presentation. The adapter intentionally exposes no GitHub client or source
/// repository, so response actions can affect only local navigation/workflow.
@MainActor
protocol NotificationLocalRouteHandling: AnyObject {
    func handleNotificationLocalAction(_ action: NotificationLocalAction) async
}

@MainActor
final class NotificationResponseApplicationAdapter: NotificationLocalActionHandling {
    private weak var routeHandler: (any NotificationLocalRouteHandling)?

    init(routeHandler: (any NotificationLocalRouteHandling)? = nil) {
        self.routeHandler = routeHandler
    }

    func install(routeHandler: any NotificationLocalRouteHandling) {
        self.routeHandler = routeHandler
    }

    func handle(_ action: NotificationLocalAction) async {
        await routeHandler?.handleNotificationLocalAction(action)
    }
}
