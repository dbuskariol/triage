import Foundation
import GRDB

enum VaultError: Error, Equatable, Sendable {
    case invalidIntegrityCheck
    case sqlCipherUnavailable
    case missingApplicationSupportDirectory
}

struct VaultPaths: Equatable, Sendable {
    let directory: URL
    let database: URL

    init(rootDirectory: URL, accountID: AccountID) {
        directory = rootDirectory
            .appendingPathComponent("Vaults", isDirectory: true)
            .appendingPathComponent(accountID.rawValue, isDirectory: true)
        database = directory.appendingPathComponent("triage.sqlite", isDirectory: false)
    }

    static func defaultRootDirectory() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw VaultError.missingApplicationSupportDirectory
        }
        return applicationSupport
            .appendingPathComponent("Triage", isDirectory: true)
    }
}

actor AccountVault {
    let accountID: AccountID
    let paths: VaultPaths

    private let databasePool: DatabasePool

    init(
        accountID: AccountID,
        vaultKey: VaultKey,
        rootDirectory: URL? = nil
    ) throws {
        self.accountID = accountID
        let root = try rootDirectory ?? VaultPaths.defaultRootDirectory()
        paths = VaultPaths(rootDirectory: root, accountID: accountID)

        try FileManager.default.createDirectory(
            at: paths.directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var configuration = Configuration()
        configuration.label = "Triage.AccountVault"
        configuration.foreignKeysEnabled = true
        configuration.journalMode = .wal
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { database in
            try database.usePassphrase(vaultKey.data)
            try database.execute(sql: "PRAGMA cipher_memory_security = ON")
            try database.execute(sql: "PRAGMA secure_delete = ON")
        }

        databasePool = try DatabasePool(path: paths.database.path, configuration: configuration)
        try Self.verify(databasePool)
    }

    func read<Value: Sendable>(
        _ operation: @Sendable (Database) throws -> Value
    ) throws -> Value {
        try databasePool.read(operation)
    }

    func write<Value: Sendable>(
        _ operation: @Sendable (Database) throws -> Value
    ) throws -> Value {
        try databasePool.write(operation)
    }

    func close() throws {
        try databasePool.close()
    }

    func applyMigrations() throws {
        try TriageDatabaseMigrator.migrate(databasePool)
    }

    private static func verify(_ databasePool: DatabasePool) throws {
        try databasePool.read { database in
            guard !(try database.cipherVersion).isEmpty else {
                throw VaultError.sqlCipherUnavailable
            }
            let integrityRows = try String.fetchAll(
                database,
                sql: "PRAGMA cipher_integrity_check"
            )
            guard integrityRows == ["ok"] else {
                throw VaultError.invalidIntegrityCheck
            }
        }
    }
}

actor VaultRegistry {
    private let rootDirectory: URL
    private var openVaults: [AccountID: AccountVault] = [:]

    init(rootDirectory: URL? = nil) throws {
        self.rootDirectory = try rootDirectory ?? VaultPaths.defaultRootDirectory()
    }

    func open(
        accountID: AccountID,
        vaultKey: VaultKey
    ) async throws -> AccountVault {
        if let vault = openVaults[accountID] {
            return vault
        }

        let vault = try AccountVault(
            accountID: accountID,
            vaultKey: vaultKey,
            rootDirectory: rootDirectory
        )
        try await vault.applyMigrations()
        openVaults[accountID] = vault
        return vault
    }

    func close(accountID: AccountID) async throws {
        guard let vault = openVaults.removeValue(forKey: accountID) else { return }
        try await vault.close()
    }

    func closeAll() async throws {
        let vaults = openVaults.values
        openVaults.removeAll()
        for vault in vaults {
            try await vault.close()
        }
    }

    func remove(accountID: AccountID) async throws {
        try await close(accountID: accountID)
        let paths = VaultPaths(rootDirectory: rootDirectory, accountID: accountID)
        if FileManager.default.fileExists(atPath: paths.directory.path) {
            try FileManager.default.removeItem(at: paths.directory)
        }
    }
}
