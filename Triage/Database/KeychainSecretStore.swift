import Foundation
import Security

enum TriageSecretKind: String, CaseIterable, Hashable, Sendable {
    case oauthAccessToken
    case oauthRefreshToken
    case personalAccessToken
    case vaultKey
    case copilotCredential
}

enum SecretStoreError: Error, Equatable, Sendable {
    case invalidVaultKeyLength
    case keychain(OSStatus)
    case unexpectedKeychainValue
}

struct VaultKey: Equatable, Sendable {
    static let byteCount = 32

    let data: Data

    init(data: Data) throws {
        guard data.count == Self.byteCount else {
            throw SecretStoreError.invalidVaultKeyLength
        }
        self.data = data
    }

    static func generate() throws -> VaultKey {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, byteCount, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw SecretStoreError.keychain(status)
        }
        return try VaultKey(data: Data(bytes))
    }
}

protocol SecretStore: Sendable {
    func read(
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) async throws -> Data?

    func write(
        _ value: Data,
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) async throws

    func remove(
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) async throws

    func accountIDs() async throws -> [AccountID]
}

/// In-memory only cache for successful Keychain reads. It deliberately never
/// represents an absent item or an error: reconnect/removal changes must keep
/// those paths fail-closed and immediately observable.
struct KeychainSecretStoreCache: Sendable {
    private struct Key: Hashable, Sendable {
        let kind: TriageSecretKind
        let accountID: AccountID
        let credentialID: CredentialID?
    }

    private var values: [Key: Data] = [:]
    private var cachedAccountIDs: [AccountID]?

    func value(
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) -> Data? {
        values[.init(kind: kind, accountID: accountID, credentialID: credentialID)]
    }

    mutating func store(
        _ value: Data,
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) {
        values[.init(kind: kind, accountID: accountID, credentialID: credentialID)] = value
        if cachedAccountIDs != nil {
            cachedAccountIDs = Array(Set(cachedAccountIDs ?? []).union([accountID]))
                .sorted { $0.rawValue < $1.rawValue }
        }
    }

    func accountIDs() -> [AccountID]? {
        cachedAccountIDs
    }

    mutating func storeAccountIDs(_ accountIDs: [AccountID]) {
        cachedAccountIDs = accountIDs
    }

    mutating func remove(
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) {
        values[.init(kind: kind, accountID: accountID, credentialID: credentialID)] = nil
        // An account can have other secret kinds, so only a fresh query can
        // determine whether it still belongs in the account list.
        cachedAccountIDs = nil
    }

    mutating func removeAll(for accountID: AccountID) {
        values = values.filter { $0.key.accountID != accountID }
        cachedAccountIDs?.removeAll { $0 == accountID }
    }
}

actor KeychainSecretStore: SecretStore {
    private static let service = "com.triage.mac.secrets"
    static let shared = KeychainSecretStore()

    private var cache = KeychainSecretStoreCache()

    init() {}

    func read(
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) throws -> Data? {
        if let cached = cache.value(kind: kind, accountID: accountID, credentialID: credentialID) {
            return cached
        }
        var query = baseQuery(kind: kind, accountID: accountID, credentialID: credentialID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw SecretStoreError.unexpectedKeychainValue
            }
            cache.store(data, kind: kind, accountID: accountID, credentialID: credentialID)
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.keychain(status)
        }
    }

    func write(
        _ value: Data,
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) throws {
        let query = baseQuery(kind: kind, accountID: accountID, credentialID: credentialID)
        var insert = query
        insert[kSecValueData as String] = value
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(insert as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            cache.store(value, kind: kind, accountID: accountID, credentialID: credentialID)
            return
        case errSecDuplicateItem:
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: value] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw SecretStoreError.keychain(updateStatus)
            }
            cache.store(value, kind: kind, accountID: accountID, credentialID: credentialID)
        default:
            throw SecretStoreError.keychain(status)
        }
    }

    func remove(
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) throws {
        let status = SecItemDelete(
            baseQuery(kind: kind, accountID: accountID, credentialID: credentialID) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychain(status)
        }
        cache.remove(kind: kind, accountID: accountID, credentialID: credentialID)
    }

    func readVaultKey(for accountID: AccountID) throws -> VaultKey? {
        guard let data = try read(kind: .vaultKey, accountID: accountID, credentialID: nil) else {
            return nil
        }
        return try VaultKey(data: data)
    }

    func removeAllSecrets(for accountID: AccountID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrGeneric as String: Data(accountID.rawValue.utf8),
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychain(status)
        }
        cache.removeAll(for: accountID)
    }

    func accountIDs() throws -> [AccountID] {
        if let cached = cache.accountIDs() {
            return cached
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            cache.storeAccountIDs([])
            return []
        }
        guard status == errSecSuccess else {
            throw SecretStoreError.keychain(status)
        }
        let attributes = result as? [[String: Any]] ?? []
        let accountIDs = Set<AccountID>(attributes.compactMap { values -> AccountID? in
            guard let data = values[kSecAttrGeneric as String] as? Data,
                  let value = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            return AccountID(rawValue: value)
        }).sorted { $0.rawValue < $1.rawValue }
        cache.storeAccountIDs(accountIDs)
        return accountIDs
    }

    private func baseQuery(
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key(
                kind: kind,
                accountID: accountID,
                credentialID: credentialID
            ),
            kSecAttrGeneric as String: Data(accountID.rawValue.utf8),
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }

    private func key(
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) -> String {
        [kind.rawValue, accountID.rawValue, credentialID?.rawValue]
            .compactMap { $0 }
            .joined(separator: ".")
    }
}
