import Foundation

actor WorkflowActionService {
    private let secretStore: KeychainSecretStore
    private let vaultRegistry: VaultRegistry

    init(secretStore: KeychainSecretStore, vaultRegistry: VaultRegistry) {
        self.secretStore = secretStore
        self.vaultRegistry = vaultRegistry
    }

    func apply(
        _ action: WorkflowAction,
        to workItem: WorkItem,
        at date: Date = .now
    ) async throws -> WorkItem {
        let transition = WorkflowTransitionEngine.apply(action, to: workItem.workflow, at: date)
        guard let vaultKey = try await secretStore.readVaultKey(for: workItem.accountID) else {
            throw AccountCredentialReaderError.missingAccessToken
        }
        let vault = try await vaultRegistry.open(accountID: workItem.accountID, vaultKey: vaultKey)
        let scope = try await AccountRepository(vault: vault).synchronizationScope(
            for: workItem.accountID,
            organizationID: workItem.organizationID
        )
        _ = try await WorkflowHistoryRepository(vault: vault).apply(
            action,
            to: [workItem.id],
            in: scope,
            at: date
        )
        return workItem.replacing(workflow: transition.next)
    }
}
