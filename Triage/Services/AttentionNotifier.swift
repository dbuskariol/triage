import AppKit
import OSLog
@preconcurrency import UserNotifications

/// Notification permission, shared by the notifier, Settings, and onboarding.
enum NotificationPermission {
    static func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Shows the system prompt once; later calls return the stored answer.
    @discardableResult
    static func request() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    @MainActor
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Posts local notifications for work that newly needs you and keeps the
/// Dock badge in step with the Briefing's "Need Action" count. Nothing leaves
/// the Mac: notifications are local and contain only titles you can already see.
@MainActor
final class AttentionNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let logger = Logger(subsystem: "com.triage.mac", category: "App")
    /// More than this many at once become one summary notification.
    private static let individualLimit = 3

    private let defaults: UserDefaults
    private let center = UNUserNotificationCenter.current()
    private var trackers: [OrganizationID: AttentionTracker] = [:]
    private var hasRequestedAuthorization = false
    /// Opens what a clicked notification points to.
    var onOpen: (AttentionTarget) -> Void = { _ in }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        center.delegate = self
    }

    func process(_ presentation: WorkspacePresentation, organizationID: OrganizationID?) {
        let needsAction = presentation.entries(in: .inbox).filter { $0.decision?.disposition == .act }
        updateDockBadge(count: needsAction.count)
        guard let organizationID else { return }

        var tracker = trackers[organizationID] ?? load(organizationID)
        let fresh = tracker.update(with: presentation)
        func target(_ kind: AttentionTarget.Kind) -> AttentionTarget { AttentionTarget(kind, organizationID: organizationID) }
        let followUps = WorkInsights.overdueFollowUps(
            in: presentation, days: Self.followUpDays(defaults), now: .now
        )
        let silent = quietHours?.contains(.now) == true
        var remindFollowUps = false
        if bool(TriagePreferenceKeys.notifyFollowUps), !silent {
            remindFollowUps = tracker.followUpReminderDue(count: followUps.count, now: .now)
        }
        if tracker != trackers[organizationID] {
            trackers[organizationID] = tracker
            save(tracker, organizationID)
        }
        guard !silent else { return }
        if bool(TriagePreferenceKeys.notifyNeedsAction), !fresh.isEmpty { post(needsAction: fresh, target: target) }
        if remindFollowUps { post(followUps: followUps, target: target) }
    }

    func updateDockBadge(count: Int) {
        let show = bool(TriagePreferenceKeys.showDockBadge) && count > 0
        // macOS shows Dock badges only for apps allowed to badge.
        if show { Task { await requestAuthorizationIfNeeded() } }
        NSApp.dockTile.badgeLabel = show ? count.formatted() : nil
    }

    // MARK: Posting

    private func post(needsAction entries: [TriageEntry], target: (AttentionTarget.Kind) -> AttentionTarget) {
        if entries.count > Self.individualLimit {
            send(
                id: "needs-action-summary",
                title: "\(entries.count) items need your action",
                body: entries.prefix(3).map(\.item.title).joined(separator: " · "),
                target: target(.needsAction)
            )
        } else {
            for entry in entries {
                send(
                    id: "needs-action-\(entry.id.rawValue)",
                    title: entry.decision?.nextAction ?? entry.item.title,
                    body: "\(entry.item.reference) · \(entry.item.title)",
                    target: target(.item(entry.id))
                )
            }
        }
    }

    private func post(followUps: [TriageEntry], target: (AttentionTarget.Kind) -> AttentionTarget) {
        send(
            id: "follow-ups",
            title: followUps.count == 1 ? "1 item may need a nudge" : "\(followUps.count) items may need a nudge",
            body: followUps.prefix(3).map(\.item.title).joined(separator: " · "),
            target: target(followUps.count == 1 ? followUps.first.map { .item($0.id) } ?? .followUps : .followUps)
        )
    }

    private func send(id: String, title: String, body: String, target: AttentionTarget) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "triage"
        content.userInfo = target.userInfo
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task {
            await requestAuthorizationIfNeeded()
            do { try await center.add(request) } catch {
                Self.logger.error("notification failed errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            }
        }
    }

    private func requestAuthorizationIfNeeded() async {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        await NotificationPermission.request()
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // While you're looking at Triage, the list already shows it.
        await MainActor.run { NSApp.isActive } ? [.list] : [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let target = AttentionTarget(userInfo: response.notification.request.content.userInfo)
        await MainActor.run {
            NSApp.activate()
            if let target { onOpen(target) }
        }
    }

    // MARK: Preferences

    private func bool(_ key: String) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    private var quietHours: QuietHours? {
        guard defaults.bool(forKey: TriagePreferenceKeys.quietHoursEnabled) else { return nil }
        return QuietHours(
            start: defaults.object(forKey: TriagePreferenceKeys.quietHoursStart) as? Int ?? 19,
            end: defaults.object(forKey: TriagePreferenceKeys.quietHoursEnd) as? Int ?? 8
        )
    }

    static func followUpDays(_ defaults: UserDefaults) -> Int {
        let days = defaults.integer(forKey: TriagePreferenceKeys.followUpDays)
        return days > 0 ? days : TriagePreferenceKeys.defaultFollowUpDays
    }

    private func load(_ organizationID: OrganizationID) -> AttentionTracker {
        defaults.data(forKey: "attention.\(organizationID.rawValue)")
            .flatMap { try? JSONDecoder().decode(AttentionTracker.self, from: $0) } ?? AttentionTracker()
    }

    private func save(_ tracker: AttentionTracker, _ organizationID: OrganizationID) {
        defaults.set(try? JSONEncoder().encode(tracker), forKey: "attention.\(organizationID.rawValue)")
    }
}
