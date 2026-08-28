import Foundation
import Security

enum TriageSecretKind: String, CaseIterable, Sendable {
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
}

actor KeychainSecretStore: SecretStore {
    private static let service = "com.triage.mac.secrets"

    func read(
        kind: TriageSecretKind,
        accountID: AccountID,
        credentialID: CredentialID?
    ) throws -> Data? {
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
            return
        case errSecDuplicateItem:
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: value] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw SecretStoreError.keychain(updateStatus)
            }
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
    }

    func readVaultKey(for accountID: AccountID) throws -> VaultKey? {
        guard let data = try read(kind: .vaultKey, accountID: accountID, credentialID: nil) else {
            return nil
        }
        return try VaultKey(data: data)
    }

    func createVaultKey(for accountID: AccountID) throws -> VaultKey {
        if try readVaultKey(for: accountID) != nil {
            throw SecretStoreError.keychain(errSecDuplicateItem)
        }
        let key = try VaultKey.generate()
        try write(key.data, kind: .vaultKey, accountID: accountID, credentialID: nil)
        return key
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
    }

    func accountIDs() throws -> [AccountID] {
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
            return []
        }
        guard status == errSecSuccess else {
            throw SecretStoreError.keychain(status)
        }
        let attributes = result as? [[String: Any]] ?? []
        return Set(attributes.compactMap { values in
            guard let data = values[kSecAttrGeneric as String] as? Data,
                  let value = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            return AccountID(rawValue: value)
        }).sorted { $0.rawValue < $1.rawValue }
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
