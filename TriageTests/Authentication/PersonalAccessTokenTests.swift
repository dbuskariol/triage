import AppKit
import Foundation
import XCTest
@testable import Triage

final class PersonalAccessTokenTests: XCTestCase {
    func testDetectsFineGrainedTokenWithoutExposingIt() throws {
        let token = try PersonalAccessToken(rawValue: "github_pat_abcdefghijklmnopqrstuvwxyz")

        XCTAssertEqual(token.kind, .fineGrained)
        XCTAssertEqual(token.kind.authenticationKind, .fineGrainedPersonalAccessToken)
        XCTAssertTrue(token.kind.supportsDirectCopilotAuthentication)
        XCTAssertFalse(token.description.contains("abcdefghijklmnopqrstuvwxyz"))
    }

    func testDetectsClassicTokenAndRequiresSeparateCopilotSignIn() throws {
        let token = try PersonalAccessToken(rawValue: "ghp_abcdefghijklmnopqrstuvwxyz")

        XCTAssertEqual(token.kind, .classic)
        XCTAssertEqual(token.kind.authenticationKind, .classicPersonalAccessToken)
        XCTAssertFalse(token.kind.supportsDirectCopilotAuthentication)
    }

    func testRejectsWhitespaceAndUnrecognizedTokenFamilies() {
        XCTAssertThrowsError(try PersonalAccessToken(rawValue: " github_pat_abc"))
        XCTAssertThrowsError(try PersonalAccessToken(rawValue: "github_pat_abc\n"))
        XCTAssertThrowsError(try PersonalAccessToken(rawValue: "gho_not-a-pat"))
    }

    func testFineGrainedConnectionRejectsMissingResourceOwnerBeforeNetworkOrPersistence() async throws {
        try await assertFineGrainedConnectionRejectsUnusableResourceOwner(nil)
    }

    func testFineGrainedConnectionRejectsBlankResourceOwnerBeforeNetworkOrPersistence() async throws {
        try await assertFineGrainedConnectionRejectsUnusableResourceOwner(" \n\t ")
    }

    func testClassicTokenDoesNotRequireAResourceOwnerOrganization() throws {
        let token = try PersonalAccessToken(rawValue: "ghp_abcdefghijklmnopqrstuvwxyz")

        XCTAssertNil(
            try AccountConnectionService.resourceOwnerOrganization(
                for: token,
                suppliedValue: nil
            )
        )
    }

    private func assertFineGrainedConnectionRejectsUnusableResourceOwner(
        _ owner: String?
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-fine-grained-owner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secretStore = ConnectionSecretStoreSpy()
        let cleanup = ConnectionSecretCleanupSpy()
        let service = AccountConnectionService(
            secretStore: secretStore,
            vaultRegistry: try VaultRegistry(rootDirectory: directory),
            removeAllSecrets: { _ in
                await cleanup.record()
            }
        )
        let token = try PersonalAccessToken(rawValue: "github_pat_abcdefghijklmnopqrstuvwxyz")

        do {
            _ = try await service.connect(
                personalAccessToken: token,
                resourceOwnerOrganization: owner
            )
            XCTFail("A fine-grained token without a usable resource owner must be rejected.")
        } catch let error as AccountConnectionError {
            XCTAssertEqual(error, .missingFineGrainedResourceOwnerOrganization)
            XCTAssertEqual(
                error.recoveryDescription,
                "Enter the resource-owner organization selected when you created this fine-grained personal access token."
            )
        }

        let operations = await secretStore.operations()
        XCTAssertEqual(operations.reads, 0)
        XCTAssertEqual(operations.writes, 0)
        XCTAssertEqual(operations.removals, 0)
        let cleanupCount = await cleanup.count()
        XCTAssertEqual(cleanupCount, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Vaults", isDirectory: true).path
            ),
            "Validation must finish before creating an account vault."
        )
    }
}

private actor ConnectionSecretStoreSpy: SecretStore {
    struct Operations: Equatable {
        var reads = 0
        var writes = 0
        var removals = 0
    }

    private var recordedOperations = Operations()

    func read(
        kind _: TriageSecretKind,
        accountID _: AccountID,
        credentialID _: CredentialID?
    ) async throws -> Data? {
        recordedOperations.reads += 1
        return nil
    }

    func write(
        _: Data,
        kind _: TriageSecretKind,
        accountID _: AccountID,
        credentialID _: CredentialID?
    ) async throws {
        recordedOperations.writes += 1
    }

    func remove(
        kind _: TriageSecretKind,
        accountID _: AccountID,
        credentialID _: CredentialID?
    ) async throws {
        recordedOperations.removals += 1
    }

    func accountIDs() async throws -> [AccountID] {
        []
    }

    func operations() -> Operations {
        recordedOperations
    }
}

private actor ConnectionSecretCleanupSpy {
    private var cleanupCount = 0

    func record() {
        cleanupCount += 1
    }

    func count() -> Int {
        cleanupCount
    }
}
