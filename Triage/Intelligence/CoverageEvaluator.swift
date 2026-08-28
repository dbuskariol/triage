import Foundation

struct CoverageRequirement: Sendable {
    let feature: CoverageFeature
    let repositoryID: RepositoryID?
    let streamID: SyncStreamID
    let intervalStart: Date?
    let intervalEnd: Date?

    init(
        feature: CoverageFeature,
        repositoryID: RepositoryID?,
        streamID: SyncStreamID,
        intervalStart: Date? = nil,
        intervalEnd: Date? = nil
    ) {
        self.feature = feature
        self.repositoryID = repositoryID
        self.streamID = streamID
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
    }
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
                    && $0.streamID == requirement.streamID
                    && $0.credentialRevision == credentialRevision
                    && $0.capabilityRevision == capabilityRevision
                    && Self.covers(record: $0, requirement: requirement)
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

    private static func covers(record: CoverageRecord, requirement: CoverageRequirement) -> Bool {
        switch (
            record.intervalStart,
            record.intervalEnd,
            requirement.intervalStart,
            requirement.intervalEnd
        ) {
        case (nil, nil, nil, nil):
            true
        case let (recordStart?, recordEnd?, requirementStart?, requirementEnd?):
            recordStart <= requirementStart && recordEnd >= requirementEnd
        default:
            false
        }
    }
}
