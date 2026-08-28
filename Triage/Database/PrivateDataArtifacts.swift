import Foundation

enum PrivateDataArtifactKind: String, CaseIterable, Sendable {
    case vault
    case urlCache
    case avatars
    case previews
    case notificationMetadata
    case copilotState
    case recovery
}

struct PrivateDataArtifact: Sendable {
    let kind: PrivateDataArtifactKind
    let url: URL
}

struct AccountPrivateDataArtifacts: Sendable {
    let accountID: AccountID
    let artifacts: [PrivateDataArtifact]

    init(
        accountID: AccountID,
        applicationSupportDirectory: URL,
        cachesDirectory: URL
    ) {
        self.accountID = accountID
        let support = applicationSupportDirectory
            .appendingPathComponent("Triage", isDirectory: true)
        artifacts = [
            PrivateDataArtifact(
                kind: .vault,
                url: support
                    .appendingPathComponent("Vaults", isDirectory: true)
                    .appendingPathComponent(accountID.rawValue, isDirectory: true)
            ),
            PrivateDataArtifact(
                kind: .copilotState,
                url: support
                    .appendingPathComponent("Copilot", isDirectory: true)
                    .appendingPathComponent(accountID.rawValue, isDirectory: true)
            ),
            PrivateDataArtifact(
                kind: .recovery,
                url: support
                    .appendingPathComponent("Recovery", isDirectory: true)
                    .appendingPathComponent(accountID.rawValue, isDirectory: true)
            ),
            PrivateDataArtifact(
                kind: .urlCache,
                url: cachesDirectory
                    .appendingPathComponent("Triage", isDirectory: true)
                    .appendingPathComponent("URLCache", isDirectory: true)
                    .appendingPathComponent(accountID.rawValue, isDirectory: true)
            ),
            PrivateDataArtifact(
                kind: .avatars,
                url: cachesDirectory
                    .appendingPathComponent("Triage", isDirectory: true)
                    .appendingPathComponent("Avatars", isDirectory: true)
                    .appendingPathComponent(accountID.rawValue, isDirectory: true)
            ),
            PrivateDataArtifact(
                kind: .previews,
                url: cachesDirectory
                    .appendingPathComponent("Triage", isDirectory: true)
                    .appendingPathComponent("Previews", isDirectory: true)
                    .appendingPathComponent(accountID.rawValue, isDirectory: true)
            ),
            PrivateDataArtifact(
                kind: .notificationMetadata,
                url: cachesDirectory
                    .appendingPathComponent("Triage", isDirectory: true)
                    .appendingPathComponent("Notifications", isDirectory: true)
                    .appendingPathComponent(accountID.rawValue, isDirectory: true)
            )
        ]
    }
}

actor AccountDataRemovalService {
    private let vaultRegistry: VaultRegistry
    private let secretStore: KeychainSecretStore
    private let applicationSupportDirectory: URL
    private let cachesDirectory: URL

    init(
        vaultRegistry: VaultRegistry,
        secretStore: KeychainSecretStore,
        applicationSupportDirectory: URL,
        cachesDirectory: URL
    ) {
        self.vaultRegistry = vaultRegistry
        self.secretStore = secretStore
        self.applicationSupportDirectory = applicationSupportDirectory
        self.cachesDirectory = cachesDirectory
    }

    func removeAllPrivateData(for accountID: AccountID) async throws {
        try await vaultRegistry.close(accountID: accountID)
        try await secretStore.removeAllSecrets(for: accountID)

        let artifacts = AccountPrivateDataArtifacts(
            accountID: accountID,
            applicationSupportDirectory: applicationSupportDirectory,
            cachesDirectory: cachesDirectory
        ).artifacts
        for artifact in artifacts {
            if FileManager.default.fileExists(atPath: artifact.url.path) {
                try FileManager.default.removeItem(at: artifact.url)
            }
        }
    }
}
