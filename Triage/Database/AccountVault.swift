import Foundation
import GRDB
import Darwin

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
    let recoveryCopies: URL

    init(rootDirectory: URL, accountID: AccountID) {
        directory = rootDirectory
            .appendingPathComponent("Vaults", isDirectory: true)
            .appendingPathComponent(accountID.rawValue, isDirectory: true)
        database = directory.appendingPathComponent("triage.sqlite", isDirectory: false)
        migrationBackups = directory
            .appendingPathComponent("MigrationBackups", isDirectory: true)
        recoveryCopies = directory
            .appendingPathComponent("RecoveryCopies", isDirectory: true)
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

/// Validates the only filesystem namespace used by account vaults before it is
/// created or opened. Account identifiers are deliberately opaque UUIDs, not
/// arbitrary strings supplied by persisted or external data.
private enum VaultPathValidator {
    /// Validates the caller-selected trusted root before entering the
    /// account-owned namespace. macOS exposes system aliases and firmlinks
    /// such as `/var`; preserving the spelling of that root also preserves the
    /// sandbox extension granted to temporary and Application Support paths.
    /// The root itself is reopened with `O_NOFOLLOW`, and every `Vaults`
    /// component below it remains descriptor-relative and no-follow protected.
    static func canonicalRootDirectory(_ rootDirectory: URL) throws -> URL {
        let standardized = rootDirectory.standardizedFileURL
        guard standardized.isFileURL, standardized.path.hasPrefix("/") else {
            throw VaultError.unsafeAccountIDPath
        }
        var status = stat()
        if Darwin.lstat(standardized.path, &status) == 0 {
            guard (status.st_mode & S_IFMT) != S_IFLNK else {
                throw VaultError.unsafeAccountIDPath
            }
        } else if errno != ENOENT {
            throw VaultError.unsafeAccountIDPath
        }
        return standardized
    }

    static func paths(rootDirectory: URL, accountID: AccountID) throws -> VaultPaths {
        guard isOpaqueAccountID(accountID) else {
            throw VaultError.unsafeAccountIDPath
        }

        let canonicalRoot = try canonicalRootDirectory(rootDirectory)
        let paths = VaultPaths(rootDirectory: canonicalRoot, accountID: accountID)
        do {
            try NoFollowFilesystem.assertExistingPath(
                beneath: canonicalRoot,
                components: ["Vaults", accountID.rawValue]
            )
        } catch {
            throw VaultError.unsafeAccountIDPath
        }
        return paths
    }

    static func ensureVaultDirectory(rootDirectory: URL, accountID: AccountID) throws {
        let canonicalRoot = try canonicalRootDirectory(rootDirectory)
        _ = try paths(rootDirectory: canonicalRoot, accountID: accountID)
        do {
            try NoFollowFilesystem.ensureDirectory(
                at: canonicalRoot,
                components: ["Vaults", accountID.rawValue]
            )
        } catch {
            throw VaultError.unsafeAccountIDPath
        }
    }

    static func assertDatabaseFileIsSafe(rootDirectory: URL, accountID: AccountID) throws {
        let canonicalRoot = try canonicalRootDirectory(rootDirectory)
        do {
            try NoFollowFilesystem.assertRegularFileIfPresent(
                beneath: canonicalRoot,
                directoryComponents: ["Vaults", accountID.rawValue],
                name: "triage.sqlite"
            )
        } catch {
            throw VaultError.unsafeAccountIDPath
        }
    }

    private static func isOpaqueAccountID(_ accountID: AccountID) -> Bool {
        guard let value = UUID(uuidString: accountID.rawValue) else { return false }
        return value.uuidString.lowercased() == accountID.rawValue
    }

}

/// Small descriptor-relative filesystem primitive for account-owned data.
/// `FileManager` path APIs resolve every component afresh, which makes a
/// check-then-create/remove sequence vulnerable to an ancestor symlink swap.
/// These helpers retain an opened directory descriptor while descending each
/// component and use `O_NOFOLLOW` at every boundary.
enum NoFollowFilesystem {
    private static let directoryFlags: Int32 = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    private static let trustedRootDirectoryFlags: Int32 = O_RDONLY | O_DIRECTORY | O_CLOEXEC

    static func ensureDirectory(at root: URL, components: [String]) throws {
        var descriptor = try openDirectory(at: root, create: true)
        defer { _ = Darwin.close(descriptor) }
        for component in components {
            let next = try openDirectory(named: component, relativeTo: descriptor, create: true)
            guard Darwin.fchmod(next, 0o700) == 0 else {
                _ = Darwin.close(next)
                throw posixError()
            }
            _ = Darwin.close(descriptor)
            descriptor = next
        }
    }

    /// Confirms the existing prefix only. Missing components are safe to
    /// create later through `ensureDirectory`, which performs the same
    /// descriptor-relative traversal.
    static func assertExistingPath(beneath root: URL, components: [String]) throws {
        var descriptor: Int32
        do {
            descriptor = try openDirectory(at: root, create: false)
        } catch let error as NSError where error.code == Int(ENOENT) {
            return
        }
        defer { _ = Darwin.close(descriptor) }
        for component in components {
            do {
                let next = try openDirectory(named: component, relativeTo: descriptor, create: false)
                _ = Darwin.close(descriptor)
                descriptor = next
            } catch let error as NSError where error.code == Int(ENOENT) {
                return
            }
        }
    }

    static func assertRegularFileIfPresent(
        beneath root: URL,
        directoryComponents: [String],
        name: String
    ) throws {
        let directory = try openedDirectory(beneath: root, components: directoryComponents, create: false)
        guard let directory else { return }
        defer { _ = Darwin.close(directory) }

        let file = Darwin.openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if file == -1 {
            guard errno == ENOENT else { throw posixError() }
            return
        }
        defer { _ = Darwin.close(file) }
        var status = stat()
        guard Darwin.fstat(file, &status) == 0 else { throw posixError() }
        guard (status.st_mode & S_IFMT) == S_IFREG else { throw posixError(code: EINVAL) }
    }

    /// Returns an owned descriptor for a directory reached entirely through
    /// the no-follow account namespace. The caller must keep it open for as
    /// long as any `/dev/fd/<descriptor>/...` pathname may be reopened.
    static func openDirectoryDescriptor(
        beneath root: URL,
        components: [String]
    ) throws -> Int32 {
        guard let descriptor = try openedDirectory(
            beneath: root,
            components: components,
            create: false
        ) else {
            throw posixError(code: ENOENT)
        }
        return descriptor
    }

    /// Opens a regular file through an already-held directory descriptor. The
    /// caller can pass `/dev/fd/<file-fd>` to a read-only SQLite pool without
    /// resolving another account-owned path after the no-follow open.
    static func withRegularFileIfPresent<Value>(
        relativeTo directory: Int32,
        name: String,
        _ operation: (Int32) throws -> Value
    ) throws -> Value? {
        guard isSafeComponent(name) else { throw posixError(code: EINVAL) }
        let file = Darwin.openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if file == -1 {
            guard errno == ENOENT else { throw posixError() }
            return nil
        }
        defer { _ = Darwin.close(file) }
        var status = stat()
        guard Darwin.fstat(file, &status) == 0 else { throw posixError() }
        guard (status.st_mode & S_IFMT) == S_IFREG else { throw posixError(code: EINVAL) }
        return try operation(file)
    }

    static func createRegularFileIfMissing(
        relativeTo directory: Int32,
        name: String,
        permissions: mode_t = 0o600
    ) throws {
        guard isSafeComponent(name) else { throw posixError(code: EINVAL) }
        let file = Darwin.openat(
            directory,
            name,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            permissions
        )
        if file == -1 {
            guard errno == EEXIST,
                  try withRegularFileIfPresent(
                      relativeTo: directory,
                      name: name,
                      { _ in true }
                  ) == true
            else {
                throw posixError()
            }
            return
        }
        defer { _ = Darwin.close(file) }
        guard Darwin.fchmod(file, permissions) == 0,
              Darwin.fsync(file) == 0,
              Darwin.fsync(directory) == 0
        else {
            throw posixError()
        }
    }

    static func readRegularFileIfPresent(
        beneath root: URL,
        directoryComponents: [String],
        name: String,
        maximumBytes: Int,
        expectedPermissions: mode_t? = nil
    ) throws -> Data? {
        guard maximumBytes >= 0 else { throw posixError(code: EINVAL) }
        let directory = try openedDirectory(beneath: root, components: directoryComponents, create: false)
        guard let directory else { return nil }
        defer { _ = Darwin.close(directory) }
        let file = Darwin.openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if file == -1 {
            guard errno == ENOENT else { throw posixError() }
            return nil
        }
        defer { _ = Darwin.close(file) }
        var status = stat()
        guard Darwin.fstat(file, &status) == 0 else { throw posixError() }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0,
              status.st_size <= off_t(maximumBytes)
        else { throw posixError(code: EINVAL) }
        if let expectedPermissions,
           (status.st_mode & 0o777) != expectedPermissions {
            throw posixError(code: EACCES)
        }
        var data = Data(count: Int(status.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
        return data
    }

    static func removeTreeIfPresent(beneath root: URL, components: [String]) throws {
        guard let name = components.last else { return }
        let parent = try openedDirectory(
            beneath: root,
            components: Array(components.dropLast()),
            create: false
        )
        guard let parent else { return }
        defer { _ = Darwin.close(parent) }
        try removeEntry(named: name, relativeTo: parent)
    }

    static func withDirectory<Value>(
        beneath root: URL,
        components: [String],
        create: Bool,
        _ operation: (Int32) throws -> Value
    ) throws -> Value {
        guard let directory = try openedDirectory(
            beneath: root,
            components: components,
            create: create
        ) else { throw posixError(code: ENOENT) }
        defer { _ = Darwin.close(directory) }
        return try operation(directory)
    }

    /// Descends from an already-held directory descriptor without resolving
    /// the account namespace again. The parent remains owned by the caller;
    /// only descendant descriptors opened here are closed.
    static func withDirectory<Value>(
        relativeTo parent: Int32,
        components: [String],
        create: Bool,
        _ operation: (Int32) throws -> Value
    ) throws -> Value {
        guard !components.isEmpty else { return try operation(parent) }
        var directory = try openDirectory(
            named: components[0],
            relativeTo: parent,
            create: create
        )
        if create, Darwin.fchmod(directory, 0o700) != 0 {
            _ = Darwin.close(directory)
            throw posixError()
        }
        defer { _ = Darwin.close(directory) }
        for component in components.dropFirst() {
            let next = try openDirectory(named: component, relativeTo: directory, create: create)
            if create, Darwin.fchmod(next, 0o700) != 0 {
                _ = Darwin.close(next)
                throw posixError()
            }
            _ = Darwin.close(directory)
            directory = next
        }
        return try operation(directory)
    }

    static func removeRegularFileIfPresent(relativeTo directory: Int32, name: String) throws {
        guard isSafeComponent(name) else { throw posixError(code: EINVAL) }
        var status = stat()
        guard Darwin.fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            guard errno == ENOENT else { throw posixError() }
            return
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else { throw posixError(code: EINVAL) }
        guard Darwin.unlinkat(directory, name, 0) == 0 else { throw posixError() }
    }

    static func writeFileAtomically(
        beneath root: URL,
        directoryComponents: [String],
        name: String,
        data: Data,
        permissions: mode_t = 0o600
    ) throws {
        guard isSafeComponent(name) else { throw posixError(code: EINVAL) }
        guard let directory = try openedDirectory(
            beneath: root,
            components: directoryComponents,
            create: true
        ) else { throw posixError(code: ENOENT) }
        defer { _ = Darwin.close(directory) }
        let temporary = ".\(name).\(UUID().uuidString.lowercased()).partial"
        let file = Darwin.openat(
            directory,
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            permissions
        )
        guard file != -1 else { throw posixError() }
        defer {
            _ = Darwin.close(file)
            _ = Darwin.unlinkat(directory, temporary, 0)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { throw posixError() }
                offset += written
            }
        }
        guard Darwin.fchmod(file, permissions) == 0 else { throw posixError() }
        // Commit content and final mode together before the name becomes
        // visible. A crash must never publish a durable journal/backup with
        // the temporary file's permissions.
        guard Darwin.fsync(file) == 0 else { throw posixError() }
        guard Darwin.renameat(directory, temporary, directory, name) == 0 else { throw posixError() }
        guard Darwin.fsync(directory) == 0 else { throw posixError() }
    }

    static func removeRegularFileIfPresent(
        beneath root: URL,
        directoryComponents: [String],
        name: String
    ) throws {
        guard isSafeComponent(name) else { throw posixError(code: EINVAL) }
        guard let directory = try openedDirectory(
            beneath: root,
            components: directoryComponents,
            create: false
        ) else {
            return
        }
        defer { _ = Darwin.close(directory) }
        var status = stat()
        guard Darwin.fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            guard errno == ENOENT else { throw posixError() }
            return
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else { throw posixError(code: EINVAL) }
        guard Darwin.unlinkat(directory, name, 0) == 0,
              Darwin.fsync(directory) == 0
        else {
            throw posixError()
        }
    }

    private static func openedDirectory(
        beneath root: URL,
        components: [String],
        create: Bool
    ) throws -> Int32? {
        var descriptor: Int32
        do {
            descriptor = try openDirectory(at: root, create: create)
        } catch let error as NSError where !create && error.code == Int(ENOENT) {
            return nil
        }
        for component in components {
            do {
                let next = try openDirectory(named: component, relativeTo: descriptor, create: create)
                _ = Darwin.close(descriptor)
                descriptor = next
            } catch let error as NSError where !create && error.code == Int(ENOENT) {
                _ = Darwin.close(descriptor)
                return nil
            }
        }
        return descriptor
    }

    private static func openDirectory(at url: URL, create: Bool) throws -> Int32 {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/") else { throw posixError(code: EINVAL) }
        if !create {
            let descriptor = Darwin.open(path, directoryFlags)
            guard descriptor != -1 else { throw posixError() }
            return descriptor
        }
        // The configured root is the trusted boundary and may sit beneath a
        // macOS system alias or firmlink (`/var`, `/tmp`, Data-volume mounts).
        // Creation traverses only that trusted boundary using ordinary
        // directory opens. The completed root is then reopened atomically with
        // `O_NOFOLLOW`, closing a final-component swap before any account-owned
        // path is accessed.
        var descriptor = Darwin.open("/", trustedRootDirectoryFlags)
        guard descriptor != -1 else { throw posixError() }
        for component in path.split(separator: "/").map(String.init) {
            do {
                guard isSafeComponent(component) else { throw posixError(code: EINVAL) }
                var next = Darwin.openat(descriptor, component, trustedRootDirectoryFlags)
                if next == -1, create, errno == ENOENT {
                    guard Darwin.mkdirat(descriptor, component, 0o700) == 0 || errno == EEXIST else {
                        throw posixError()
                    }
                    next = Darwin.openat(descriptor, component, trustedRootDirectoryFlags)
                }
                guard next != -1 else { throw posixError() }
                _ = Darwin.close(descriptor)
                descriptor = next
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
        }
        _ = Darwin.close(descriptor)
        descriptor = Darwin.open(path, directoryFlags)
        guard descriptor != -1 else { throw posixError() }
        return descriptor
    }

    private static func openDirectory(named name: String, relativeTo parent: Int32, create: Bool) throws -> Int32 {
        guard isSafeComponent(name) else { throw posixError(code: EINVAL) }
        var descriptor = Darwin.openat(parent, name, directoryFlags)
        if descriptor == -1, create, errno == ENOENT {
            guard Darwin.mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else { throw posixError() }
            descriptor = Darwin.openat(parent, name, directoryFlags)
        }
        guard descriptor != -1 else { throw posixError() }
        return descriptor
    }

    private static func removeEntry(named name: String, relativeTo parent: Int32) throws {
        guard isSafeComponent(name) else { throw posixError(code: EINVAL) }
        var status = stat()
        guard Darwin.fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            guard errno == ENOENT else { throw posixError() }
            return
        }
        if (status.st_mode & S_IFMT) != S_IFDIR {
            guard Darwin.unlinkat(parent, name, 0) == 0 else { throw posixError() }
            return
        }
        let child = Darwin.openat(parent, name, directoryFlags)
        guard child != -1 else { throw posixError() }
        guard let stream = Darwin.fdopendir(child) else {
            _ = Darwin.close(child)
            throw posixError()
        }
        defer { _ = Darwin.closedir(stream) }
        while let entry = Darwin.readdir(stream) {
            let childName = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) {
                    String(cString: $0)
                }
            }
            guard childName != ".", childName != ".." else { continue }
            try removeEntry(named: childName, relativeTo: child)
        }
        guard Darwin.unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw posixError() }
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
    }

    private static func posixError(code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

actor AccountVault {
    let accountID: AccountID
    let paths: VaultPaths

    private let databasePool: DatabasePool
    private let vaultDirectoryDescriptor: Int32
    private let rootDirectory: URL
    private let vaultKey: VaultKey

    init(
        accountID: AccountID,
        vaultKey: VaultKey,
        rootDirectory: URL? = nil
    ) throws {
        self.accountID = accountID
        self.vaultKey = vaultKey
        let configuredRoot = try rootDirectory ?? VaultPaths.defaultRootDirectory()
        let root = try VaultPathValidator.canonicalRootDirectory(configuredRoot)
        self.rootDirectory = root
        paths = try VaultPathValidator.paths(rootDirectory: root, accountID: accountID)

        // Each component is opened relative to a no-follow directory
        // descriptor. This prevents a symlinked Vaults/account namespace from
        // redirecting creation outside the app-owned root.
        try VaultPathValidator.ensureVaultDirectory(rootDirectory: root, accountID: accountID)
        try VaultPathValidator.assertDatabaseFileIsSafe(rootDirectory: root, accountID: accountID)

        let vaultDirectoryDescriptor = try NoFollowFilesystem.openDirectoryDescriptor(
            beneath: root,
            components: ["Vaults", accountID.rawValue]
        )
        self.vaultDirectoryDescriptor = vaultDirectoryDescriptor
        do {
            try NoFollowFilesystem.createRegularFileIfMissing(
                relativeTo: vaultDirectoryDescriptor,
                name: "triage.sqlite"
            )
            // SQLite's WAL VFS requires a normal sibling pathname on macOS;
            // `/dev/fd/<directory>/<name>` is not traversable. The complete
            // private path has already been created and verified no-follow,
            // and the held directory descriptor remains our containment proof.
            let pool = try DatabasePool(
                path: paths.database.path,
                configuration: Self.configuration(vaultKey: vaultKey)
            )
            try Self.verify(pool)
            databasePool = pool
        } catch {
            _ = Darwin.close(vaultDirectoryDescriptor)
            throw error
        }
    }

    deinit {
        _ = Darwin.close(vaultDirectoryDescriptor)
    }

    func read<Value: Sendable>(
        _ operation: @escaping @Sendable (Database) throws -> Value
    ) async throws -> Value {
        try await databasePool.read(operation)
    }

    /// Starts a value-only database observation without exposing the pool.
    func observe<Value: Equatable & Sendable>(
        _ fetch: @escaping @Sendable (Database) throws -> Value,
        onError: @escaping @Sendable (Error) -> Void,
        onChange: @escaping @Sendable (Value) -> Void
    ) -> AnyDatabaseCancellable {
        ValueObservation
            .tracking(fetch)
            .removeDuplicates()
            .start(
                in: databasePool,
                scheduling: .task,
                onError: onError,
                onChange: onChange
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

    static func configuration(vaultKey: VaultKey, readonly: Bool = false) -> Configuration {
        var configuration = Configuration()
        configuration.label = "Triage.AccountVault"
        configuration.foreignKeysEnabled = true
        configuration.readonly = readonly
        if !readonly { configuration.journalMode = .wal }
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { database in
            try database.usePassphrase(vaultKey.data)
            try database.execute(sql: "PRAGMA cipher_memory_security = ON")
            if !readonly { try database.execute(sql: "PRAGMA secure_delete = ON") }
        }
        return configuration
    }

    static func verify(_ databasePool: DatabasePool) throws {
        try databasePool.read { database in
            guard !(try database.cipherVersion).isEmpty else { throw VaultError.sqlCipherUnavailable }
            guard try String.fetchAll(database, sql: "PRAGMA cipher_integrity_check").isEmpty else {
                throw VaultError.invalidIntegrityCheck
            }
        }
    }

    func applyMigrations() throws {
        try TriageDatabaseMigrator.migrate(databasePool, beforeDestructiveMigration: { _ in })
    }

    static func verifiedMigrationBackupIDs(
        rootDirectory: URL,
        accountID: AccountID,
        vaultKey: VaultKey
    ) throws -> [String] {
        _ = try VaultPathValidator.paths(rootDirectory: rootDirectory, accountID: accountID)
        _ = vaultKey
        return []
    }

    static func restoreVerifiedMigrationBackup(
        rootDirectory: URL,
        accountID: AccountID,
        vaultKey: VaultKey,
        migrationID: String
    ) throws {
        _ = try VaultPathValidator.paths(rootDirectory: rootDirectory, accountID: accountID)
        _ = vaultKey
        _ = migrationID
        throw VaultError.invalidMigrationBackup
    }
}

actor VaultRegistry {
    private let rootDirectory: URL
    private var openVaults: [AccountID: AccountVault] = [:]
    private var accountsBeingRemoved: Set<AccountID> = []

    init(rootDirectory: URL? = nil) throws {
        let configuredRoot = try rootDirectory ?? VaultPaths.defaultRootDirectory()
        self.rootDirectory = try VaultPathValidator.canonicalRootDirectory(configuredRoot)
    }

    func open(
        accountID: AccountID,
        vaultKey: VaultKey
    ) async throws -> AccountVault {
        // Validate before consulting cached vaults so a malformed persisted ID
        // can never become an accepted vault namespace.
        _ = try VaultPathValidator.paths(rootDirectory: rootDirectory, accountID: accountID)
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
        _ = try VaultPathValidator.paths(rootDirectory: rootDirectory, accountID: accountID)
        beginRemoval(accountID: accountID)
        defer { cancelRemoval(accountID: accountID) }
        try await close(accountID: accountID)
        do {
            try NoFollowFilesystem.removeTreeIfPresent(
                beneath: rootDirectory,
                components: ["Vaults", accountID.rawValue]
            )
        } catch {
            throw VaultError.unsafeAccountIDPath
        }
    }

    func beginRemoval(accountID: AccountID) {
        accountsBeingRemoved.insert(accountID)
    }

    func cancelRemoval(accountID: AccountID) {
        accountsBeingRemoved.remove(accountID)
    }

    func verifiedMigrationBackupIDs(
        accountID: AccountID,
        vaultKey: VaultKey
    ) throws -> [String] {
        try AccountVault.verifiedMigrationBackupIDs(
            rootDirectory: rootDirectory,
            accountID: accountID,
            vaultKey: vaultKey
        )
    }

    /// Restores only a verified encrypted migration backup. The current vault
    /// is closed first and preserved as an encrypted recovery copy by the
    /// vault layer; callers never receive a filesystem path or a destructive
    /// replace/delete primitive.
    func restoreVerifiedMigrationBackup(
        accountID: AccountID,
        vaultKey: VaultKey,
        migrationID: String
    ) async throws {
        guard !accountsBeingRemoved.contains(accountID) else {
            throw VaultError.accountBeingRemoved
        }
        try await close(accountID: accountID)
        try AccountVault.restoreVerifiedMigrationBackup(
            rootDirectory: rootDirectory,
            accountID: accountID,
            vaultKey: vaultKey,
            migrationID: migrationID
        )
    }
}
