import Foundation

struct SyncStream: Equatable, Sendable {
    let id: SyncStreamID
    let accountID: AccountID
    let organizationID: OrganizationID
    let feature: CoverageFeature
    let highWater: Date?
    let lastSuccessfulAt: Date?
    let lastAttemptAt: Date?
    let status: CoverageStatus
    let failureDetail: String?
}
