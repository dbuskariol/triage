import Foundation

enum OrganizationRefreshBlockReason: String, Codable, Sendable {
    case authenticationRequired
    case ssoRequired
    case approvalRequired
}

struct OrganizationSchedulerState: Codable, Equatable, Sendable {
    let accountID: AccountID
    let organizationID: OrganizationID
    let credentialRevision: CredentialRevision
    let capabilityRevision: CapabilityRevision
    let nextIncrementalRefreshAt: Date
    let nextFullReconciliationAt: Date
    let rateLimitedUntil: Date?
    let blockedReason: OrganizationRefreshBlockReason?
    let consecutiveTransientFailureCount: Int
    let activeAttemptID: UUID?
    let lastAttemptAt: Date?
    let lastCompletedAt: Date?
    let generation: UInt64
    let updatedAt: Date
}
