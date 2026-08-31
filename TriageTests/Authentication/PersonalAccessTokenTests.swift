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

    @MainActor
    func testPATFailureReplacesPriorOAuthConfigurationError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-pat-oauth-isolation-\(UUID().uuidString)", isDirectory: true)
        let defaultsSuite = "triage-pat-oauth-isolation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
            try? FileManager.default.removeItem(at: directory)
        }

        let model = TriageAppModel(
            dependencies: .init(
                accountSession: PATFailureAccountSession(),
                workspaceCoordinator: PATFailureWorkspaceCoordinator(),
                refreshLifecycle: PATFailureRefreshLifecycle(),
                workspaceObserver: PATFailureWorkspaceObserver(),
                workspaceMutator: PATFailureWorkspaceMutator()
            ),
            vaultRegistry: try VaultRegistry(rootDirectory: directory),
            defaults: defaults
        )

        await model.connectGitHub(presentationAnchor: NSWindow())
        XCTAssertEqual(model.connectionError, "GitHub sign-in is not configured in this build.")

        await model.connectPersonalAccessToken(
            "ghp_abcdefghijklmnopqrstuvwxyz",
            resourceOwnerOrganization: nil
        )
        XCTAssertEqual(
            model.connectionError,
            "Triage could not validate this personal access token. Check its access and try again."
        )
        await model.shutdown()
    }

    @MainActor
    func testFineGrainedOwnerFailureShowsItsActionableRecoveryMessage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-pat-owner-message-\(UUID().uuidString)", isDirectory: true)
        let defaultsSuite = "triage-pat-owner-message-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
            try? FileManager.default.removeItem(at: directory)
        }

        let model = TriageAppModel(
            dependencies: .init(
                accountSession: PATFailureAccountSession(
                    personalAccessTokenError: AccountConnectionError
                        .missingFineGrainedResourceOwnerOrganization
                ),
                workspaceCoordinator: PATFailureWorkspaceCoordinator(),
                refreshLifecycle: PATFailureRefreshLifecycle(),
                workspaceObserver: PATFailureWorkspaceObserver(),
                workspaceMutator: PATFailureWorkspaceMutator()
            ),
            vaultRegistry: try VaultRegistry(rootDirectory: directory),
            defaults: defaults
        )

        await model.connectPersonalAccessToken(
            "github_pat_abcdefghijklmnopqrstuvwxyz",
            resourceOwnerOrganization: " \n\t "
        )

        XCTAssertEqual(
            model.connectionError,
            "Enter the resource-owner organization selected when you created this fine-grained personal access token."
        )
        await model.shutdown()
    }

    @MainActor
    func testReplacementPATFailureReplacesPriorOAuthConfigurationError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-pat-replacement-oauth-isolation-\(UUID().uuidString)", isDirectory: true)
        let defaultsSuite = "triage-pat-replacement-oauth-isolation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
            try? FileManager.default.removeItem(at: directory)
        }

        let model = TriageAppModel(
            dependencies: .init(
                accountSession: PATFailureAccountSession(),
                workspaceCoordinator: PATFailureWorkspaceCoordinator(),
                refreshLifecycle: PATFailureRefreshLifecycle(),
                workspaceObserver: PATFailureWorkspaceObserver(),
                workspaceMutator: PATFailureWorkspaceMutator()
            ),
            vaultRegistry: try VaultRegistry(rootDirectory: directory),
            defaults: defaults
        )
        let account = GitHubAccount(
            id: AccountID(rawValue: "replacement-account")!,
            githubUserID: 1,
            nodeID: GitHubNodeID(rawValue: "U_1")!,
            login: "octocat",
            authenticationKind: .classicPersonalAccessToken,
            credentialID: CredentialID(rawValue: "replacement-credential")!,
            credentialStatus: .active,
            createdAt: .now
        )
        model.install(
            accounts: [account],
            organizations: [],
            organizationAccesses: [:],
            for: account.id
        )

        await model.connectGitHub(presentationAnchor: NSWindow())
        XCTAssertEqual(model.connectionError, "GitHub sign-in is not configured in this build.")

        await model.replacePersonalAccessToken("ghp_abcdefghijklmnopqrstuvwxyz", for: account)
        XCTAssertEqual(
            model.connectionError,
            "Triage could not replace this personal access token. Check its access and try again."
        )
        await model.shutdown()
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

private struct PATFailureAccountSession: AccountSessionServing {
    private let personalAccessTokenError: any Error & Sendable

    init(personalAccessTokenError: any Error & Sendable = URLError(.badServerResponse)) {
        self.personalAccessTokenError = personalAccessTokenError
    }

    func restoreAccounts() async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func connectOAuth(_: AuthBrokerExchangeRequest) async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func connectPersonalAccessToken(
        _: PersonalAccessToken,
        resourceOwnerOrganization _: String?
    ) async throws -> AccountSessionSnapshot {
        throw personalAccessTokenError
    }
    func reconnectOAuth(
        _: AuthBrokerExchangeRequest,
        replacing _: GitHubAccount
    ) async throws -> AccountSessionSnapshot { try emptySnapshot() }
    func replacePersonalAccessToken(
        _: PersonalAccessToken,
        replacing _: GitHubAccount
    ) async throws -> AccountSessionSnapshot {
        throw URLError(.badServerResponse)
    }
    func removeAccount(_: AccountID) async throws {}

    private func emptySnapshot() throws -> AccountSessionSnapshot {
        try AccountSessionSnapshot(
            accounts: [],
            organizationsByAccount: [:],
            organizationAccessesByAccount: [:],
            accountCapabilitiesByAccount: [:]
        )
    }
}

private struct PATFailureWorkspaceCoordinator: WorkspaceCoordinating {
    func select(_: SynchronizationScope) async throws -> AccountOrganizationCoordinatorState? { nil }
    func refresh(
        _: SynchronizationScope,
        priority _: AccountOrganizationRefreshPriority
    ) async throws -> AccountOrganizationCoordinatorState? { nil }
    func cancel(_: SynchronizationScope) async throws {}
    func cancelAll(for _: AccountID) async throws {}
    func shutdown() async {}
}

private struct PATFailureRefreshLifecycle: OrganizationRefreshLifecycleHandling {
    func launch(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {}
    func applicationDidBecomeActive(
        synchronizationScopes _: [SynchronizationScope],
        activeAccountID _: AccountID?
    ) async {}
    func wake(synchronizationScopes _: [SynchronizationScope], activeAccountID _: AccountID?) async {}
    func scheduleOpportunisticBackgroundRefresh(
        synchronizationScopes _: [SynchronizationScope],
        activeAccountID _: AccountID?
    ) async {}
    func stop() async {}
}

private struct PATFailureWorkspaceObserver: WorkspaceObserving {
    func snapshots(
        for _: SynchronizationScope
    ) async throws -> AsyncThrowingStream<WorkspacePresentationSnapshot, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct PATFailureWorkspaceMutator: WorkspaceMutating {
    func apply(_: WorkflowAction, to _: WorkItemID, in _: SynchronizationScope) async throws {}
    func completeActionItem(
        _: ActionItemID,
        in _: WorkItemID,
        scope _: SynchronizationScope
    ) async throws {}
    func editActionItem(_: LocalActionItemEdit, actionItemID _: ActionItemID, in _: WorkItemID, expectedUpdatedAt _: Date, scope _: SynchronizationScope) async throws -> ActionItem { throw CancellationError() }
}
