import Foundation

/// Keeps the per-account authorization controller shared by Settings and the
/// refresh runtime. The controller itself is still scoped at every operation;
/// this registry only preserves cancellation generations while a vault lives.
protocol OrganizationAIControllerProviding: Sendable {
    func controller(for vault: AccountVault) async -> OrganizationAIController
    func evict(accountID: AccountID) async
}

actor OrganizationAIControllerRegistry: OrganizationAIControllerProviding {
    private var controllers: [AccountID: OrganizationAIController] = [:]

    func controller(for vault: AccountVault) -> OrganizationAIController {
        if let controller = controllers[vault.accountID] { return controller }
        let controller = OrganizationAIController(vault: vault)
        controllers[vault.accountID] = controller
        return controller
    }

    func evict(accountID: AccountID) async {
        guard let controller = controllers.removeValue(forKey: accountID) else { return }
        await controller.cancelAll()
    }
}
