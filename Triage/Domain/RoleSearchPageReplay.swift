import Foundation

struct RoleSearchPageReplay: Equatable, Sendable {
    let requestKey: String
    let accountID: AccountID
    let organizationID: OrganizationID
    let queryValue: String
    let page: Int
    let endpoint: String
    let credentialRevision: CredentialRevision
    let capabilityRevision: CapabilityRevision
    let rawSnapshotID: RawAPISnapshotID
    let eTag: String
    let parserVersion: Int
    let lastValidatedAt: Date
}

struct RoleSearchPageReplayEntry: Equatable, Sendable {
    let replay: RoleSearchPageReplay
    let snapshot: RawAPISnapshot
}
