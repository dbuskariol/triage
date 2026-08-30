import Foundation

enum DiscussionProjectV2SynchronizationError: Error, Equatable, Sendable {
    case requiresSSO(GitHubSSOHeader)
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
            try await validateCurrentScope(scope)
            let inventory = try await client.allDiscussions(
                repositoryNodeID: repositoryNodeID,
                githubOrganizationID: organization.githubOrganizationID,
                validateScope: { [repository] in try await repository.validateCurrentScope(scope) }
            )
            try Task.checkCancellation()
            try await validateCurrentScope(scope)
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
                scope: scope,
                accountID: scope.accountID,
                organization: organization,
                repositoryID: repositoryID,
                repositoryNodeID: repositoryNodeID,
                streamID: streamID,
                observedAt: observedAt,
                coverageRecords: [result, comments, replies]
            )
            try await validateCurrentScope(scope)
            return .init(
                discussions: inventory.discussions,
                coverage: result,
                commentCoverage: comments.status,
                replyCoverage: replies.status
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch DiscussionRepositoryError.staleSynchronizationScope,
                DiscussionRepositoryError.organizationScopeMismatch {
            throw CancellationError()
        } catch {
            let failure = recordCoverage(
                status(for: error, githubOrganizationID: organization.githubOrganizationID),
                detail: diagnostic(for: error, githubOrganizationID: organization.githubOrganizationID)
            )
            do {
                try await repository.recordFailure(
                    pages: discussionRawPages(for: error), scope: scope, accountID: scope.accountID,
                    organization: organization, repositoryID: repositoryID, repositoryNodeID: repositoryNodeID,
                    streamID: streamID, observedAt: observedAt,
                    diagnostic: diagnostic(for: error, githubOrganizationID: organization.githubOrganizationID),
                    coverageRecord: failure
                )
                try await validateCurrentScope(scope)
            } catch DiscussionRepositoryError.staleSynchronizationScope,
                    DiscussionRepositoryError.organizationScopeMismatch {
                throw CancellationError()
            }
            throw mapped(error, githubOrganizationID: organization.githubOrganizationID)
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

    private func validateCurrentScope(_ scope: SynchronizationScope) async throws {
        do {
            try await repository.validateCurrentScope(scope)
        } catch DiscussionRepositoryError.staleSynchronizationScope,
                DiscussionRepositoryError.organizationScopeMismatch {
            throw CancellationError()
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
            try await validateCurrentScope(scope)
            let inventory = try await client.allProjects(
                organizationNodeID: organization.nodeID,
                githubOrganizationID: organization.githubOrganizationID,
                validateScope: { [repository] in try await repository.validateCurrentScope(scope) }
            )
            try Task.checkCancellation()
            try await validateCurrentScope(scope)
            let projectCoverage = makeCoverage(feature: .projects, streamID: streamID, repositoryID: nil, status: .complete,
                                               detail: nil, success: observedAt)
            try await repository.replaceProjects(
                inventory.projects,
                rawPages: inventory.rawPages,
                scope: scope,
                accountID: scope.accountID,
                organization: organization,
                streamID: streamID,
                observedAt: observedAt,
                coverageRecords: [projectCoverage]
            )
            try await validateCurrentScope(scope)
            return .init(projects: inventory.projects, projectCoverage: projectCoverage, itemCoverages: [:])
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch ProjectV2RepositoryError.staleSynchronizationScope,
                ProjectV2RepositoryError.organizationScopeMismatch {
            throw CancellationError()
        } catch {
            let failed = makeCoverage(
                feature: .projects,
                streamID: streamID,
                repositoryID: nil,
                status: status(for: error, githubOrganizationID: organization.githubOrganizationID),
                detail: diagnostic(for: error, githubOrganizationID: organization.githubOrganizationID),
                success: nil
            )
            do {
                try await repository.recordFailure(
                    pages: projectRawPages(for: error), scope: scope, accountID: scope.accountID,
                    organization: organization, feature: .projects, streamID: streamID,
                    sourceNodeID: organization.nodeID, observedAt: observedAt,
                    diagnostic: diagnostic(for: error, githubOrganizationID: organization.githubOrganizationID),
                    coverageRecord: failed
                )
                try await validateCurrentScope(scope)
            } catch ProjectV2RepositoryError.staleSynchronizationScope,
                    ProjectV2RepositoryError.organizationScopeMismatch {
                throw CancellationError()
            }
            throw mapped(error, githubOrganizationID: organization.githubOrganizationID)
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
            try await validateCurrentScope(scope)
            let inventory = try await client.allItems(
                projectNodeID: project.nodeID,
                githubOrganizationID: organization.githubOrganizationID,
                validateScope: { [repository] in try await repository.validateCurrentScope(scope) }
            )
            try Task.checkCancellation()
            try await validateCurrentScope(scope)
            let status: CoverageStatus = inventory.items.contains(where: { !$0.fieldValuesComplete }) ? .partial : .complete
            let result = coverageRecord(status: status, detail: status == .partial ? "one or more field unions were incomplete" : nil,
                                        success: status == .complete ? observedAt : nil)
            try await repository.replaceItems(
                inventory.items,
                project: project,
                rawPages: inventory.rawPages,
                scope: scope,
                accountID: scope.accountID,
                organization: organization,
                streamID: streamID,
                observedAt: observedAt,
                coverageRecords: [result]
            )
            try await validateCurrentScope(scope)
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch ProjectV2RepositoryError.staleSynchronizationScope,
                ProjectV2RepositoryError.organizationScopeMismatch {
            throw CancellationError()
        } catch {
            let failed = coverageRecord(
                status: status(for: error, githubOrganizationID: organization.githubOrganizationID),
                detail: diagnostic(for: error, githubOrganizationID: organization.githubOrganizationID),
                success: nil
            )
            do {
                try await repository.recordFailure(
                    pages: projectRawPages(for: error), scope: scope, accountID: scope.accountID,
                    organization: organization, feature: .projectItems, streamID: streamID,
                    sourceNodeID: project.nodeID, observedAt: observedAt,
                    diagnostic: diagnostic(for: error, githubOrganizationID: organization.githubOrganizationID),
                    coverageRecord: failed
                )
                try await validateCurrentScope(scope)
            } catch ProjectV2RepositoryError.staleSynchronizationScope,
                    ProjectV2RepositoryError.organizationScopeMismatch {
                throw CancellationError()
            }
            throw mapped(error, githubOrganizationID: organization.githubOrganizationID)
        }

        func coverageRecord(status: CoverageStatus, detail: String?, success: Date?) -> CoverageRecord {
            CoverageRecord(accountID: scope.accountID, organizationID: scope.organizationID, repositoryID: nil,
                           feature: .projectItems, streamID: streamID, intervalStart: intervalStart, intervalEnd: observedAt,
                           credentialRevision: scope.credentialRevision, capabilityRevision: scope.capabilityRevision,
                           status: status, lastSuccessfulAt: success, failureDetail: detail)
        }
    }

    private func validateCurrentScope(_ scope: SynchronizationScope) async throws {
        do {
            try await repository.validateCurrentScope(scope)
        } catch ProjectV2RepositoryError.staleSynchronizationScope,
                ProjectV2RepositoryError.organizationScopeMismatch {
            throw CancellationError()
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
         let GitHubDiscussionClientError.ssoResponse(pages, _),
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
         let GitHubProjectV2ClientError.ssoResponse(pages, _),
         let GitHubProjectV2ClientError.normalizationFailed(pages),
         let GitHubProjectV2ClientError.duplicateItem(pages),
         let GitHubProjectV2ClientError.aggregateLimitExceeded(pages): pages
    default: []
    }
}

private func status(for error: Error, githubOrganizationID: UInt64) -> CoverageStatus {
    if let header = sourceSSOHeader(from: error) {
        return switch header {
        case .authorizationRequired: .requiresSSO
        case .partialResults, .malformed: .partial
        }
    }
    guard case let GitHubGraphQLError.requestFailed(failure) = error else { return .partial }
    if let header = failure.ssoHeader?.scoped(to: githubOrganizationID) {
        return switch header {
        case .authorizationRequired: .requiresSSO
        case .partialResults, .malformed: .partial
        }
    }
    if failure.accessRestriction != nil { return .requiresApproval }
    switch failure.kind {
    case .forbidden, .notFound: return .unavailable
    case .rateLimited, .secondaryRateLimited: return .partial
    case .unauthorized, .serverFailure, .unexpectedResponse: return .failed
    }
}

private func mapped(_ error: Error, githubOrganizationID: UInt64) -> Error {
    if let header = sourceSSOHeader(from: error), case .authorizationRequired = header {
        return DiscussionProjectV2SynchronizationError.requiresSSO(header)
    }
    guard case let GitHubGraphQLError.requestFailed(failure) = error else { return error }
    if let ssoHeader = failure.ssoHeader?.scoped(to: githubOrganizationID),
       case .authorizationRequired = ssoHeader {
        return DiscussionProjectV2SynchronizationError.requiresSSO(ssoHeader)
    }
    if failure.accessRestriction != nil { return DiscussionProjectV2SynchronizationError.requiresApproval }
    return error
}

private func diagnostic(for error: Error, githubOrganizationID: UInt64) -> String {
    if let header = sourceSSOHeader(from: error) {
        return switch header {
        case .authorizationRequired:
            "GitHub organization SSO authorization is required for this resource."
        case .partialResults:
            "GitHub reported partial results for this organization; this resource remains incomplete."
        case .malformed:
            "GitHub returned malformed organization SSO metadata; this resource remains incomplete."
        }
    }
    guard case let GitHubGraphQLError.requestFailed(failure) = error else {
        return "GitHub discussion or project synchronization did not complete."
    }
    if let header = failure.ssoHeader?.scoped(to: githubOrganizationID) {
        return switch header {
        case .authorizationRequired:
            "GitHub organization SSO authorization is required for this resource."
        case .partialResults:
            "GitHub reported partial results for this organization; this resource remains incomplete."
        case .malformed:
            "GitHub returned malformed organization SSO metadata; this resource remains incomplete."
        }
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

private func sourceSSOHeader(from error: Error) -> GitHubSSOHeader? {
    switch error {
    case let GitHubDiscussionClientError.ssoResponse(_, header),
         let GitHubProjectV2ClientError.ssoResponse(_, header):
        header
    default:
        nil
    }
}
