import Foundation

enum SyncShardState: String, Codable, Sendable {
    case pending
    case running
    case completed
    case failed
}

struct SyncShard: Equatable, Sendable {
    let id: SyncShardID
    let streamID: SyncStreamID
    let queryKind: String
    let intervalStart: Date?
    let intervalEnd: Date?
    let pageCursor: String?
    let state: SyncShardState
    let completedAt: Date?
}
