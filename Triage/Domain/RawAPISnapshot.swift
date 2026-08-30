import Foundation

struct RawAPISnapshot: Equatable, Sendable {
    let id: RawAPISnapshotID
    let accountID: AccountID
    let githubNodeID: GitHubNodeID?
    let endpoint: String
    let eTag: String?
    let lastModified: String?
    let parserVersion: Int
    let observedAt: Date
    let payload: Data
    let requestIdentity: ConditionalRequestIdentity?

    init(
        id: RawAPISnapshotID,
        accountID: AccountID,
        githubNodeID: GitHubNodeID?,
        endpoint: String,
        eTag: String?,
        lastModified: String? = nil,
        parserVersion: Int,
        observedAt: Date,
        payload: Data,
        requestIdentity: ConditionalRequestIdentity? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.githubNodeID = githubNodeID
        self.endpoint = endpoint
        self.eTag = eTag
        self.lastModified = lastModified
        self.parserVersion = parserVersion
        self.observedAt = observedAt
        self.payload = payload
        self.requestIdentity = requestIdentity
    }
}
