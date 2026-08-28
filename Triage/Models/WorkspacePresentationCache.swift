import Foundation

struct WorkspacePresentationCache<Value> {
    private struct Key: Hashable {
        let accountID: AccountID
        let organizationID: OrganizationID
    }

    private var values: [Key: Value] = [:]

    subscript(accountID: AccountID, organizationID: OrganizationID) -> Value? {
        get {
            values[Key(accountID: accountID, organizationID: organizationID)]
        }
        set {
            values[Key(accountID: accountID, organizationID: organizationID)] = newValue
        }
    }

    mutating func removeAll(for accountID: AccountID) {
        values = values.filter { $0.key.accountID != accountID }
    }
}
