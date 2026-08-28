import Foundation

struct RawAPISnapshot: Equatable, Sendable {
    let id: RawAPISnapshotID
    let accountID: AccountID
    let githubNodeID: GitHubNodeID?
    let endpoint: String
    let eTag: String?
    let parserVersion: Int
    let observedAt: Date
    let payload: Data
}
