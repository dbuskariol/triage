import Foundation

protocol DiscussionCommentFetching: Sendable {
    func allCommentsAndReplies(
        discussionNodeID: GitHubNodeID,
        githubOrganizationID: UInt64,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> GitHubDiscussionCommentInventory
}

extension GitHubDiscussionCommentClient: DiscussionCommentFetching {}

enum DiscussionCommentSynchronizationError: Error, Equatable, Sendable {
    case requiresSSO(GitHubSSOHeader)
    case requiresApproval
}

struct DiscussionCommentSynchronizationResult: Sendable {
    let comments: [DiscussionCommentRecord]
    let replies: [DiscussionCommentRecord]
    let commentCoverage: CoverageRecord
    let replyCoverage: CoverageRecord
}

actor DiscussionCommentSynchronizationService {
    private static let overlap: TimeInterval = 5 * 60
    private let client: any DiscussionCommentFetching
    private let repository: DiscussionCommentRepository

    init(client: any DiscussionCommentFetching, repository: DiscussionCommentRepository) {
        self.client = client; self.repository = repository
    }

    func refresh(
        discussionNodeID: GitHubNodeID, scope: SynchronizationScope, organization: GitHubOrganization,
        repositoryID: RepositoryID, commentStreamID: SyncStreamID, replyStreamID: SyncStreamID,
        previousCommentHighWater: Date?,
        previousReplyHighWater: Date?,
        observedAt: Date = .now
    ) async throws -> DiscussionCommentSynchronizationResult {
        let commentStart = intervalStart(previousCommentHighWater)
        let replyStart = intervalStart(previousReplyHighWater)
        let completeComment = coverage(.discussionComments, commentStreamID, commentStart, .complete, nil, observedAt)
        let completeReply = coverage(.discussionReplies, replyStreamID, replyStart, .complete, nil, observedAt)
        do {
            try Task.checkCancellation(); try await validate(scope)
            let inventory = try await client.allCommentsAndReplies(discussionNodeID: discussionNodeID, githubOrganizationID: organization.githubOrganizationID, validateScope: { [repository] in try await repository.validateCurrentScope(scope) })
            try Task.checkCancellation(); try await validate(scope)
            try await repository.replace(inventory, scope: scope, accountID: scope.accountID, organization: organization, repositoryID: repositoryID, discussionNodeID: discussionNodeID, commentStreamID: commentStreamID, replyStreamID: replyStreamID, observedAt: observedAt, coverageRecords: [completeComment, completeReply])
            try await validate(scope)
            return .init(comments: inventory.comments, replies: inventory.replies, commentCoverage: completeComment, replyCoverage: completeReply)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch DiscussionCommentRepositoryError.staleSynchronizationScope, DiscussionCommentRepositoryError.discussionScopeMismatch { throw CancellationError() }
        catch {
            let source = Self.source(of: error)
            let status = Self.status(for: error, githubOrganizationID: organization.githubOrganizationID)
            let failure = coverage(
                source.coverageFeature,
                source == .comments ? commentStreamID : replyStreamID,
                source == .comments ? commentStart : replyStart,
                status,
                Self.diagnostic(for: error, githubOrganizationID: organization.githubOrganizationID),
                nil
            )
            do {
                try await repository.recordFailure(pages: Self.pages(for: error), scope: scope, accountID: scope.accountID, organization: organization, repositoryID: repositoryID, discussionNodeID: discussionNodeID, commentStreamID: commentStreamID, replyStreamID: replyStreamID, observedAt: observedAt, diagnostic: failure.failureDetail ?? "Discussion source did not complete.", coverageRecords: [failure])
                try await validate(scope)
            } catch DiscussionCommentRepositoryError.staleSynchronizationScope, DiscussionCommentRepositoryError.discussionScopeMismatch { throw CancellationError() }
            throw Self.mapped(error, githubOrganizationID: organization.githubOrganizationID)
        }

        func intervalStart(_ previousHighWater: Date?) -> Date {
            previousHighWater.map { max($0.addingTimeInterval(-Self.overlap), Date(timeIntervalSince1970: 0)) }
                ?? Date(timeIntervalSince1970: 0)
        }

        func coverage(_ feature: CoverageFeature, _ streamID: SyncStreamID, _ start: Date, _ status: CoverageStatus, _ detail: String?, _ success: Date?) -> CoverageRecord {
            .init(accountID: scope.accountID, organizationID: scope.organizationID, repositoryID: repositoryID, feature: feature, streamID: streamID, intervalStart: start, intervalEnd: observedAt, credentialRevision: scope.credentialRevision, capabilityRevision: scope.capabilityRevision, status: status, lastSuccessfulAt: success, failureDetail: detail)
        }
    }

    private func validate(_ scope: SynchronizationScope) async throws {
        do { try await repository.validateCurrentScope(scope) }
        catch DiscussionCommentRepositoryError.staleSynchronizationScope, DiscussionCommentRepositoryError.discussionScopeMismatch { throw CancellationError() }
    }

    private nonisolated static func source(of error: Error) -> GitHubDiscussionCommentSource {
        switch error {
        case let GitHubDiscussionCommentClientError.requestFailed(source, _, _), let GitHubDiscussionCommentClientError.paginationLoop(source, _), let GitHubDiscussionCommentClientError.paginationLimitExceeded(source, _), let GitHubDiscussionCommentClientError.queryCostExceeded(source, _), let GitHubDiscussionCommentClientError.aggregateLimitExceeded(source, _), let GitHubDiscussionCommentClientError.missingRequestedNode(source, _), let GitHubDiscussionCommentClientError.incompleteConnection(source, _), let GitHubDiscussionCommentClientError.undecodableResponse(source, _), let GitHubDiscussionCommentClientError.partialResponse(source, _), let GitHubDiscussionCommentClientError.ssoResponse(source, _, _), let GitHubDiscussionCommentClientError.normalizationFailed(source, _): source
        default: .comments
        }
    }
    private nonisolated static func pages(for error: Error) -> [GitHubDiscussionCommentRawPage] {
        switch error {
        case let GitHubDiscussionCommentClientError.requestFailed(_, pages, _), let GitHubDiscussionCommentClientError.paginationLoop(_, pages), let GitHubDiscussionCommentClientError.paginationLimitExceeded(_, pages), let GitHubDiscussionCommentClientError.queryCostExceeded(_, pages), let GitHubDiscussionCommentClientError.aggregateLimitExceeded(_, pages), let GitHubDiscussionCommentClientError.missingRequestedNode(_, pages), let GitHubDiscussionCommentClientError.incompleteConnection(_, pages), let GitHubDiscussionCommentClientError.undecodableResponse(_, pages), let GitHubDiscussionCommentClientError.partialResponse(_, pages), let GitHubDiscussionCommentClientError.ssoResponse(_, pages, _), let GitHubDiscussionCommentClientError.normalizationFailed(_, pages): pages
        default: []
        }
    }
    private nonisolated static func status(for error: Error, githubOrganizationID: UInt64) -> CoverageStatus {
        if let header = ssoHeader(from: error) { return switch header { case .authorizationRequired: .requiresSSO; case .partialResults, .malformed: .partial } }
        if case let GitHubDiscussionCommentClientError.requestFailed(_, _, .requestFailed(failure)) = error {
            if failure.accessRestriction != nil { return .requiresApproval }
            switch failure.kind { case .forbidden, .notFound: return .unavailable; case .rateLimited, .secondaryRateLimited: return .partial; case .unauthorized, .serverFailure, .unexpectedResponse: return .failed }
        }
        return .partial
    }
    private nonisolated static func diagnostic(for error: Error, githubOrganizationID: UInt64) -> String {
        if let header = ssoHeader(from: error) { return switch header { case .authorizationRequired: "GitHub organization SSO authorization is required for this Discussion source."; case .partialResults, .malformed: "GitHub returned partial Discussion source results." } }
        if case let GitHubDiscussionCommentClientError.requestFailed(_, _, .requestFailed(failure)) = error, failure.accessRestriction != nil { return "GitHub organization approval is required for this Discussion source." }
        return "Discussion source did not return a complete authoritative page traversal."
    }
    private nonisolated static func ssoHeader(from error: Error) -> GitHubSSOHeader? {
        if case let GitHubDiscussionCommentClientError.ssoResponse(_, _, header) = error { return header }
        if case let GitHubDiscussionCommentClientError.requestFailed(_, _, .requestFailed(failure)) = error { return failure.ssoHeader }
        return nil
    }
    private nonisolated static func mapped(_ error: Error, githubOrganizationID: UInt64) -> Error {
        if let header = ssoHeader(from: error), case .authorizationRequired = header { return DiscussionCommentSynchronizationError.requiresSSO(header) }
        if case let GitHubDiscussionCommentClientError.requestFailed(_, _, .requestFailed(failure)) = error, failure.accessRestriction != nil { return DiscussionCommentSynchronizationError.requiresApproval }
        return error
    }
}
