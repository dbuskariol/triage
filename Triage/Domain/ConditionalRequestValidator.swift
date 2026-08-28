import Foundation

struct ConditionalRequestValidator: Equatable, Sendable {
    let requestKey: String
    let accountID: AccountID
    let eTag: String?
    let lastModified: String?
    let observedAt: Date
}
