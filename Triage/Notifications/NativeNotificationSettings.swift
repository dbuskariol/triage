import Combine
import Foundation
@preconcurrency import UserNotifications

@MainActor
protocol NotificationDeliveryPreferencesProviding: Sendable {
    func deliveryPreferences(for organizationID: OrganizationID) async -> NotificationPreferences?
}

@MainActor
final class NativeNotificationSettings: ObservableObject, NotificationDeliveryPreferencesProviding {
    private struct Stored: Codable {
        var preferences: NotificationPreferences
        var organizationEnabled: [String: Bool]
    }

    private static let storageKey = "notifications.delivery-settings.v1"
    @Published private(set) var preferences: NotificationPreferences
    @Published private(set) var organizationEnabled: [String: Bool]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            preferences = stored.preferences
            organizationEnabled = stored.organizationEnabled
        } else {
            preferences = .init()
            organizationEnabled = [:]
        }
    }

    func deliveryPreferences(for organizationID: OrganizationID) async -> NotificationPreferences? {
        guard preferences.isEnabled, organizationEnabled[organizationID.rawValue] == true else { return nil }
        return preferences
    }

    func setEnabled(_ isEnabled: Bool) {
        preferences.isEnabled = isEnabled
        persist()
    }

    func setPrivacy(_ privacy: NotificationPrivacy) {
        preferences.privacy = privacy
        persist()
    }

    func setReason(_ reason: NotificationReason, enabled: Bool) {
        if enabled { preferences.enabledReasons.insert(reason) }
        else { preferences.enabledReasons.remove(reason) }
        persist()
    }

    func setQuietSchedule(_ schedule: NotificationQuietSchedule?) {
        preferences.quietSchedule = schedule
        persist()
    }

    func isEnabled(for organizationID: OrganizationID) -> Bool {
        organizationEnabled[organizationID.rawValue] == true
    }

    func setEnabled(_ isEnabled: Bool, for organizationID: OrganizationID) {
        organizationEnabled[organizationID.rawValue] = isEnabled
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Stored(
            preferences: preferences,
            organizationEnabled: organizationEnabled
        )) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

@MainActor
final class NotificationSystemAuthorization: ObservableObject {
    @Published private(set) var status: UNAuthorizationStatus = .notDetermined
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func refresh() async {
        status = await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func requestAuthorization() async {
        _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            center.requestAuthorization(options: [.alert]) { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
        await refresh()
    }
}

extension UNAuthorizationStatus {
    var notificationAuthorizationTitle: String {
        switch self {
        case .notDetermined:
            "Not requested"
        case .denied:
            "Denied in macOS Settings"
        case .authorized:
            "Allowed"
        case .provisional:
            "Provisional"
        case .ephemeral:
            "Temporary"
        @unknown default:
            "Unknown"
        }
    }
}
