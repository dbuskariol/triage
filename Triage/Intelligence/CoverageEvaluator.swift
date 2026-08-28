import Foundation

struct CoverageRequirement: Sendable {
    let feature: CoverageFeature
    let repositoryID: RepositoryID?
}

struct CoverageEvaluation: Sendable {
    let freshness: FreshnessState
    let missing: [CoverageRequirement]

    var isComplete: Bool { missing.isEmpty }
}

struct CoverageEvaluator: Sendable {
    func evaluate(
        requirements: [CoverageRequirement],
        records: [CoverageRecord],
        accountID: AccountID,
        organizationID: OrganizationID,
        credentialRevision: CredentialRevision,
        capabilityRevision: CapabilityRevision
    ) -> CoverageEvaluation {
        var missing: [CoverageRequirement] = []
        var statuses: [CoverageStatus] = []
        var latestSuccess: Date?

        for requirement in requirements {
            let matching = records.filter {
                $0.accountID == accountID
                    && $0.organizationID == organizationID
                    && $0.repositoryID == requirement.repositoryID
                    && $0.feature == requirement.feature
                    && $0.credentialRevision == credentialRevision
                    && $0.capabilityRevision == capabilityRevision
            }
            guard let record = matching.max(by: { ($0.lastSuccessfulAt ?? .distantPast) < ($1.lastSuccessfulAt ?? .distantPast) }) else {
                missing.append(requirement)
                continue
            }
            statuses.append(record.status)
            if record.status != .complete {
                missing.append(requirement)
            }
            if let success = record.lastSuccessfulAt, success > (latestSuccess ?? .distantPast) {
                latestSuccess = success
            }
        }

        let status: FreshnessStatus
        if statuses.contains(.requiresSSO) {
            status = .ssoRequired
        } else if statuses.contains(.requiresApproval) {
            status = .approvalRequired
        } else if missing.isEmpty {
            status = .fresh
        } else {
            status = .partial
        }
        return CoverageEvaluation(
            freshness: FreshnessState(
                status: status,
                lastSuccessfulSyncAt: latestSuccess,
                detail: missing.isEmpty ? nil : "\(missing.count) coverage requirement(s) incomplete."
            ),
            missing: missing
        )
    }
}
