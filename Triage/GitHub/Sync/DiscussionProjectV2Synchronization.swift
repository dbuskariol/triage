import Foundation

enum DiscussionProjectV2SynchronizationError: Error, Equatable, Sendable {
    case requiresSSO
    case requiresApproval
}

struct DiscussionSynchronizationResult: Sendable {
    let discussions: [GitHubDiscussionRecord]
    let coverage: CoverageRecord
    /// Discussion comments and replies are deliberately unavailable: their source
    /// connection is not committed by this slice.
    let commentCoverage: CoverageStatus
}

struct ProjectV2SynchronizationResult: Sendable {
    let projects: [GitHubProjectV2Record]
    let projectCoverage: CoverageRecord
    let itemCoverages: [GitHubNodeID: CoverageRecord]
}

actor DiscussionSynchronizationService {
    private static let overlap: TimeInterval = 5 * 60
    private let client: GitHubDiscussionClient
    private let repository: DiscussionRepository
    private let coverage: CoverageRepository

    init(client: GitHubDiscussionClient, repository: DiscussionRepository, coverage: CoverageRepository) {
        self.client = client
        self.repository = repository
        self.coverage = coverage
    }

    func refresh(
        scope: SynchronizationScope,
        organization: GitHubOrganization,
        repositoryID: RepositoryID,
        repositoryNodeID: GitHubNodeID,
        streamID: SyncStreamID,
        previousHighWater: Date?,
        observedAt: Date = .now
    ) async throws -> DiscussionSynchronizationResult {
        let intervalStart = previousHighWater.map { $0.addingTimeInterval(-Self.overlap) }
        do {
            let inventory = try await client.allDiscussions(repositoryNodeID: repositoryNodeID)
            try await repository.replace(inventory.discussions, rawPages: inventory.rawPages, accountID: scope.accountID,
                                         organization: organization, repositoryID: repositoryID, observedAt: observedAt)
            let result = recordCoverage(.complete, detail: nil)
            try await coverage.save(result, attemptedAt: observedAt)
            return .init(discussions: inventory.discussions, coverage: result, commentCoverage: .unavailable)
        } catch {
            if case let GitHubDiscussionClientError.partialResponse(page) = error {
                try? await repository.recordFailedPage(page, accountID: scope.accountID, observedAt: observedAt,
                                                        diagnostic: "partial GraphQL response")
            }
            if case let GitHubDiscussionClientError.normalizationFailed(pages) = error {
                for page in pages {
                    try? await repository.recordFailedPage(page, accountID: scope.accountID, observedAt: observedAt,
                                                            diagnostic: "malformed discussion payload")
                }
            }
            if case let GitHubDiscussionClientError.aggregateLimitExceeded(pages) = error {
                for page in pages {
                    try? await repository.recordFailedPage(page, accountID: scope.accountID, observedAt: observedAt,
                                                            diagnostic: "aggregate GraphQL inventory budget exceeded")
                }
            }
            let failure = recordCoverage(status(for: error), detail: diagnostic(for: error))
            try await coverage.save(failure, attemptedAt: observedAt)
            throw mapped(error)
        }

        func recordCoverage(_ status: CoverageStatus, detail: String?) -> CoverageRecord {
            CoverageRecord(accountID: scope.accountID, organizationID: scope.organizationID, repositoryID: repositoryID,
                           feature: .discussions, streamID: streamID, intervalStart: intervalStart, intervalEnd: observedAt,
                           credentialRevision: scope.credentialRevision, capabilityRevision: scope.capabilityRevision,
                           status: status, lastSuccessfulAt: status == .complete ? observedAt : nil, failureDetail: detail)
        }
    }
}

actor ProjectV2SynchronizationService {
    private static let overlap: TimeInterval = 5 * 60
    private let client: GitHubProjectV2Client
    private let repository: ProjectV2Repository
    private let coverage: CoverageRepository

    init(client: GitHubProjectV2Client, repository: ProjectV2Repository, coverage: CoverageRepository) {
        self.client = client
        self.repository = repository
        self.coverage = coverage
    }

    func refreshProjects(
        scope: SynchronizationScope, organization: GitHubOrganization, streamID: SyncStreamID,
        previousHighWater: Date?, observedAt: Date = .now
    ) async throws -> ProjectV2SynchronizationResult {
        let intervalStart = previousHighWater.map { $0.addingTimeInterval(-Self.overlap) }
        do {
            let inventory = try await client.allProjects(organizationNodeID: organization.nodeID)
            try await repository.replaceProjects(inventory.projects, rawPages: inventory.rawPages, accountID: scope.accountID,
                                                 organization: organization, observedAt: observedAt)
            let projectCoverage = makeCoverage(feature: .projects, streamID: streamID, repositoryID: nil, status: .complete,
                                               detail: nil, success: observedAt)
            try await coverage.save(projectCoverage, attemptedAt: observedAt)
            return .init(projects: inventory.projects, projectCoverage: projectCoverage, itemCoverages: [:])
        } catch {
            if case let GitHubProjectV2ClientError.partialResponse(page) = error {
                try? await repository.recordFailedPage(page, accountID: scope.accountID, observedAt: observedAt,
                                                        diagnostic: "partial GraphQL response")
            }
            if case let GitHubProjectV2ClientError.normalizationFailed(pages) = error {
                for page in pages {
                    try? await repository.recordFailedPage(page, accountID: scope.accountID, observedAt: observedAt,
                                                            diagnostic: "malformed Project V2 payload")
                }
            }
            if case let GitHubProjectV2ClientError.aggregateLimitExceeded(pages) = error {
                for page in pages {
                    try? await repository.recordFailedPage(page, accountID: scope.accountID, observedAt: observedAt,
                                                            diagnostic: "aggregate GraphQL inventory budget exceeded")
                }
            }
            let failed = makeCoverage(feature: .projects, streamID: streamID, repositoryID: nil, status: status(for: error),
                                      detail: diagnostic(for: error), success: nil)
            try await coverage.save(failed, attemptedAt: observedAt)
            throw mapped(error)
        }

        func makeCoverage(feature: CoverageFeature, streamID: SyncStreamID, repositoryID: RepositoryID?, status: CoverageStatus,
                          detail: String?, success: Date?) -> CoverageRecord {
            CoverageRecord(accountID: scope.accountID, organizationID: scope.organizationID, repositoryID: repositoryID,
                           feature: feature, streamID: streamID, intervalStart: intervalStart, intervalEnd: observedAt,
                           credentialRevision: scope.credentialRevision, capabilityRevision: scope.capabilityRevision,
                           status: status, lastSuccessfulAt: success, failureDetail: detail)
        }
    }

    func refreshItems(
        project: GitHubProjectV2Record, scope: SynchronizationScope, organization: GitHubOrganization,
        streamID: SyncStreamID, previousHighWater: Date?, observedAt: Date = .now
    ) async throws -> CoverageRecord {
        let intervalStart = previousHighWater.map { $0.addingTimeInterval(-Self.overlap) }
        do {
            let inventory = try await client.allItems(projectNodeID: project.nodeID)
            try await repository.replaceItems(inventory.items, project: project, rawPages: inventory.rawPages,
                                              accountID: scope.accountID, organization: organization, observedAt: observedAt)
            let status: CoverageStatus = inventory.items.contains(where: { !$0.fieldValuesComplete }) ? .partial : .complete
            let result = coverageRecord(status: status, detail: status == .partial ? "one or more field unions were incomplete" : nil,
                                        success: status == .complete ? observedAt : nil)
            try await coverage.save(result, attemptedAt: observedAt)
            return result
        } catch {
            if case let GitHubProjectV2ClientError.partialResponse(page) = error {
                try? await repository.recordFailedPage(page, accountID: scope.accountID, observedAt: observedAt,
                                                        diagnostic: "partial GraphQL response")
            }
            if case let GitHubProjectV2ClientError.normalizationFailed(pages) = error {
                for page in pages {
                    try? await repository.recordFailedPage(page, accountID: scope.accountID, observedAt: observedAt,
                                                            diagnostic: "malformed Project V2 payload")
                }
            }
            if case let GitHubProjectV2ClientError.aggregateLimitExceeded(pages) = error {
                for page in pages {
                    try? await repository.recordFailedPage(page, accountID: scope.accountID, observedAt: observedAt,
                                                            diagnostic: "aggregate GraphQL inventory budget exceeded")
                }
            }
            let failed = coverageRecord(status: status(for: error), detail: diagnostic(for: error), success: nil)
            try await coverage.save(failed, attemptedAt: observedAt)
            throw mapped(error)
        }

        func coverageRecord(status: CoverageStatus, detail: String?, success: Date?) -> CoverageRecord {
            CoverageRecord(accountID: scope.accountID, organizationID: scope.organizationID, repositoryID: nil,
                           feature: .projectItems, streamID: streamID, intervalStart: intervalStart, intervalEnd: observedAt,
                           credentialRevision: scope.credentialRevision, capabilityRevision: scope.capabilityRevision,
                           status: status, lastSuccessfulAt: success, failureDetail: detail)
        }
    }
}

private func status(for error: Error) -> CoverageStatus {
    guard case let GitHubGraphQLError.requestFailed(failure) = error else { return .partial }
    if failure.ssoHeader != nil { return .requiresSSO }
    if failure.accessRestriction != nil { return .requiresApproval }
    return .failed
}

private func mapped(_ error: Error) -> Error {
    guard case let GitHubGraphQLError.requestFailed(failure) = error else { return error }
    if failure.ssoHeader != nil { return DiscussionProjectV2SynchronizationError.requiresSSO }
    if failure.accessRestriction != nil { return DiscussionProjectV2SynchronizationError.requiresApproval }
    return error
}

private func diagnostic(for error: Error) -> String {
    String(describing: error).prefix(4_096).description
}
