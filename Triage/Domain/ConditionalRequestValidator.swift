import Foundation

struct ConditionalRequestIdentity: Equatable, Hashable, Sendable {
    let scope: SynchronizationScope
    let feature: CoverageFeature
    let streamID: SyncStreamID
    let requestKey: String
}

struct ConditionalRequestValidator: Equatable, Sendable {
    let identity: ConditionalRequestIdentity
    let eTag: String?
    let lastModified: String?
    let observedAt: Date
}

enum ConditionalRequestCacheMutation: Equatable, Sendable {
    case save(ConditionalRequestValidator)
    case remove(ConditionalRequestIdentity)
}
