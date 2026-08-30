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
    let replyCoverage: CoverageStatus
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
            ?? Date(timeIntervalSince1970: 0)
        do {
            try Task.checkCancellation()
            let inventory = try await client.allDiscussions(repositoryNodeID: repositoryNodeID)
            try Task.checkCancellation()
            let result = recordCoverage(.complete, detail: nil)
            let comments = unavailableCoverage(
                feature: .discussionComments,
                component: "discussion-comments",
                detail: "Discussion comments are unavailable until their independently paginated source is implemented."
            )
            let replies = unavailableCoverage(
                feature: .discussionReplies,
                component: "discussion-replies",
                detail: "Discussion replies are unavailable until their independently paginated source is implemented."
            )
            try await repository.replace(
                inventory.discussions,
                rawPages: inventory.rawPages,
                accountID: scope.accountID,
                organization: organization,
                repositoryID: repositoryID,
                observedAt: observedAt,
                coverageRecords: [result, comments, replies]
            )
            return .init(
                discussions: inventory.discussions,
                coverage: result,
                commentCoverage: comments.status,
                replyCoverage: replies.status
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = recordCoverage(status(for: error), detail: diagnostic(for: error))
            try await repository.recordFailure(
                pages: discussionRawPages(for: error),
                accountID: scope.accountID,
                observedAt: observedAt,
                diagnostic: diagnostic(for: error),
                coverageRecord: failure
            )
            throw mapped(error)
        }

        func unavailableCoverage(
            feature: CoverageFeature,
            component: String,
            detail: String
        ) -> CoverageRecord {
            CoverageRecord(
                accountID: scope.accountID,
                organizationID: scope.organizationID,
                repositoryID: repositoryID,
                feature: feature,
                streamID: SyncStreamID(
                    rawValue: "\(component)-\(scope.organizationID.rawValue)-\(repositoryID.rawValue)"
                )!,
                intervalStart: intervalStart,
                intervalEnd: observedAt,
                credentialRevision: scope.credentialRevision,
                capabilityRevision: scope.capabilityRevision,
                status: .unavailable,
                lastSuccessfulAt: nil,
                failureDetail: detail
            )
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
            ?? Date(timeIntervalSince1970: 0)
        do {
            try Task.checkCancellation()
            let inventory = try await client.allProjects(organizationNodeID: organization.nodeID)
            try Task.checkCancellation()
            let projectCoverage = makeCoverage(feature: .projects, streamID: streamID, repositoryID: nil, status: .complete,
                                               detail: nil, success: observedAt)
            try await repository.replaceProjects(
                inventory.projects,
                rawPages: inventory.rawPages,
                accountID: scope.accountID,
                organization: organization,
                observedAt: observedAt,
                coverageRecords: [projectCoverage]
            )
            return .init(projects: inventory.projects, projectCoverage: projectCoverage, itemCoverages: [:])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failed = makeCoverage(feature: .projects, streamID: streamID, repositoryID: nil, status: status(for: error),
                                      detail: diagnostic(for: error), success: nil)
            try await repository.recordFailure(
                pages: projectRawPages(for: error), accountID: scope.accountID,
                observedAt: observedAt, diagnostic: diagnostic(for: error), coverageRecord: failed
            )
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
            ?? Date(timeIntervalSince1970: 0)
        do {
            try Task.checkCancellation()
            let inventory = try await client.allItems(projectNodeID: project.nodeID)
            try Task.checkCancellation()
            let status: CoverageStatus = inventory.items.contains(where: { !$0.fieldValuesComplete }) ? .partial : .complete
            let result = coverageRecord(status: status, detail: status == .partial ? "one or more field unions were incomplete" : nil,
                                        success: status == .complete ? observedAt : nil)
            try await repository.replaceItems(
                inventory.items,
                project: project,
                rawPages: inventory.rawPages,
                accountID: scope.accountID,
                organization: organization,
                observedAt: observedAt,
                coverageRecords: [result]
            )
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failed = coverageRecord(status: status(for: error), detail: diagnostic(for: error), success: nil)
            try await repository.recordFailure(
                pages: projectRawPages(for: error), accountID: scope.accountID,
                observedAt: observedAt, diagnostic: diagnostic(for: error), coverageRecord: failed
            )
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

private func discussionRawPages(for error: Error) -> [GitHubDiscussionRawPage] {
    switch error {
    case let GitHubDiscussionClientError.paginationLoop(pages),
         let GitHubDiscussionClientError.paginationLimitExceeded(pages),
         let GitHubDiscussionClientError.queryCostExceeded(pages),
         let GitHubDiscussionClientError.missingRequestedRepository(pages),
         let GitHubDiscussionClientError.incompleteConnection(pages),
         let GitHubDiscussionClientError.missingData(pages),
         let GitHubDiscussionClientError.undecodableResponse(pages),
         let GitHubDiscussionClientError.partialResponse(pages),
         let GitHubDiscussionClientError.normalizationFailed(pages),
         let GitHubDiscussionClientError.aggregateLimitExceeded(pages): pages
    default: []
    }
}

private func projectRawPages(for error: Error) -> [GitHubProjectV2RawPage] {
    switch error {
    case let GitHubProjectV2ClientError.paginationLoop(pages),
         let GitHubProjectV2ClientError.paginationLimitExceeded(pages),
         let GitHubProjectV2ClientError.queryCostExceeded(pages),
         let GitHubProjectV2ClientError.missingRequestedNode(pages),
         let GitHubProjectV2ClientError.incompleteConnection(pages),
         let GitHubProjectV2ClientError.missingData(pages),
         let GitHubProjectV2ClientError.undecodableResponse(pages),
         let GitHubProjectV2ClientError.partialResponse(pages),
         let GitHubProjectV2ClientError.normalizationFailed(pages),
         let GitHubProjectV2ClientError.duplicateItem(pages),
         let GitHubProjectV2ClientError.aggregateLimitExceeded(pages): pages
    default: []
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
    guard case let GitHubGraphQLError.requestFailed(failure) = error else {
        return "GitHub discussion or project synchronization did not complete."
    }
    if failure.ssoHeader != nil {
        return "GitHub organization SSO authorization is required for this resource."
    }
    if failure.accessRestriction != nil {
        return "GitHub organization approval is required for this resource."
    }
    switch failure.kind {
    case .unauthorized:
        return "Reconnect the selected account to continue synchronization."
    case .rateLimited, .secondaryRateLimited:
        return "GitHub rate limiting left this resource incomplete."
    case .forbidden, .notFound:
        return "This resource is unavailable to the selected account."
    case .serverFailure, .unexpectedResponse:
        return "GitHub did not complete the resource request."
    }
}
