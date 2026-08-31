import Combine
import Foundation
@preconcurrency import UserNotifications

/// Credential-revision-independent local notification-consent boundary.
/// Consent belongs to an account/organization pair, while synchronization
/// revisions remain an authority concern for delivery and actions.
struct NotificationScope: Equatable, Hashable, Sendable {
    let accountID: AccountID
    let organizationID: OrganizationID
}

@MainActor
protocol NotificationDeliveryPreferencesProviding: Sendable {
    func deliveryPreferences(for organizationID: OrganizationID) async -> NotificationPreferences?
    func deliveryPreferences(for scope: SynchronizationScope) async -> NotificationPreferences?
    /// Notification consent is bound to both the local account and the GitHub
    /// organization. Implementations that predate account-scoped consent fail
    /// closed rather than widening an organization approval to every account.
    func deliveryPreferences(
        for accountID: AccountID,
        organizationID: OrganizationID
    ) async -> NotificationPreferences?
}

extension NotificationDeliveryPreferencesProviding {
    func deliveryPreferences(for scope: SynchronizationScope) async -> NotificationPreferences? {
        await deliveryPreferences(
            for: scope.accountID,
            organizationID: scope.organizationID
        )
    }
    func deliveryPreferences(
        for _: AccountID,
        organizationID _: OrganizationID
    ) async -> NotificationPreferences? {
        nil
    }
}

protocol NotificationOrganizationConsentPersisting: Sendable {
    func isEnabled(accountID: AccountID, organizationID: OrganizationID) async throws -> Bool
    func setEnabled(_ isEnabled: Bool, accountID: AccountID, organizationID: OrganizationID) async throws
    func removeAll(accountID: AccountID) async throws
}

extension NotificationPreferenceRepository: NotificationOrganizationConsentPersisting {}

@MainActor
final class NativeNotificationSettings: ObservableObject, NotificationDeliveryPreferencesProviding {
    private struct Stored: Codable {
        var preferences: NotificationPreferences
    }

    private static let storageKey = "notifications.delivery-settings.v1"
    @Published private(set) var preferences: NotificationPreferences
    private let defaults: UserDefaults
    private let notificationRemover: any AccountNotificationRemoving
    private var consentResolver: (@Sendable (AccountID) async throws -> any NotificationOrganizationConsentPersisting)?

    init(
        defaults: UserDefaults = .standard,
        notificationRemover: any AccountNotificationRemoving = NativeNotificationAccountRemover(),
        consentResolver: (@Sendable (AccountID) async throws -> any NotificationOrganizationConsentPersisting)? = nil
    ) {
        self.defaults = defaults
        self.notificationRemover = notificationRemover
        self.consentResolver = consentResolver
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            preferences = stored.preferences
        } else {
            preferences = .init()
        }
        // The prior storage format included an organization-only consent map.
        // Decode its non-sensitive global preferences but rewrite immediately
        // without the ambiguous map; it must never migrate into another
        // account's encrypted vault implicitly.
        persist()
    }

    func deliveryPreferences(for organizationID: OrganizationID) async -> NotificationPreferences? {
        // This legacy overload has no account authority. It must never turn a
        // globally-identifiable GitHub organization into account-wide consent.
        nil
    }

    func deliveryPreferences(
        for accountID: AccountID,
        organizationID: OrganizationID
    ) async -> NotificationPreferences? {
        guard preferences.isEnabled,
              let repository = try? await consentRepository(for: accountID),
              (try? await repository.isEnabled(accountID: accountID, organizationID: organizationID)) == true
        else { return nil }
        return preferences
    }

    func deliveryPreferences(for scope: SynchronizationScope) async -> NotificationPreferences? {
        await deliveryPreferences(for: scope.accountID, organizationID: scope.organizationID)
    }

    func setEnabled(_ isEnabled: Bool) {
        preferences.isEnabled = isEnabled
        persist()
        if !isEnabled {
            Task { await notificationRemover.removeAllTriageNotifications() }
        }
    }

    func setPrivacy(_ privacy: NotificationPrivacy) {
        let mustPurgeExistingContent = preferences.privacy == .showDetails && privacy == .generic
        preferences.privacy = privacy
        persist()
        if mustPurgeExistingContent {
            Task { await notificationRemover.removeAllTriageNotifications() }
        }
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
        // Kept only to make older callers fail closed while they migrate to
        // account-qualified consent.
        false
    }

    func setEnabled(_ isEnabled: Bool, for organizationID: OrganizationID) {
        // A caller without an account cannot grant notification authority.
        // Preserve fail-closed behavior instead of writing a legacy global key.
        _ = isEnabled
        _ = organizationID
    }

    func isEnabled(for scope: NotificationScope) async -> Bool {
        guard let repository = try? await consentRepository(for: scope.accountID) else { return false }
        return (try? await repository.isEnabled(
            accountID: scope.accountID,
            organizationID: scope.organizationID
        )) == true
    }

    func isEnabled(for scope: SynchronizationScope) async -> Bool {
        await isEnabled(for: .init(accountID: scope.accountID, organizationID: scope.organizationID))
    }

    @discardableResult
    func setEnabled(_ isEnabled: Bool, for scope: NotificationScope) async -> Bool {
        guard let repository = try? await consentRepository(for: scope.accountID) else { return false }
        guard (try? await repository.setEnabled(
            isEnabled,
            accountID: scope.accountID,
            organizationID: scope.organizationID
        )) != nil else { return false }
        if !isEnabled {
            await notificationRemover.removeNotifications(
                for: scope.accountID,
                organizationID: scope.organizationID
            )
        }
        return true
    }

    @discardableResult
    func setEnabled(_ isEnabled: Bool, for scope: SynchronizationScope) async -> Bool {
        await setEnabled(
            isEnabled,
            for: .init(accountID: scope.accountID, organizationID: scope.organizationID)
        )
    }

    func configureEncryptedConsent(
        vaultRegistry: VaultRegistry,
        secretStore: KeychainSecretStore
    ) {
        consentResolver = { accountID in
            guard let vaultKey = try await secretStore.readVaultKey(for: accountID) else {
                throw AccountCredentialReaderError.missingAccessToken
            }
            let vault = try await vaultRegistry.open(accountID: accountID, vaultKey: vaultKey)
            return NotificationPreferenceRepository(vault: vault)
        }
    }

    /// Call before the account vault is deleted. Failure remains fail-closed:
    /// there is no root-store copy to resurrect the removed consent.
    func removeAccountPreferences(for accountID: AccountID) async {
        guard let repository = try? await consentRepository(for: accountID) else { return }
        try? await repository.removeAll(accountID: accountID)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Stored(
            preferences: preferences
        )) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func consentRepository(
        for accountID: AccountID
    ) async throws -> any NotificationOrganizationConsentPersisting {
        guard let consentResolver else {
            throw NotificationPreferenceRepositoryError.accountScopeMismatch
        }
        return try await consentResolver(accountID)
    }
}

@MainActor
protocol NotificationSystemAuthorizationProviding: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async -> UNAuthorizationStatus
}

@MainActor
final class UserNotificationSystemAuthorizationProvider: NotificationSystemAuthorizationProviding {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func requestAuthorization() async -> UNAuthorizationStatus {
        _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            center.requestAuthorization(options: [.alert]) { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
        return await authorizationStatus()
    }
}

/// Deliberately has no `UNUserNotificationCenter` dependency. The DEBUG UI
/// fixture uses it so opening Notification Settings cannot query or prompt
/// macOS for the user's real notification authorization.
@MainActor
final class InMemoryNotificationSystemAuthorizationProvider: NotificationSystemAuthorizationProviding {
    private let storedStatus: UNAuthorizationStatus
    private(set) var requestCount = 0

    init(status: UNAuthorizationStatus = .notDetermined) {
        storedStatus = status
    }

    func authorizationStatus() async -> UNAuthorizationStatus { storedStatus }

    func requestAuthorization() async -> UNAuthorizationStatus {
        requestCount += 1
        return storedStatus
    }
}

@MainActor
final class NotificationSystemAuthorization: ObservableObject {
    @Published private(set) var status: UNAuthorizationStatus = .notDetermined
    private let provider: any NotificationSystemAuthorizationProviding

    init(provider: any NotificationSystemAuthorizationProviding = UserNotificationSystemAuthorizationProvider()) {
        self.provider = provider
    }

    func refresh() async {
        status = await provider.authorizationStatus()
    }

    func requestAuthorization() async {
        status = await provider.requestAuthorization()
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
