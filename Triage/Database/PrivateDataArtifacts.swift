import CryptoKit
import Foundation
import Security

enum PrivateDataArtifactKind: String, CaseIterable, Sendable {
    case vault
    case urlCache
    case avatars
    case previews
    case notificationMetadata
    case copilotState
    case copilotScratch
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
                kind: .copilotScratch,
                url: support
                    .appendingPathComponent("CopilotXPC", isDirectory: true)
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

enum AccountDataRemovalError: Error, Equatable, Sendable {
    /// Key material has already been erased, so the account must remain closed
    /// until a later deletion retry removes the remaining local artifacts.
    case residualArtifacts
    case invalidOpaqueAccountID
    case unsafeArtifactPath
}

private struct AccountDeletionJournal: Codable, Sendable {
    static let currentVersion = 2

    let version: Int
    let accountID: AccountID
    let signature: Data

    init(accountID: AccountID, signature: Data) {
        version = Self.currentVersion
        self.accountID = accountID
        self.signature = signature
    }

    func isValid(using authority: any AccountDeletionJournalAuthenticating) throws -> Bool {
        guard version == Self.currentVersion else { return false }
        return try authority.verify(signature: signature, accountID: accountID)
    }
}

/// The recovery journal authorizes irreversible key erasure after restart, so
/// its authentication key must not live beside the journal. This separate,
/// device-only Keychain item survives per-account secret removal long enough
/// to validate an interrupted deletion, but is never synced or exposed to XPC.
protocol AccountDeletionJournalAuthenticating: Sendable {
    func sign(accountID: AccountID) throws -> Data
    func verify(signature: Data, accountID: AccountID) throws -> Bool
}

private final class AccountDeletionJournalKeychainAuthority: AccountDeletionJournalAuthenticating, @unchecked Sendable {
    static let shared = AccountDeletionJournalKeychainAuthority()

    private static let service = "com.triage.mac.deletion-journal-authority"
    private static let account = "v2"
    private static let keyLength = 32

    func sign(accountID: AccountID) throws -> Data {
        try mac(for: accountID, createIfMissing: true)
    }

    func verify(signature: Data, accountID: AccountID) throws -> Bool {
        let expected = try mac(for: accountID, createIfMissing: false)
        return constantTimeEqual(signature, expected)
    }

    private func mac(for accountID: AccountID, createIfMissing: Bool) throws -> Data {
        let material = Data("triage-account-deletion-journal\u{1F}2\u{1F}\(accountID.rawValue)".utf8)
        let key = SymmetricKey(data: try keyData(createIfMissing: createIfMissing))
        return Data(HMAC<SHA256>.authenticationCode(for: material, using: key))
    }

    private func keyData(createIfMissing: Bool) throws -> Data {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let readStatus = SecItemCopyMatching(query as CFDictionary, &result)
        if readStatus == errSecSuccess {
            guard let key = result as? Data, key.count == Self.keyLength else {
                throw SecretStoreError.unexpectedKeychainValue
            }
            return key
        }
        guard readStatus == errSecItemNotFound, createIfMissing else {
            throw SecretStoreError.keychain(readStatus)
        }

        var bytes = [UInt8](repeating: 0, count: Self.keyLength)
        let randomStatus = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, Self.keyLength, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw SecretStoreError.keychain(randomStatus) }
        let generated = Data(bytes)
        var insert = baseQuery
        insert[kSecValueData as String] = generated
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        if insertStatus == errSecSuccess { return generated }
        guard insertStatus == errSecDuplicateItem else { throw SecretStoreError.keychain(insertStatus) }
        // A concurrent deletion began first. Read the established authority;
        // never replace it while a journal may already depend on it.
        return try keyData(createIfMissing: false)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }

    private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
actor AccountDataRemovalService {
    private let vaultRegistry: VaultRegistry
    private let applicationSupportDirectory: URL
    private let cachesDirectory: URL
    private let eraseSecrets: @Sendable (AccountID) async throws -> Void
    private let eraseArtifacts: @Sendable ([PrivateDataArtifact]) throws -> Void
    private let willBeginCryptoErasure: @Sendable () async -> Void
    /// The account-qualified lifecycle fence is used by startup journal
    /// recovery as well as interactive removal. Keeping it here ensures the
    /// same drain completes before every irreversible crypto-erasure path.
    private let willBeginCryptoErasureForAccount: @Sendable (AccountID) async -> Void
    private let journalAuthority: any AccountDeletionJournalAuthenticating

    init(
        vaultRegistry: VaultRegistry,
        secretStore: KeychainSecretStore,
        applicationSupportDirectory: URL,
        cachesDirectory: URL,
        willBeginCryptoErasure: @escaping @Sendable () async -> Void = {},
        willBeginCryptoErasureForAccount: @escaping @Sendable (AccountID) async -> Void = { _ in }
    ) {
        self.vaultRegistry = vaultRegistry
        self.applicationSupportDirectory = applicationSupportDirectory
        self.cachesDirectory = cachesDirectory
        eraseSecrets = { accountID in
            try await secretStore.removeAllSecrets(for: accountID)
        }
        eraseArtifacts = Self.removeArtifacts
        self.willBeginCryptoErasure = willBeginCryptoErasure
        self.willBeginCryptoErasureForAccount = willBeginCryptoErasureForAccount
        journalAuthority = AccountDeletionJournalKeychainAuthority.shared
    }

    init(
        vaultRegistry: VaultRegistry,
        applicationSupportDirectory: URL,
        cachesDirectory: URL,
        eraseSecrets: @escaping @Sendable (AccountID) async throws -> Void,
        eraseArtifacts: (@Sendable ([PrivateDataArtifact]) throws -> Void)? = nil,
        willBeginCryptoErasure: (@Sendable () async -> Void)? = nil,
        willBeginCryptoErasureForAccount: (@Sendable (AccountID) async -> Void)? = nil,
        journalAuthority: (any AccountDeletionJournalAuthenticating)? = nil
    ) {
        self.vaultRegistry = vaultRegistry
        self.applicationSupportDirectory = applicationSupportDirectory
        self.cachesDirectory = cachesDirectory
        self.eraseSecrets = eraseSecrets
        self.eraseArtifacts = eraseArtifacts ?? Self.removeArtifacts
        self.willBeginCryptoErasure = willBeginCryptoErasure ?? {}
        self.willBeginCryptoErasureForAccount = willBeginCryptoErasureForAccount ?? { _ in }
        self.journalAuthority = journalAuthority ?? AccountDeletionJournalKeychainAuthority.shared
    }

    func removeAllPrivateData(for accountID: AccountID) async throws {
        // Before removing the vault key, cancellation must leave the account
        // entirely usable. Once key erasure begins, reopening is unsafe even if
        // a later artifact removal needs another retry.
        guard Self.isOpaqueAccountID(accountID) else {
            throw AccountDataRemovalError.invalidOpaqueAccountID
        }
        let artifacts = AccountPrivateDataArtifacts(
            accountID: accountID,
            applicationSupportDirectory: applicationSupportDirectory,
            cachesDirectory: cachesDirectory
        ).artifacts
        try Self.validateArtifactPaths(
            artifacts,
            applicationSupportDirectory: applicationSupportDirectory,
            cachesDirectory: cachesDirectory
        )
        try Task.checkCancellation()
        await vaultRegistry.beginRemoval(accountID: accountID)
        do {
            try await vaultRegistry.close(accountID: accountID)
            await willBeginCryptoErasure()
            await willBeginCryptoErasureForAccount(accountID)
            try Task.checkCancellation()
        } catch {
            await vaultRegistry.cancelRemoval(accountID: accountID)
            throw error
        }

        do {
            // Persist intent before deleting the vault key. If the process is
            // interrupted after this point, only this explicit account-removal
            // journal authorizes startup recovery to resume erasure.
            try writeDeletionJournal(
                for: accountID,
                applicationSupportDirectory: applicationSupportDirectory
            )
            // This is the irreversible boundary. Do not observe cancellation
            // below it: completing (or later retrying) erasure is safer than
            // leaving a keyless vault available for reopening.
            try await eraseSecrets(accountID)
            // The recovery directory contains the journal itself. It must be
            // the final artifact removed so any earlier cleanup failure still
            // has durable, explicit authorization for replay after restart.
            let nonRecoveryArtifacts = artifacts.filter { $0.kind != .recovery }
            try eraseArtifacts(nonRecoveryArtifacts)
            guard nonRecoveryArtifacts.allSatisfy({
                !FileManager.default.fileExists(atPath: $0.url.path)
            }) else {
                throw AccountDataRemovalError.residualArtifacts
            }
            try eraseArtifacts(artifacts.filter { $0.kind == .recovery })
            guard artifacts.allSatisfy({
                !FileManager.default.fileExists(atPath: $0.url.path)
            }) else {
                throw AccountDataRemovalError.residualArtifacts
            }
        } catch {
            // The registry remains closed and marked for removal. A subsequent
            // call is idempotent and can finish erasing the remaining paths.
            throw error
        }
    }

    /// Replays only explicit, validated deletion journals left by an interrupted
    /// account removal. It never treats a missing source response, a missing
    /// key, or an unjournaled vault directory as authorization to delete data.
    func recoverInterruptedRemovals() async throws -> [AccountID] {
        let accountIDs = try interruptedDeletionAccountIDs(
            applicationSupportDirectory: applicationSupportDirectory
        )
        for accountID in accountIDs {
            try await removeAllPrivateData(for: accountID)
        }
        return accountIDs
    }

    private static func removeArtifacts(_ artifacts: [PrivateDataArtifact]) throws {
        for artifact in artifacts {
            let root = artifact.kind == .vault
                || artifact.kind == .copilotState
                || artifact.kind == .copilotScratch
                || artifact.kind == .recovery
                ? artifact.url.deletingLastPathComponent().deletingLastPathComponent()
                : artifact.url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let components = artifact.url.standardizedFileURL.path
                .dropFirst(root.standardizedFileURL.path.count + 1)
                .split(separator: "/")
                .map(String.init)
            try NoFollowFilesystem.removeTreeIfPresent(beneath: root, components: components)
        }
    }

    private func writeDeletionJournal(
        for accountID: AccountID,
        applicationSupportDirectory: URL
    ) throws {
        let components = ["Triage", "Recovery", accountID.rawValue]
        do {
            try NoFollowFilesystem.ensureDirectory(
                at: applicationSupportDirectory,
                components: components
            )
        } catch {
            throw AccountDataRemovalError.unsafeArtifactPath
        }
        let journal = AccountDeletionJournal(
            accountID: accountID,
            signature: try journalAuthority.sign(accountID: accountID)
        )
        do {
            try NoFollowFilesystem.writeFileAtomically(
                beneath: applicationSupportDirectory,
                directoryComponents: components,
                name: "account-deletion.json",
                data: try JSONEncoder().encode(journal)
            )
        } catch {
            throw AccountDataRemovalError.unsafeArtifactPath
        }
    }

    private func interruptedDeletionAccountIDs(
        applicationSupportDirectory: URL
    ) throws -> [AccountID] {
        let recoveryDirectory = applicationSupportDirectory
            .appendingPathComponent("Triage", isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
        try Self.assertSafePath(recoveryDirectory, beneath: applicationSupportDirectory)
        let triageDirectory = recoveryDirectory.deletingLastPathComponent()
        // A normal vault-only installation has no recovery directory and is
        // never deletion authorization. Return before inspecting the ordinary
        // Triage directory's mode; containment above still rejects symlinks.
        guard FileManager.default.fileExists(atPath: recoveryDirectory.path) else {
            return []
        }
        guard FileManager.default.fileExists(atPath: triageDirectory.path),
              try Self.isPrivateDirectoryWithoutSymlink(triageDirectory),
              try Self.isPrivateDirectoryWithoutSymlink(recoveryDirectory)
        else {
            throw AccountDataRemovalError.unsafeArtifactPath
        }
        let directories = try FileManager.default.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return directories.compactMap { directory in
            guard (try? Self.isPrivateDirectoryWithoutSymlink(directory)) == true,
                  let accountID = AccountID(rawValue: directory.lastPathComponent),
                  Self.isOpaqueAccountID(accountID)
            else {
                return nil
            }
            guard let data = try? NoFollowFilesystem.readRegularFileIfPresent(
                    beneath: applicationSupportDirectory,
                    directoryComponents: ["Triage", "Recovery", accountID.rawValue],
                    name: "account-deletion.json",
                    maximumBytes: 16 * 1_024,
                    expectedPermissions: 0o600
                  ),
                  let journal = try? JSONDecoder().decode(AccountDeletionJournal.self, from: data),
                  (try? journal.isValid(using: journalAuthority)) == true,
                  journal.accountID == accountID
            else {
                return nil
            }
            return journal.accountID
        }.sorted { $0.rawValue < $1.rawValue }
    }

    private static func deletionJournalURL(
        for accountID: AccountID,
        applicationSupportDirectory: URL
    ) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("Triage", isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent(accountID.rawValue, isDirectory: true)
            .appendingPathComponent("account-deletion.json", isDirectory: false)
    }

    private static func isOpaqueAccountID(_ accountID: AccountID) -> Bool {
        guard let value = UUID(uuidString: accountID.rawValue) else { return false }
        return value.uuidString.lowercased() == accountID.rawValue
    }

    private static func validateArtifactPaths(
        _ artifacts: [PrivateDataArtifact],
        applicationSupportDirectory: URL,
        cachesDirectory: URL
    ) throws {
        let supportRoot = applicationSupportDirectory.standardizedFileURL
            .appendingPathComponent("Triage", isDirectory: true)
        let cacheRoot = cachesDirectory.standardizedFileURL
            .appendingPathComponent("Triage", isDirectory: true)
        for artifact in artifacts {
            let expectedRoot = artifact.kind == .vault
                || artifact.kind == .copilotState
                || artifact.kind == .copilotScratch
                || artifact.kind == .recovery
                ? supportRoot
                : cacheRoot
            try assertSafePath(artifact.url, beneath: expectedRoot.deletingLastPathComponent())
        }
    }

    private static func ensurePrivateDirectory(_ directory: URL, beneath root: URL) throws {
        try assertSafePath(directory, beneath: root)
        if FileManager.default.fileExists(atPath: directory.path) {
            guard try isDirectoryWithoutSymlink(directory) else {
                throw AccountDataRemovalError.unsafeArtifactPath
            }
        } else {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private static func assertSafePath(_ path: URL, beneath root: URL) throws {
        let standardizedRoot = root.standardizedFileURL
        let standardizedPath = path.standardizedFileURL
        let rootPath = standardizedRoot.path
        let pathPath = standardizedPath.path
        guard pathPath.hasPrefix(rootPath + "/") else {
            throw AccountDataRemovalError.unsafeArtifactPath
        }
        var current = standardizedRoot
        guard !isSymbolicLink(current) else {
            throw AccountDataRemovalError.unsafeArtifactPath
        }
        let relativePath = String(pathPath.dropFirst(rootPath.count + 1))
        for component in relativePath.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            guard !isSymbolicLink(current) else {
                throw AccountDataRemovalError.unsafeArtifactPath
            }
        }
    }

    private static func isDirectoryWithoutSymlink(_ url: URL) throws -> Bool {
        guard !isSymbolicLink(url) else { return false }
        return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }

    private static func isPrivateDirectoryWithoutSymlink(_ url: URL) throws -> Bool {
        try isDirectoryWithoutSymlink(url) && hasExactPermissions(url, expected: 0o700)
    }

    private static func hasExactPermissions(_ url: URL, expected: Int) -> Bool {
        guard let permissions = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber else {
            return false
        }
        return (permissions.intValue & 0o777) == expected
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType)
            == .typeSymbolicLink
    }
}
