import Foundation

/// The normalized state is deliberately smaller than GitHub's raw check
/// payload. It contains no log, annotation, target URL, actor, or workflow
/// metadata; the deterministic rules need only current requiredness and the
/// terminal state for one exact pull request.
enum GitHubPullRequestStatusCheckState: String, Codable, Sendable {
    case success
    case failure
    case pending
}

struct GitHubPullRequestStatusCheckRecord: Equatable, Sendable {
    let sourceNodeID: GitHubNodeID
    let context: String
    let state: GitHubPullRequestStatusCheckState
    let isRequired: Bool
    let completedAt: Date?
}

struct GitHubPullRequestStatusCheckRawPage: Equatable, Sendable {
    let requestKey: String
    let payload: Data
}

struct GitHubPullRequestStatusCheckInventory: Sendable {
    let pullRequestNodeID: GitHubNodeID
    let mergeableState: String
    let checks: [GitHubPullRequestStatusCheckRecord]
    let rawPages: [GitHubPullRequestStatusCheckRawPage]
}

enum GitHubPullRequestStatusCheckClientError: Error, Equatable, Sendable {
    case missingPullRequest
    case missingRollup
    case partialResponse
    case missingData
    case undecodableResponse
    case requestFailed
    case transportFailure
    case queryCostExceeded
    case responseByteBudgetExceeded
    case paginationLoop
    case paginationLimitExceeded
    case incompleteConnection
    case invalidContext
    case duplicateContext
}

/// Read-only, pull-request-scoped status-check traversal. Its GraphQL query
/// asks GitHub whether each context is required for the requested PR, which is
/// stricter than matching a branch rule or a check name locally.
actor GitHubPullRequestStatusCheckClient {
    private static let maximumPages = 100
    private static let maximumContextsPerPage = 50
    private static let maximumQueryCost = 500
    private static let maximumResponseBytes = 4 * 1_024 * 1_024

    private let client: GitHubGraphQLClient

    init(client: GitHubGraphQLClient) {
        self.client = client
    }

    func allStatusChecks(
        pullRequestNodeID: GitHubNodeID
    ) async throws -> GitHubPullRequestStatusCheckInventory {
        let query = try GitHubGraphQLQueries.pullRequestStatusChecks()
        var after: String?
        var visitedCursors = Set<String>()
        var rawPages = [GitHubPullRequestStatusCheckRawPage]()
        var checks = [GitHubPullRequestStatusCheckRecord]()
        var seenSourceNodeIDs = Set<GitHubNodeID>()
        var totalCost = 0
        var totalResponseBytes = 0
        var mergeableState: String?

        for pageOrdinal in 1...Self.maximumPages {
            try Task.checkCancellation()
            let requestKey = Self.requestKey(pullRequestNodeID: pullRequestNodeID, after: after)
            let result: GitHubGraphQLDecodingResult<GitHubPullRequestStatusCheckPayload>
            do {
                result = try await client.executePreservingUndecodableResponse(
                    query,
                    variables: CursorVariables(pullRequestID: pullRequestNodeID.rawValue, after: after),
                    as: GitHubPullRequestStatusCheckPayload.self
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch GitHubGraphQLError.requestFailed {
                throw GitHubPullRequestStatusCheckClientError.requestFailed
            } catch {
                throw GitHubPullRequestStatusCheckClientError.transportFailure
            }

            let response: GitHubGraphQLResponse<GitHubPullRequestStatusCheckPayload>
            switch result {
            case let .response(value):
                response = value
            case .undecodable:
                throw GitHubPullRequestStatusCheckClientError.undecodableResponse
            }
            rawPages.append(.init(requestKey: requestKey, payload: response.payload))
            guard response.metadata.ssoHeader == nil else {
                throw GitHubPullRequestStatusCheckClientError.requestFailed
            }
            guard response.errors.isEmpty else {
                throw GitHubPullRequestStatusCheckClientError.partialResponse
            }
            guard let payload = response.data else {
                throw GitHubPullRequestStatusCheckClientError.missingData
            }
            totalCost += payload.rateLimit.cost
            totalResponseBytes += response.payload.count
            guard payload.rateLimit.cost >= 0, totalCost <= Self.maximumQueryCost else {
                throw GitHubPullRequestStatusCheckClientError.queryCostExceeded
            }
            guard totalResponseBytes <= Self.maximumResponseBytes else {
                throw GitHubPullRequestStatusCheckClientError.responseByteBudgetExceeded
            }
            guard let pullRequest = payload.node, pullRequest.id == pullRequestNodeID.rawValue else {
                throw GitHubPullRequestStatusCheckClientError.missingPullRequest
            }
            guard let rollup = pullRequest.statusCheckRollup else {
                throw GitHubPullRequestStatusCheckClientError.missingRollup
            }
            guard pullRequest.mergeable == "MERGEABLE" || pullRequest.mergeable == "CONFLICTING" || pullRequest.mergeable == "UNKNOWN" else {
                throw GitHubPullRequestStatusCheckClientError.missingPullRequest
            }
            if let mergeableState, mergeableState != pullRequest.mergeable {
                throw GitHubPullRequestStatusCheckClientError.incompleteConnection
            }
            mergeableState = pullRequest.mergeable

            let pageContexts = rollup.contexts.nodes
            guard pageContexts.count <= Self.maximumContextsPerPage else {
                throw GitHubPullRequestStatusCheckClientError.incompleteConnection
            }
            let pageRecords = try pageContexts.map(Self.normalize)
            guard Set(pageRecords.map(\.sourceNodeID)).count == pageRecords.count,
                  seenSourceNodeIDs.isDisjoint(with: Set(pageRecords.map(\.sourceNodeID)))
            else {
                throw GitHubPullRequestStatusCheckClientError.duplicateContext
            }
            seenSourceNodeIDs.formUnion(pageRecords.map(\.sourceNodeID))
            checks.append(contentsOf: pageRecords)

            guard rollup.contexts.pageInfo.hasNextPage else {
                return GitHubPullRequestStatusCheckInventory(
                    pullRequestNodeID: pullRequestNodeID,
                    mergeableState: pullRequest.mergeable,
                    checks: checks.sorted { $0.context < $1.context },
                    rawPages: rawPages
                )
            }
            guard let next = rollup.contexts.pageInfo.endCursor,
                  !next.isEmpty,
                  visitedCursors.insert(next).inserted
            else {
                throw GitHubPullRequestStatusCheckClientError.paginationLoop
            }
            after = next
            if pageOrdinal == Self.maximumPages {
                throw GitHubPullRequestStatusCheckClientError.paginationLimitExceeded
            }
        }
        throw GitHubPullRequestStatusCheckClientError.paginationLimitExceeded
    }

    private nonisolated static func normalize(
        _ context: GitHubPullRequestStatusCheckPayload.Context
    ) throws -> GitHubPullRequestStatusCheckRecord {
        guard let sourceNodeID = GitHubNodeID(rawValue: context.id),
              !context.name.isEmpty,
              context.name.count <= 500
        else {
            throw GitHubPullRequestStatusCheckClientError.invalidContext
        }
        let state: GitHubPullRequestStatusCheckState
        switch context.typeName {
        case "CheckRun":
            switch context.conclusion ?? context.status {
            case "SUCCESS", "NEUTRAL", "SKIPPED": state = .success
            case "ACTION_REQUIRED", "CANCELLED", "FAILURE", "STALE", "STARTUP_FAILURE", "TIMED_OUT": state = .failure
            case "COMPLETED", "IN_PROGRESS", "PENDING", "QUEUED", "REQUESTED", "WAITING", nil: state = .pending
            default: throw GitHubPullRequestStatusCheckClientError.invalidContext
            }
        case "StatusContext":
            switch context.status {
            case "SUCCESS": state = .success
            case "ERROR", "FAILURE": state = .failure
            case "EXPECTED", "PENDING": state = .pending
            default: throw GitHubPullRequestStatusCheckClientError.invalidContext
            }
        default:
            throw GitHubPullRequestStatusCheckClientError.invalidContext
        }
        return .init(
            sourceNodeID: sourceNodeID,
            // GitHub permits whitespace in a display name. The durable primary
            // key is instead the immutable GraphQL node identity, so an
            // arbitrary display string cannot collide with an EvidenceID.
            context: "\(context.typeName):\(sourceNodeID.rawValue)",
            state: state,
            isRequired: context.isRequired,
            completedAt: context.completedAt
        )
    }

    private nonisolated static func requestKey(pullRequestNodeID: GitHubNodeID, after: String?) -> String {
        let cursor = after.map { Data($0.utf8).base64EncodedString() } ?? "none"
        return "graphql:TriagePullRequestStatusChecks/pull-request=\(pullRequestNodeID.rawValue)/after=\(cursor)"
    }

    private struct CursorVariables: Encodable, Sendable {
        let pullRequestID: String
        let after: String?
    }
}

struct GitHubPullRequestStatusCheckPayload: Decodable, Sendable {
    let node: PullRequest?
    let rateLimit: RateLimit

    struct PullRequest: Decodable, Sendable {
        let id: String
        let mergeable: String
        let statusCheckRollup: Rollup?
    }

    struct Rollup: Decodable, Sendable {
        let contexts: Connection
    }

    struct Connection: Decodable, Sendable {
        let nodes: [Context]
        let pageInfo: PageInfo
    }

    struct Context: Decodable, Sendable {
        let typeName: String
        let id: String
        let name: String
        let status: String?
        let conclusion: String?
        let completedAt: Date?
        let isRequired: Bool

        enum CodingKeys: String, CodingKey {
            case typeName = "__typename"
            case id, name, status, conclusion, completedAt, isRequired
            case context, state, updatedAt
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            typeName = try values.decode(String.self, forKey: .typeName)
            id = try values.decode(String.self, forKey: .id)
            isRequired = try values.decode(Bool.self, forKey: .isRequired)
            switch typeName {
            case "CheckRun":
                name = try values.decode(String.self, forKey: .name)
                status = try values.decodeIfPresent(String.self, forKey: .status)
                conclusion = try values.decodeIfPresent(String.self, forKey: .conclusion)
                completedAt = try values.decodeIfPresent(Date.self, forKey: .completedAt)
            case "StatusContext":
                name = try values.decode(String.self, forKey: .context)
                status = try values.decodeIfPresent(String.self, forKey: .state)
                conclusion = nil
                completedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt)
            default:
                name = ""
                status = nil
                conclusion = nil
                completedAt = nil
            }
        }
    }

    struct PageInfo: Decodable, Sendable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct RateLimit: Decodable, Sendable {
        let cost: Int
        let remaining: Int
        let resetAt: Date
    }
}
