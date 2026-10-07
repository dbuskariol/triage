import Foundation
import Sparkle

enum AppUpdateCheckInterval: TimeInterval, CaseIterable, Identifiable {
    case daily = 86_400
    case weekly = 604_800

    var id: Self { self }
    var title: String { self == .daily ? "Daily" : "Weekly" }
}

@MainActor
final class SoftwareUpdateController: ObservableObject {
    private let updaterController: SPUStandardUpdaterController

    /// Fixture launches construct the controller only to satisfy the shared
    /// SwiftUI environment; they must not start Sparkle's updater or its
    /// automatic update schedule.
    init(startingUpdater: Bool = true) {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var automaticallyChecksForUpdates: Bool {
        updaterController.updater.automaticallyChecksForUpdates
    }

    var automaticallyDownloadsUpdates: Bool {
        updaterController.updater.automaticallyDownloadsUpdates
    }

    var updateCheckInterval: AppUpdateCheckInterval {
        AppUpdateCheckInterval(rawValue: updaterController.updater.updateCheckInterval) ?? .daily
    }

    var canCheckForUpdates: Bool { updaterController.updater.canCheckForUpdates }
    var lastUpdateCheckDate: Date? { updaterController.updater.lastUpdateCheckDate }
    var allowsAutomaticUpdates: Bool { updaterController.updater.allowsAutomaticUpdates }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updaterController.updater.automaticallyChecksForUpdates = enabled
        objectWillChange.send()
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        updaterController.updater.automaticallyDownloadsUpdates = enabled
        objectWillChange.send()
    }

    func setUpdateCheckInterval(_ interval: AppUpdateCheckInterval) {
        updaterController.updater.updateCheckInterval = interval.rawValue
        objectWillChange.send()
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
