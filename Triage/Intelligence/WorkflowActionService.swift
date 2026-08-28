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
        try await WorkflowRepository(vault: vault).save(transition.next, for: workItem.id)
        return workItem.replacing(workflow: transition.next)
    }
}
