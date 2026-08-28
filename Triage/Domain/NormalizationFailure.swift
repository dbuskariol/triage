import Foundation

struct NormalizationFailure: Equatable, Sendable {
    let id: UUID
    let accountID: AccountID
    let rawSnapshotID: RawAPISnapshotID
    let githubNodeID: GitHubNodeID?
    let endpoint: String
    let parserVersion: Int
    let occurredAt: Date
    let redactedDiagnostic: String
}
