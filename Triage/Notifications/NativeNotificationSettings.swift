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
    /// A Settings change is not authoritative until it has acquired the
    /// shared delivery lease, persisted, and purged incompatible requests.
    @Published private(set) var isDeliverySettingsMutationPending = false
    @Published private(set) var deliverySettingsMutationError: String?
    @Published private(set) var deliveryRevision: UInt64 = 0
    private let defaults: UserDefaults
    private let notificationRemover: any AccountNotificationRemoving
    let notificationDeliveryLeaseGate: NotificationDeliveryLeaseGate
    private var consentResolver: (@Sendable (AccountID) async throws -> any NotificationOrganizationConsentPersisting)?
    private var pendingDeliverySettingsMutationCount = 0

    init(
        defaults: UserDefaults = .standard,
        notificationRemover: any AccountNotificationRemoving = NativeNotificationAccountRemover(),
        notificationDeliveryLeaseGate: NotificationDeliveryLeaseGate = .init(),
        consentResolver: (@Sendable (AccountID) async throws -> any NotificationOrganizationConsentPersisting)? = nil
    ) {
        self.defaults = defaults
        self.notificationRemover = notificationRemover
        self.notificationDeliveryLeaseGate = notificationDeliveryLeaseGate
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
        enqueueGlobalDeliveryMutation(.enabled(isEnabled))
    }

    func setPrivacy(_ privacy: NotificationPrivacy) {
        enqueueGlobalDeliveryMutation(.privacy(privacy))
    }

    func setReason(_ reason: NotificationReason, enabled: Bool) {
        enqueueGlobalDeliveryMutation(.reason(reason, enabled: enabled))
    }

    func setQuietSchedule(_ schedule: NotificationQuietSchedule?) {
        enqueueGlobalDeliveryMutation(.quietSchedule(schedule))
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
        beginDeliverySettingsMutation()
        await notificationDeliveryLeaseGate.acquire()
        do {
            let repository = try await consentRepository(for: scope.accountID)
            try await repository.setEnabled(
                isEnabled,
                accountID: scope.accountID,
                organizationID: scope.organizationID
            )
            deliveryRevision &+= 1
            if !isEnabled {
                await notificationRemover.removeNotifications(
                    for: scope.accountID,
                    organizationID: scope.organizationID
                )
            }
            await notificationDeliveryLeaseGate.release()
            finishDeliverySettingsMutation()
            return true
        } catch {
            await notificationDeliveryLeaseGate.release()
            deliverySettingsMutationError = error.localizedDescription
            finishDeliverySettingsMutation()
            return false
        }
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

    private enum GlobalDeliveryMutation {
        case enabled(Bool)
        case privacy(NotificationPrivacy)
        case reason(NotificationReason, enabled: Bool)
        case quietSchedule(NotificationQuietSchedule?)
    }

    private func enqueueGlobalDeliveryMutation(_ mutation: GlobalDeliveryMutation) {
        beginDeliverySettingsMutation()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.notificationDeliveryLeaseGate.acquire()
            let mustPurgeExistingContent: Bool
            switch mutation {
            case let .enabled(isEnabled):
                self.preferences.isEnabled = isEnabled
                mustPurgeExistingContent = !isEnabled
            case let .privacy(privacy):
                mustPurgeExistingContent = self.preferences.privacy == .showDetails && privacy == .generic
                self.preferences.privacy = privacy
            case let .reason(reason, enabled):
                if enabled { self.preferences.enabledReasons.insert(reason) }
                else { self.preferences.enabledReasons.remove(reason) }
                // Requests cannot be selected by reason at the system API
                // boundary. Purging our own pending and delivered requests is
                // the fail-closed exact application scope.
                mustPurgeExistingContent = !enabled
            case let .quietSchedule(schedule):
                self.preferences.quietSchedule = schedule
                // A newly configured quiet range can cover already-delivered
                // content, so make that transition fail closed too.
                mustPurgeExistingContent = true
            }
            self.persist()
            self.deliveryRevision &+= 1
            if mustPurgeExistingContent {
                await self.notificationRemover.removeAllTriageNotifications()
            }
            await self.notificationDeliveryLeaseGate.release()
            self.finishDeliverySettingsMutation()
        }
    }

    private func beginDeliverySettingsMutation() {
        pendingDeliverySettingsMutationCount += 1
        isDeliverySettingsMutationPending = true
        deliverySettingsMutationError = nil
    }

    private func finishDeliverySettingsMutation() {
        pendingDeliverySettingsMutationCount = max(0, pendingDeliverySettingsMutationCount - 1)
        isDeliverySettingsMutationPending = pendingDeliverySettingsMutationCount > 0
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
