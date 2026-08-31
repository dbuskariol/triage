import Foundation
import GRDB

enum VaultError: Error, Equatable, Sendable {
    case invalidIntegrityCheck
    case sqlCipherUnavailable
    case missingApplicationSupportDirectory
    case accountBeingRemoved
    case unsafeAccountIDPath
    case unsupportedDestructiveMigration(String)
    case invalidMigrationBackup
}

struct VaultPaths: Equatable, Sendable {
    let directory: URL
    let database: URL
    let migrationBackups: URL

    init(rootDirectory: URL, accountID: AccountID) {
        directory = rootDirectory
            .appendingPathComponent("Vaults", isDirectory: true)
            .appendingPathComponent(accountID.rawValue, isDirectory: true)
        database = directory.appendingPathComponent("triage.sqlite", isDirectory: false)
        migrationBackups = directory
            .appendingPathComponent("MigrationBackups", isDirectory: true)
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
    private let vaultKey: VaultKey

    init(
        accountID: AccountID,
        vaultKey: VaultKey,
        rootDirectory: URL? = nil
    ) throws {
        self.accountID = accountID
        self.vaultKey = vaultKey
        let root = try rootDirectory ?? VaultPaths.defaultRootDirectory()
        paths = VaultPaths(rootDirectory: root, accountID: accountID)

        try FileManager.default.createDirectory(
            at: paths.directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        databasePool = try DatabasePool(
            path: paths.database.path,
            configuration: Self.configuration(vaultKey: vaultKey)
        )
        try Self.verify(databasePool)
    }

    func read<Value: Sendable>(
        _ operation: @Sendable (Database) throws -> Value
    ) throws -> Value {
        try databasePool.read(operation)
    }

    /// Creates a value-only workspace observation bridge while retaining sole
    /// ownership of this vault's database pool. Consumers can cancel their
    /// subscriptions, but never receive a database handle.
    func workspaceObservationBridge() -> WorkspaceDatabaseObservationBridge {
        WorkspaceDatabaseObservationService.bridge(
            in: databasePool,
            accountID: accountID
        )
    }

    func write<Value: Sendable>(
        _ operation: @Sendable (Database) throws -> Value
    ) throws -> Value {
        try databasePool.write(operation)
    }

    /// Commits all writes performed by `operation`, or rolls them all back on failure.
    func writeTransaction<Value: Sendable>(
        _ operation: @Sendable (Database) throws -> Value
    ) throws -> Value {
        // DatabasePool.write commits the closure atomically and rolls it back when
        // the operation throws, so an inner transaction would be both redundant
        // and invalid on current GRDB/SQLite.
        try databasePool.write(operation)
    }

    func close() throws {
        try databasePool.close()
    }

    func applyMigrations() throws {
        let databasePool = databasePool
        let vaultKey = vaultKey
        let paths = paths
        try TriageDatabaseMigrator.migrate(
            databasePool,
            beforeDestructiveMigration: { migrationID in
                try Self.createVerifiedMigrationBackup(
                    for: migrationID,
                    from: databasePool,
                    vaultKey: vaultKey,
                    paths: paths
                )
            }
        )
    }

    private static func configuration(
        vaultKey: VaultKey,
        readonly: Bool = false
    ) -> Configuration {
        var configuration = Configuration()
        configuration.label = "Triage.AccountVault"
        configuration.foreignKeysEnabled = true
        configuration.readonly = readonly
        if !readonly {
            configuration.journalMode = .wal
        }
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { database in
            try database.usePassphrase(vaultKey.data)
            try database.execute(sql: "PRAGMA cipher_memory_security = ON")
            if !readonly {
                try database.execute(sql: "PRAGMA secure_delete = ON")
            }
        }
        return configuration
    }

    private static func createVerifiedMigrationBackup(
        for migrationID: String,
        from source: DatabasePool,
        vaultKey: VaultKey,
        paths: VaultPaths
    ) throws {
        guard [
            "033-role-search-page-replay-v2",
            "034-role-search-page-replay-parser-identity"
        ].contains(migrationID) else {
            throw VaultError.unsupportedDestructiveMigration(migrationID)
        }
        let sourceReplayCount = try source.read { database in
            guard try database.tableExists("role_search_page_replays"),
                  try String.fetchOne(
                    database,
                    sql: "SELECT checksum FROM schema_migrations WHERE id = ?",
                    arguments: [migrationID]
                  ) == nil
            else {
                throw VaultError.invalidMigrationBackup
            }
            return try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM role_search_page_replays"
            ) ?? 0
        }

        try FileManager.default.createDirectory(
            at: paths.migrationBackups,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let backup = paths.migrationBackups
            .appendingPathComponent("\(migrationID).sqlite", isDirectory: false)
        let temporaryBackup = paths.migrationBackups
            .appendingPathComponent(".\(migrationID).\(UUID().uuidString).partial", isDirectory: false)
        let temporaryArtifacts = [
            temporaryBackup,
            URL(fileURLWithPath: temporaryBackup.path + "-journal"),
            URL(fileURLWithPath: temporaryBackup.path + "-shm"),
            URL(fileURLWithPath: temporaryBackup.path + "-wal")
        ]
        defer {
            for artifact in temporaryArtifacts {
                try? FileManager.default.removeItem(at: artifact)
            }
        }

        var backupConfiguration = configuration(vaultKey: vaultKey)
        // A queue defaults to a rollback journal, avoiding durable WAL/SHM
        // sidecars for a temporary migration backup.
        backupConfiguration.journalMode = .default
        let destination = try DatabaseQueue(
            path: temporaryBackup.path,
            configuration: backupConfiguration
        )
        try source.backup(to: destination)
        try destination.close()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporaryBackup.path
        )

        let verificationPool = try DatabasePool(
            path: temporaryBackup.path,
            configuration: configuration(vaultKey: vaultKey, readonly: true)
        )
        defer { try? verificationPool.close() }
        try verify(verificationPool)
        let verified = try verificationPool.read { database in
            guard try database.tableExists("role_search_page_replays"),
                  try String.fetchOne(
                    database,
                    sql: "SELECT checksum FROM schema_migrations WHERE id = ?",
                    arguments: [migrationID]
                  ) == nil
            else {
                return false
            }
            return (try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM role_search_page_replays"
            ) ?? 0) == sourceReplayCount
        }
        guard verified else {
            throw VaultError.invalidMigrationBackup
        }

        if FileManager.default.fileExists(atPath: backup.path) {
            _ = try FileManager.default.replaceItemAt(
                backup,
                withItemAt: temporaryBackup,
                backupItemName: nil,
                options: []
            )
        } else {
            try FileManager.default.moveItem(at: temporaryBackup, to: backup)
        }
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
            // SQLCipher reports one row per integrity error and no rows when
            // every encrypted page passes HMAC verification.
            guard integrityRows.isEmpty else {
                throw VaultError.invalidIntegrityCheck
            }
        }
    }
}

actor VaultRegistry {
    private let rootDirectory: URL
    private var openVaults: [AccountID: AccountVault] = [:]
    private var accountsBeingRemoved: Set<AccountID> = []

    init(rootDirectory: URL? = nil) throws {
        self.rootDirectory = try rootDirectory ?? VaultPaths.defaultRootDirectory()
    }

    func open(
        accountID: AccountID,
        vaultKey: VaultKey
    ) async throws -> AccountVault {
        guard !accountsBeingRemoved.contains(accountID) else {
            throw VaultError.accountBeingRemoved
        }
        if let vault = openVaults[accountID] {
            return vault
        }

        let vault = try AccountVault(
            accountID: accountID,
            vaultKey: vaultKey,
            rootDirectory: rootDirectory
        )
        try await vault.applyMigrations()
        guard !accountsBeingRemoved.contains(accountID) else {
            try await vault.close()
            throw VaultError.accountBeingRemoved
        }
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
        guard Self.isOpaqueAccountID(accountID) else {
            throw VaultError.unsafeAccountIDPath
        }
        let paths = VaultPaths(rootDirectory: rootDirectory, accountID: accountID)
        try Self.assertRemovalPathIsSafe(paths.directory, beneath: rootDirectory)
        beginRemoval(accountID: accountID)
        defer { cancelRemoval(accountID: accountID) }
        try await close(accountID: accountID)
        if FileManager.default.fileExists(atPath: paths.directory.path) {
            try FileManager.default.removeItem(at: paths.directory)
        }
    }

    func beginRemoval(accountID: AccountID) {
        accountsBeingRemoved.insert(accountID)
    }

    func cancelRemoval(accountID: AccountID) {
        accountsBeingRemoved.remove(accountID)
    }

    /// Lifecycle state only; no database handle is exposed while an account is
    /// being cryptographically erased.
    func isOpen(accountID: AccountID) -> Bool {
        openVaults[accountID] != nil
    }

    func isBeingRemoved(accountID: AccountID) -> Bool {
        accountsBeingRemoved.contains(accountID)
    }

    private static func isOpaqueAccountID(_ accountID: AccountID) -> Bool {
        guard let value = UUID(uuidString: accountID.rawValue) else { return false }
        return value.uuidString.lowercased() == accountID.rawValue
    }

    private static func assertRemovalPathIsSafe(_ path: URL, beneath root: URL) throws {
        let standardizedRoot = root.standardizedFileURL
        let standardizedPath = path.standardizedFileURL
        let rootPath = standardizedRoot.path
        let pathPath = standardizedPath.path
        guard pathPath.hasPrefix(rootPath + "/") else {
            throw VaultError.unsafeAccountIDPath
        }

        var current = standardizedRoot
        guard !isSymbolicLink(current) else {
            throw VaultError.unsafeAccountIDPath
        }
        let relativePath = String(pathPath.dropFirst(rootPath.count + 1))
        for component in relativePath.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            guard !isSymbolicLink(current) else {
                throw VaultError.unsafeAccountIDPath
            }
        }
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType)
            == .typeSymbolicLink
    }
}
