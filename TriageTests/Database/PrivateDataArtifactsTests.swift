import CryptoKit
import XCTest
@testable import Triage

final class PrivateDataArtifactsTests: XCTestCase {
    func testArtifactsAreAccountScopedAndEnumerateEveryAppOwnedLocation() {
        let artifacts = AccountPrivateDataArtifacts(
            accountID: AccountID(rawValue: "account-1")!,
            applicationSupportDirectory: URL(fileURLWithPath: "/support"),
            cachesDirectory: URL(fileURLWithPath: "/cache")
        )

        XCTAssertEqual(artifacts.artifacts.count, PrivateDataArtifactKind.allCases.count)
        XCTAssertTrue(artifacts.artifacts.allSatisfy { $0.url.path.contains("account-1") })
        XCTAssertTrue(artifacts.artifacts.contains { $0.kind == .vault })
        XCTAssertTrue(artifacts.artifacts.contains { $0.kind == .copilotState })
        XCTAssertEqual(
            artifacts.artifacts.first(where: { $0.kind == .copilotScratch })?.url.path,
            "/support/Triage/CopilotXPC/account-1"
        )
    }

    func testDeletionClosesOpenVaultBeforeSecretErasureAndRemovesEveryArtifact() async throws {
        let support = try makeTemporaryDirectory()
        let caches = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: caches)
        }

        let accountID = AccountID.make()
        let vaultRoot = support.appendingPathComponent("Triage", isDirectory: true)
        let registry = try VaultRegistry(rootDirectory: vaultRoot)
        let vault = try await registry.open(accountID: accountID, vaultKey: try VaultKey.generate())
        try await vault.write { database in
            try database.execute(sql: "CREATE TABLE deletion_marker (value TEXT NOT NULL)")
        }

        let artifacts = AccountPrivateDataArtifacts(
            accountID: accountID,
            applicationSupportDirectory: support,
            cachesDirectory: caches
        ).artifacts
        let scratch = try XCTUnwrap(artifacts.first(where: { $0.kind == .copilotScratch }))
        let staleScratch = scratch.url.appendingPathComponent("crashed-helper", isDirectory: true)
        try FileManager.default.createDirectory(at: staleScratch, withIntermediateDirectories: true)
        try Data("private copilot input".utf8).write(
            to: staleScratch.appendingPathComponent("request.json", isDirectory: false)
        )
        for artifact in artifacts where artifact.kind != .vault {
            try FileManager.default.createDirectory(
                at: artifact.url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data("private".utf8).write(to: artifact.url.appendingPathComponent("marker"))
        }

        let events = DeletionEventLog()
        let service = AccountDataRemovalService(
            vaultRegistry: registry,
            applicationSupportDirectory: support,
            cachesDirectory: caches,
            eraseSecrets: { _ in
                await events.recordSecretErasure(
                    vaultWasOpen: await registry.isOpen(accountID: accountID),
                    removalWasActive: await registry.isBeingRemoved(accountID: accountID)
                )
            },
            journalAuthority: TestAccountDeletionJournalAuthority()
        )

        try await service.removeAllPrivateData(for: accountID)

        let secretErasures = await events.secretErasures()
        let vaultWasOpen = await events.vaultWasOpenAtSecretErasure()
        let removalWasActive = await events.removalWasActiveAtSecretErasure()
        let vaultIsOpen = await registry.isOpen(accountID: accountID)
        let removalIsActive = await registry.isBeingRemoved(accountID: accountID)
        XCTAssertEqual(secretErasures, 1)
        XCTAssertEqual(vaultWasOpen, false)
        XCTAssertEqual(removalWasActive, true)
        XCTAssertTrue(artifacts.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.url.path)
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleScratch.path))
        XCTAssertFalse(vaultIsOpen)
        XCTAssertTrue(removalIsActive)
    }

    func testCancelledDeletionBeforeCryptoErasureLeavesVaultAndArtifactsUsable() async throws {
        let support = try makeTemporaryDirectory()
        let caches = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: caches)
        }

        let accountID = AccountID.make()
        let key = try VaultKey.generate()
        let registry = try VaultRegistry(
            rootDirectory: support.appendingPathComponent("Triage", isDirectory: true)
        )
        let vault = try await registry.open(accountID: accountID, vaultKey: key)
        try await vault.write { database in
            try database.execute(sql: "CREATE TABLE cancellation_marker (value TEXT NOT NULL)")
            try database.execute(sql: "INSERT INTO cancellation_marker (value) VALUES ('kept')")
        }
        let artifacts = AccountPrivateDataArtifacts(
            accountID: accountID,
            applicationSupportDirectory: support,
            cachesDirectory: caches
        ).artifacts
        let events = DeletionEventLog()
        let service = AccountDataRemovalService(
            vaultRegistry: registry,
            applicationSupportDirectory: support,
            cachesDirectory: caches,
            eraseSecrets: { _ in await events.recordSecretErasure(vaultWasOpen: false, removalWasActive: false) },
            journalAuthority: TestAccountDeletionJournalAuthority()
        )

        let cancelled = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await service.removeAllPrivateData(for: accountID)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value

        let secretErasures = await events.secretErasures()
        let vaultIsOpen = await registry.isOpen(accountID: accountID)
        let removalIsActive = await registry.isBeingRemoved(accountID: accountID)
        XCTAssertTrue(cancelled)
        XCTAssertEqual(secretErasures, 0)
        XCTAssertTrue(vaultIsOpen)
        XCTAssertFalse(removalIsActive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.first(where: { $0.kind == .vault })!.url.path))
        let marker = try await vault.read { database in
            try String.fetchOne(database, sql: "SELECT value FROM cancellation_marker")
        }
        XCTAssertEqual(marker, "kept")
        try await registry.closeAll()
    }

    func testCancellationAfterVaultCloseRollsBackRemovalBeforeJournalAndKeyErasure() async throws {
        let support = try makeTemporaryDirectory()
        let caches = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: caches)
        }

        let accountID = AccountID.make()
        let key = try VaultKey.generate()
        let vaultRoot = support.appendingPathComponent("Triage", isDirectory: true)
        let registry = try VaultRegistry(rootDirectory: vaultRoot)
        let vault = try await registry.open(accountID: accountID, vaultKey: key)
        try await vault.write { database in
            try database.execute(sql: "CREATE TABLE delayed_cancellation_marker (value TEXT NOT NULL)")
            try database.execute(sql: "INSERT INTO delayed_cancellation_marker (value) VALUES ('kept')")
        }
        let events = DeletionEventLog()
        let barrier = DeletionBarrier()
        let service = AccountDataRemovalService(
            vaultRegistry: registry,
            applicationSupportDirectory: support,
            cachesDirectory: caches,
            eraseSecrets: { _ in
                await events.recordSecretErasure(vaultWasOpen: false, removalWasActive: false)
            },
            willBeginCryptoErasure: { await barrier.pause() },
            journalAuthority: TestAccountDeletionJournalAuthority()
        )
        let removalTask = Task {
            try await service.removeAllPrivateData(for: accountID)
        }

        await barrier.waitUntilPaused()
        let vaultIsOpenBeforeCancellation = await registry.isOpen(accountID: accountID)
        let removalIsActiveBeforeCancellation = await registry.isBeingRemoved(accountID: accountID)
        XCTAssertFalse(vaultIsOpenBeforeCancellation)
        XCTAssertTrue(removalIsActiveBeforeCancellation)
        removalTask.cancel()
        await barrier.resume()

        do {
            try await removalTask.value
            XCTFail("Expected cancellation before crypto-erasure.")
        } catch is CancellationError {
            // The removal gate is released because no irreversible action ran.
        }

        let secretErasures = await events.secretErasures()
        let removalIsActive = await registry.isBeingRemoved(accountID: accountID)
        let reopened = try await registry.open(accountID: accountID, vaultKey: key)
        let marker = try await reopened.read { database in
            try String.fetchOne(database, sql: "SELECT value FROM delayed_cancellation_marker")
        }
        let journalURL = support
            .appendingPathComponent("Triage", isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent(accountID.rawValue, isDirectory: true)
            .appendingPathComponent("account-deletion.json", isDirectory: false)
        XCTAssertEqual(secretErasures, 0)
        XCTAssertFalse(removalIsActive)
        XCTAssertEqual(marker, "kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        try await registry.closeAll()
    }

    func testCryptoErasureWaitsForPreErasureControllerDrain() async throws {
        let support = try makeTemporaryDirectory()
        let caches = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: caches)
        }

        let accountID = AccountID.make()
        let registry = try VaultRegistry(rootDirectory: support.appendingPathComponent("Triage", isDirectory: true))
        let events = DeletionEventLog()
        let drain = DeletionBarrier()
        let service = AccountDataRemovalService(
            vaultRegistry: registry,
            applicationSupportDirectory: support,
            cachesDirectory: caches,
            eraseSecrets: { _ in
                await events.recordSecretErasure(vaultWasOpen: false, removalWasActive: true)
            },
            willBeginCryptoErasure: { await drain.pause() },
            journalAuthority: TestAccountDeletionJournalAuthority()
        )

        let removal = Task { try await service.removeAllPrivateData(for: accountID) }
        await drain.waitUntilPaused()
        let erasuresBeforeDrain = await events.secretErasures()
        XCTAssertEqual(erasuresBeforeDrain, 0)

        await drain.resume()
        try await removal.value
        let erasuresAfterDrain = await events.secretErasures()
        XCTAssertEqual(erasuresAfterDrain, 1)
    }

    func testInterruptedPostErasureDeletionReplaysItsJournalAfterProcessRestart() async throws {
        let support = try makeTemporaryDirectory()
        let caches = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: caches)
        }

        let accountID = AccountID.make()
        let vaultRoot = support.appendingPathComponent("Triage", isDirectory: true)
        let registry = try VaultRegistry(rootDirectory: vaultRoot)
        _ = try await registry.open(accountID: accountID, vaultKey: try VaultKey.generate())
        let artifacts = AccountPrivateDataArtifacts(
            accountID: accountID,
            applicationSupportDirectory: support,
            cachesDirectory: caches
        ).artifacts
        let events = DeletionEventLog()
        let interrupted = AccountDataRemovalService(
            vaultRegistry: registry,
            applicationSupportDirectory: support,
            cachesDirectory: caches,
            eraseSecrets: { _ in await events.recordSecretErasure(vaultWasOpen: false, removalWasActive: true) },
            eraseArtifacts: { _ in throw URLError(.cannotWriteToFile) },
            journalAuthority: TestAccountDeletionJournalAuthority()
        )

        do {
            try await interrupted.removeAllPrivateData(for: accountID)
            XCTFail("Expected an interrupted artifact removal.")
        } catch is URLError {
            // Crypto-erasure has already occurred. The vault must remain closed.
        }

        let secretErasures = await events.secretErasures()
        let vaultIsOpen = await registry.isOpen(accountID: accountID)
        let removalIsActive = await registry.isBeingRemoved(accountID: accountID)
        XCTAssertEqual(secretErasures, 1)
        XCTAssertFalse(vaultIsOpen)
        XCTAssertTrue(removalIsActive)
        await XCTAssertThrowsErrorAsync {
            _ = try await registry.open(accountID: accountID, vaultKey: try VaultKey.generate())
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.first(where: { $0.kind == .vault })!.url.path))
        let journalURL = support
            .appendingPathComponent("Triage", isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent(accountID.rawValue, isDirectory: true)
            .appendingPathComponent("account-deletion.json", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertEqual(try posixPermissions(of: journalURL), 0o600)
        XCTAssertEqual(try posixPermissions(of: journalURL.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(
            try posixPermissions(of: journalURL.deletingLastPathComponent().deletingLastPathComponent()),
            0o700
        )
        XCTAssertEqual(
            try posixPermissions(
                of: journalURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            ),
            0o700
        )

        // A fresh registry simulates app relaunch: the in-memory removal gate
        // is gone, so recovery must depend on the durable journal instead.
        let restartedRegistry = try VaultRegistry(rootDirectory: vaultRoot)
        let recoveryOrdering = RecoveryCryptoErasureOrdering()
        let recovery = AccountDataRemovalService(
            vaultRegistry: restartedRegistry,
            applicationSupportDirectory: support,
            cachesDirectory: caches,
            eraseSecrets: { recoveredAccountID in
                await recoveryOrdering.record(.secretsErased(recoveredAccountID))
                await events.recordSecretErasure(vaultWasOpen: false, removalWasActive: true)
            },
            willBeginCryptoErasureForAccount: { recoveredAccountID in
                await recoveryOrdering.record(.drained(recoveredAccountID))
            },
            journalAuthority: TestAccountDeletionJournalAuthority()
        )
        let recoveredAccountIDs = try await recovery.recoverInterruptedRemovals()

        let totalSecretErasures = await events.secretErasures()
        let recoveryEvents = await recoveryOrdering.events()
        let secondReplay = try await recovery.recoverInterruptedRemovals()
        let secretErasuresAfterSecondReplay = await events.secretErasures()
        let recoveryEventsAfterSecondReplay = await recoveryOrdering.events()
        XCTAssertEqual(recoveredAccountIDs, [accountID])
        XCTAssertEqual(totalSecretErasures, 2)
        XCTAssertEqual(recoveryEvents, [.drained(accountID), .secretsErased(accountID)])
        XCTAssertEqual(secondReplay, [])
        XCTAssertEqual(secretErasuresAfterSecondReplay, 2)
        XCTAssertEqual(recoveryEventsAfterSecondReplay, recoveryEvents)
        XCTAssertTrue(artifacts.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.url.path)
        })
    }

    func testLateArtifactFailureRetainsJournalForRestartRecovery() async throws {
        let support = try makeTemporaryDirectory()
        let caches = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: caches)
        }

        let accountID = AccountID.make()
        let vaultRoot = support.appendingPathComponent("Triage", isDirectory: true)
        let registry = try VaultRegistry(rootDirectory: vaultRoot)
        _ = try await registry.open(accountID: accountID, vaultKey: try VaultKey.generate())
        let artifacts = AccountPrivateDataArtifacts(
            accountID: accountID,
            applicationSupportDirectory: support,
            cachesDirectory: caches
        ).artifacts
        let events = DeletionEventLog()
        let interrupted = AccountDataRemovalService(
            vaultRegistry: registry,
            applicationSupportDirectory: support,
            cachesDirectory: caches,
            eraseSecrets: { _ in await events.recordSecretErasure(vaultWasOpen: false, removalWasActive: true) },
            eraseArtifacts: { batch in
                for artifact in batch {
                    if artifact.kind == .previews {
                        throw URLError(.cannotWriteToFile)
                    }
                    if FileManager.default.fileExists(atPath: artifact.url.path) {
                        try FileManager.default.removeItem(at: artifact.url)
                    }
                }
            },
            journalAuthority: TestAccountDeletionJournalAuthority()
        )

        try await assertInterruptedDeletion(interrupted, accountID: accountID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL(for: accountID, support: support).path))

        let recovery = AccountDataRemovalService(
            vaultRegistry: try VaultRegistry(rootDirectory: vaultRoot),
            applicationSupportDirectory: support,
            cachesDirectory: caches,
            eraseSecrets: { _ in await events.recordSecretErasure(vaultWasOpen: false, removalWasActive: true) },
            journalAuthority: TestAccountDeletionJournalAuthority()
        )
        let recoveredAccountIDs = try await recovery.recoverInterruptedRemovals()
        let secretErasures = await events.secretErasures()

        XCTAssertEqual(recoveredAccountIDs, [accountID])
        XCTAssertEqual(secretErasures, 2)
        XCTAssertTrue(artifacts.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.url.path)
        })
    }

    func testRecoveryRejectsTamperedOrUnsupportedJournalWithoutDeletingData() async throws {
        let support = try makeTemporaryDirectory()
        let caches = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: caches)
        }

        let accountID = AccountID.make()
        let vaultRoot = support.appendingPathComponent("Triage", isDirectory: true)
        let registry = try VaultRegistry(rootDirectory: vaultRoot)
        _ = try await registry.open(accountID: accountID, vaultKey: try VaultKey.generate())
        let artifacts = AccountPrivateDataArtifacts(
            accountID: accountID,
            applicationSupportDirectory: support,
            cachesDirectory: caches
        ).artifacts
        let events = DeletionEventLog()
        let interrupted = AccountDataRemovalService(
            vaultRegistry: registry,
            applicationSupportDirectory: support,
            cachesDirectory: caches,
            eraseSecrets: { _ in await events.recordSecretErasure(vaultWasOpen: false, removalWasActive: true) },
            eraseArtifacts: { _ in throw URLError(.cannotWriteToFile) },
            journalAuthority: TestAccountDeletionJournalAuthority()
        )
        try await assertInterruptedDeletion(interrupted, accountID: accountID)
        let journalURL = journalURL(for: accountID, support: support)
        var tamperedV2 = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any]
        )
        tamperedV2["signature"] = Data(repeating: 0, count: 32).base64EncodedString()
        try JSONSerialization.data(withJSONObject: tamperedV2).write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: journalURL.path
        )

        let restartedRegistry = try VaultRegistry(rootDirectory: vaultRoot)
        let recovery = AccountDataRemovalService(
            vaultRegistry: restartedRegistry,
            applicationSupportDirectory: support,
            cachesDirectory: caches,
            eraseSecrets: { _ in await events.recordSecretErasure(vaultWasOpen: false, removalWasActive: true) },
            journalAuthority: TestAccountDeletionJournalAuthority()
        )
        let tamperedReplay = try await recovery.recoverInterruptedRemovals()
        let erasuresAfterTamper = await events.secretErasures()

        XCTAssertEqual(tamperedReplay, [])
        XCTAssertEqual(erasuresAfterTamper, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts[0].url.path))

        try Data(
            "{\"version\":999,\"accountID\":\"\(accountID.rawValue)\",\"checksum\":\"ignored\"}".utf8
        ).write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: journalURL.path
        )
        let unsupportedReplay = try await recovery.recoverInterruptedRemovals()
        let erasuresAfterUnsupportedVersion = await events.secretErasures()

        XCTAssertEqual(unsupportedReplay, [])
        XCTAssertEqual(erasuresAfterUnsupportedVersion, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts[0].url.path))

        // Version 1's public SHA-256 checksum was forgeable. A syntactically
        // valid legacy journal must not authorize irreversible recovery after
        // the authenticated v2 format ships.
        let legacyMaterial = "triage-account-deletion-journal\u{1F}1\u{1F}\(accountID.rawValue)"
        let legacyChecksum = SHA256.hash(data: Data(legacyMaterial.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        try Data(
            "{\"version\":1,\"accountID\":\"\(accountID.rawValue)\",\"checksum\":\"\(legacyChecksum)\"}".utf8
        ).write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: journalURL.path
        )
        let forgedLegacyReplay = try await recovery.recoverInterruptedRemovals()
        let erasuresAfterForgedLegacy = await events.secretErasures()

        XCTAssertEqual(forgedLegacyReplay, [])
        XCTAssertEqual(erasuresAfterForgedLegacy, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts[0].url.path))
    }

    func testRecoveryRefusesRelaxedJournalAndDirectoryPermissionsWithoutDeletingData() async throws {
        let support = try makeTemporaryDirectory()
        let caches = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: caches)
        }

        let accountID = AccountID.make()
        let vaultRoot = support.appendingPathComponent("Triage", isDirectory: true)
        let registry = try VaultRegistry(rootDirectory: vaultRoot)
        _ = try await registry.open(accountID: accountID, vaultKey: try VaultKey.generate())
        let artifacts = AccountPrivateDataArtifacts(
            accountID: accountID,
            applicationSupportDirectory: support,
            cachesDirectory: caches
        ).artifacts
        let events = DeletionEventLog()
        let interrupted = AccountDataRemovalService(
            vaultRegistry: registry,
            applicationSupportDirectory: support,
            cachesDirectory: caches,
            eraseSecrets: { _ in await events.recordSecretErasure(vaultWasOpen: false, removalWasActive: true) },
            eraseArtifacts: { _ in throw URLError(.cannotWriteToFile) },
            journalAuthority: TestAccountDeletionJournalAuthority()
        )
        try await assertInterruptedDeletion(interrupted, accountID: accountID)

        let journal = journalURL(for: accountID, support: support)
        let accountDirectory = journal.deletingLastPathComponent()
        let recovery = AccountDataRemovalService(
            vaultRegistry: try VaultRegistry(rootDirectory: vaultRoot),
            applicationSupportDirectory: support,
            cachesDirectory: caches,
            eraseSecrets: { _ in await events.recordSecretErasure(vaultWasOpen: false, removalWasActive: true) },
            journalAuthority: TestAccountDeletionJournalAuthority()
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: journal.path)
        let insecureJournalReplay = try await recovery.recoverInterruptedRemovals()
        let erasuresAfterInsecureJournal = await events.secretErasures()
        XCTAssertEqual(insecureJournalReplay, [])
        XCTAssertEqual(erasuresAfterInsecureJournal, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts[0].url.path))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: accountDirectory.path)
        let insecureDirectoryReplay = try await recovery.recoverInterruptedRemovals()
        let erasuresAfterInsecureDirectory = await events.secretErasures()
        XCTAssertEqual(insecureDirectoryReplay, [])
        XCTAssertEqual(erasuresAfterInsecureDirectory, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts[0].url.path))
    }

    func testRecoveryRefusesJournalSymlinkWithoutFollowingItsTarget() async throws {
        let support = try makeTemporaryDirectory()
        let caches = try makeTemporaryDirectory()
        let external = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: caches)
            try? FileManager.default.removeItem(at: external)
        }

        let accountID = AccountID.make()
        let vaultRoot = support.appendingPathComponent("Triage", isDirectory: true)
        let registry = try VaultRegistry(rootDirectory: vaultRoot)
        _ = try await registry.open(accountID: accountID, vaultKey: try VaultKey.generate())
        try await registry.closeAll()
        let vaultDirectory = VaultPaths(rootDirectory: vaultRoot, accountID: accountID).directory
        let target = external.appendingPathComponent("outside-journal")
        try Data("outside".utf8).write(to: target)
        let journalURL = journalURL(for: accountID, support: support)
        try FileManager.default.createDirectory(
            at: journalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        for directory in [
            support.appendingPathComponent("Triage", isDirectory: true),
            journalURL.deletingLastPathComponent().deletingLastPathComponent(),
            journalURL.deletingLastPathComponent()
        ] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
        try FileManager.default.createSymbolicLink(at: journalURL, withDestinationURL: target)
        let events = DeletionEventLog()
        let service = AccountDataRemovalService(
            vaultRegistry: registry,
            applicationSupportDirectory: support,
            cachesDirectory: caches,
            eraseSecrets: { _ in await events.recordSecretErasure(vaultWasOpen: false, removalWasActive: false) },
            journalAuthority: TestAccountDeletionJournalAuthority()
        )

        let replayed = try await service.recoverInterruptedRemovals()
        let secretErasures = await events.secretErasures()

        XCTAssertEqual(replayed, [])
        XCTAssertEqual(secretErasures, 0)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "outside")
        XCTAssertTrue(FileManager.default.fileExists(atPath: vaultDirectory.path))
    }

    func testDeletionRefusesSymlinkedSupportRootBeforeSecretErasure() async throws {
        let support = try makeTemporaryDirectory()
        let caches = try makeTemporaryDirectory()
        let external = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: caches)
            try? FileManager.default.removeItem(at: external)
        }

        let accountID = AccountID.make()
        let externalMarker = external.appendingPathComponent("must-not-delete")
        try Data("outside".utf8).write(to: externalMarker)
        try FileManager.default.createSymbolicLink(
            at: support.appendingPathComponent("Triage", isDirectory: true),
            withDestinationURL: external
        )
        let events = DeletionEventLog()
        let service = AccountDataRemovalService(
            vaultRegistry: try VaultRegistry(rootDirectory: support.appendingPathComponent("separate", isDirectory: true)),
            applicationSupportDirectory: support,
            cachesDirectory: caches,
            eraseSecrets: { _ in await events.recordSecretErasure(vaultWasOpen: false, removalWasActive: false) },
            journalAuthority: TestAccountDeletionJournalAuthority()
        )

        do {
            try await service.removeAllPrivateData(for: accountID)
            XCTFail("Expected symlinked support root to be refused.")
        } catch let error as AccountDataRemovalError {
            XCTAssertEqual(error, .unsafeArtifactPath)
        }

        let secretErasures = await events.secretErasures()
        XCTAssertEqual(secretErasures, 0)
        XCTAssertEqual(try String(contentsOf: externalMarker, encoding: .utf8), "outside")
    }

    func testDeletionRejectsNonOpaqueAccountIDBeforeTouchingStorage() async throws {
        let support = try makeTemporaryDirectory()
        let caches = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: caches)
        }

        let accountID = AccountID(rawValue: "../outside")!
        let events = DeletionEventLog()
        let service = AccountDataRemovalService(
            vaultRegistry: try VaultRegistry(rootDirectory: support.appendingPathComponent("Triage", isDirectory: true)),
            applicationSupportDirectory: support,
            cachesDirectory: caches,
            eraseSecrets: { _ in await events.recordSecretErasure(vaultWasOpen: false, removalWasActive: false) },
            journalAuthority: TestAccountDeletionJournalAuthority()
        )

        do {
            try await service.removeAllPrivateData(for: accountID)
            XCTFail("Expected non-opaque account ID to be rejected.")
        } catch let error as AccountDataRemovalError {
            XCTAssertEqual(error, .invalidOpaqueAccountID)
        }

        let secretErasures = await events.secretErasures()
        XCTAssertEqual(secretErasures, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("Triage").path))
    }

    func testRecoveryNeverErasesAnUnjournaledVault() async throws {
        let support = try makeTemporaryDirectory()
        let caches = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: caches)
        }

        let accountID = AccountID.make()
        let vaultRoot = support.appendingPathComponent("Triage", isDirectory: true)
        let registry = try VaultRegistry(rootDirectory: vaultRoot)
        _ = try await registry.open(accountID: accountID, vaultKey: try VaultKey.generate())
        try await registry.closeAll()
        let vaultDirectory = VaultPaths(rootDirectory: vaultRoot, accountID: accountID).directory
        let events = DeletionEventLog()
        let service = AccountDataRemovalService(
            vaultRegistry: registry,
            applicationSupportDirectory: support,
            cachesDirectory: caches,
            eraseSecrets: { _ in
                await events.recordSecretErasure(vaultWasOpen: false, removalWasActive: false)
            },
            journalAuthority: TestAccountDeletionJournalAuthority()
        )

        let recoveredAccountIDs = try await service.recoverInterruptedRemovals()
        let secretErasures = await events.secretErasures()

        XCTAssertEqual(recoveredAccountIDs, [])
        XCTAssertEqual(secretErasures, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vaultDirectory.path))
    }
}

/// Tests exercise journal authenticity without reading or creating the app's
/// production device-only Keychain authority.
private struct TestAccountDeletionJournalAuthority: AccountDeletionJournalAuthenticating {
    func sign(accountID: AccountID) throws -> Data {
        Data(SHA256.hash(data: material(for: accountID)))
    }

    func verify(signature: Data, accountID: AccountID) throws -> Bool {
        signature == Data(SHA256.hash(data: material(for: accountID)))
    }

    private func material(for accountID: AccountID) -> Data {
        Data("triage-test-deletion-journal\u{1F}\(accountID.rawValue)".utf8)
    }
}

private actor DeletionEventLog {
    private var secretErasureCount = 0
    private var vaultOpenAtSecretErasure: Bool?
    private var removalActiveAtSecretErasure: Bool?

    func recordSecretErasure(vaultWasOpen: Bool, removalWasActive: Bool) {
        secretErasureCount += 1
        vaultOpenAtSecretErasure = vaultWasOpen
        removalActiveAtSecretErasure = removalWasActive
    }

    func secretErasures() -> Int { secretErasureCount }
    func vaultWasOpenAtSecretErasure() -> Bool? { vaultOpenAtSecretErasure }
    func removalWasActiveAtSecretErasure() -> Bool? { removalActiveAtSecretErasure }
}

private actor RecoveryCryptoErasureOrdering {
    enum Event: Equatable, Sendable {
        case drained(AccountID)
        case secretsErased(AccountID)
    }

    private var storage = [Event]()

    func record(_ event: Event) { storage.append(event) }
    func events() -> [Event] { storage }
}

private actor DeletionBarrier {
    private var paused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        let waiters = pauseWaiters
        pauseWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilPaused() async {
        guard !paused else { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func resume() {
        let continuation = resumeContinuation
        resumeContinuation = nil
        continuation?.resume()
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func journalURL(for accountID: AccountID, support: URL) -> URL {
    support
        .appendingPathComponent("Triage", isDirectory: true)
        .appendingPathComponent("Recovery", isDirectory: true)
        .appendingPathComponent(accountID.rawValue, isDirectory: true)
        .appendingPathComponent("account-deletion.json", isDirectory: false)
}

private func posixPermissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private func assertInterruptedDeletion(
    _ service: AccountDataRemovalService,
    accountID: AccountID,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    do {
        try await service.removeAllPrivateData(for: accountID)
        XCTFail("Expected an interrupted artifact deletion.", file: file, line: line)
    } catch is URLError {
        // Expected: the journal was persisted before artifact cleanup failed.
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {
        // Expected.
    }
}
