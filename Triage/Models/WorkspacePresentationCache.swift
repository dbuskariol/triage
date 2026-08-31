import Foundation

struct WorkspacePresentationCache<Value> {
    private struct Key: Hashable {
        let accountID: AccountID
        let organizationID: OrganizationID
    }

    private let capacity: Int
    private var values: [Key: Value] = [:]
    private var leastRecentlyUsedFirst: [Key] = []

    init(capacity: Int = 12) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    subscript(accountID: AccountID, organizationID: OrganizationID) -> Value? {
        mutating get {
            let key = Key(accountID: accountID, organizationID: organizationID)
            guard let value = values[key] else { return nil }
            touch(key)
            return value
        }
        set {
            let key = Key(accountID: accountID, organizationID: organizationID)
            guard let newValue else {
                values[key] = nil
                leastRecentlyUsedFirst.removeAll { $0 == key }
                return
            }
            values[key] = newValue
            touch(key)
            while values.count > capacity, let oldest = leastRecentlyUsedFirst.first {
                leastRecentlyUsedFirst.removeFirst()
                values[oldest] = nil
            }
        }
    }

    mutating func removeAll(for accountID: AccountID) {
        values = values.filter { $0.key.accountID != accountID }
        leastRecentlyUsedFirst.removeAll { $0.accountID == accountID }
    }

    private mutating func touch(_ key: Key) {
        leastRecentlyUsedFirst.removeAll { $0 == key }
        leastRecentlyUsedFirst.append(key)
    }
}
