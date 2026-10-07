import Foundation
import OSLog

enum TriageDecisionError: Error, LocalizedError, TriageAvailabilityError, Sendable {
    case consentRequired
    case signInRequired
    case runtimeUnavailable
    case invalidResponse
    case timedOut

    var errorDescription: String? {
        switch self {
        case .consentRequired:
            "Enable AI for this organization in Settings to triage your work."
        case .signInRequired:
            "Sign in to Copilot to triage your work."
        case .runtimeUnavailable:
            "Copilot runtime is unavailable. Reconnect Copilot and try again."
        case .invalidResponse:
            "Copilot returned an invalid triage response. No decisions were saved."
        case .timedOut:
            "Copilot triage timed out. Try again shortly."
        }
    }

    var pausesAnalysis: Bool {
        switch self {
        case .consentRequired, .signInRequired, .runtimeUnavailable:
            true
        case .invalidResponse, .timedOut:
            false
        }
    }

    var userMessage: String { errorDescription ?? "Copilot is unavailable." }
}

/// Authorization facts obtained by the production adapter before a request is
/// built. Keeping this boundary injectable makes the decider deterministic.
struct CopilotTriageAuthorization: Sendable {
    let isConsentGranted: Bool
    let selectedModelID: String?

    init(isConsentGranted: Bool, selectedModelID: String?) {
        self.isConsentGranted = isConsentGranted
        self.selectedModelID = selectedModelID
    }
}

actor CopilotTriageDecider: TriageDeciding {
    private static let logger = Logger(subsystem: "com.triage.mac", category: "Copilot")
    nonisolated let maximumBatchSize = 15
    /// A full batch is one model call; allow it to finish rather than retrying it.
    static let requestTimeout: TimeInterval = 120

    private let makeHelper: @Sendable () -> any TriageCopilotHelping
    private let authorize: @Sendable (WorkspaceScope) async throws -> CopilotTriageAuthorization
    private let now: @Sendable () -> Date
    /// The XPC service keeps one authenticated helper session; authenticating
    /// again replaces it. Authenticate once and reuse the session.
    private var authenticatedScope: WorkspaceScope?
    /// One XPC connection owns one helper session; reuse it across batches.
    private var helper: (any TriageCopilotHelping)?

    init(
        makeHelper: @escaping @Sendable () -> any TriageCopilotHelping = {
            CopilotHelperClient(
                transport: CopilotXPCFrameTransport(service: CopilotXPCServiceClient())
            )
        },
        authorize: @escaping @Sendable (WorkspaceScope) async throws -> CopilotTriageAuthorization,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.makeHelper = makeHelper
        self.authorize = authorize
        self.now = now
    }

    init(
        resolveVault: @escaping @Sendable (AccountID) async throws -> AccountVault,
        makeHelper: @escaping @Sendable () -> any TriageCopilotHelping = {
            CopilotHelperClient(
                transport: CopilotXPCFrameTransport(service: CopilotXPCServiceClient())
            )
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.makeHelper = makeHelper
        self.now = now
        self.authorize = { scope in
            let vault = try await resolveVault(scope.accountID)
            let consent = try await AIConsentRepository(vault: vault).consent(
                for: scope.accountID,
                organizationID: scope.organizationID
            )
            return CopilotTriageAuthorization(
                isConsentGranted: consent.isEnabled,
                selectedModelID: consent.selectedModelID
            )
        }
    }

    func decide(
        _ items: [PersonalWorkItem],
        scope: WorkspaceScope,
        rules: TriageRules,
        contexts: [GitHubNodeID: TriageHandledContext] = [:]
    ) async throws -> [TriageDecision] {
        guard (1...maximumBatchSize).contains(items.count) else {
            throw TriageDecisionError.invalidResponse
        }

        let authorization: CopilotTriageAuthorization
        do {
            authorization = try await authorize(scope)
        } catch let error as TriageDecisionError {
            throw error
        } catch {
            throw TriageDecisionError.runtimeUnavailable
        }

        guard authorization.isConsentGranted else {
            throw TriageDecisionError.consentRequired
        }

        let helper = self.helper ?? makeHelper()
        self.helper = helper
        do {
            let wireItems = items.map { Self.item($0, hints: rules.hints(for: $0), context: contexts[$0.id]) }
            let instructions = rules.trimmedInstructions
            let makeRequest = { [now] in
                CopilotTriageRequest(
                    accountID: scope.accountID,
                    organizationID: scope.organizationID,
                    viewerLogin: scope.viewerLogin,
                    items: wireItems,
                    modelID: authorization.selectedModelID,
                    deadline: now().addingTimeInterval(Self.requestTimeout),
                    instructions: instructions
                )
            }
            if authenticatedScope != scope {
                try await authenticate(helper, scope: scope)
            }
            let response: CopilotTriageResponse
            do {
                response = try await helper.triage(makeRequest())
            } catch CopilotXPCError.runtimeUnavailable {
                // The session ended (idle expiry, sign-in elsewhere). Re-establish once.
                Self.logger.notice("triage session missing; re-authenticating")
                authenticatedScope = nil
                try await authenticate(helper, scope: scope)
                response = try await helper.triage(makeRequest())
            }
            let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id.rawValue, $0) })
            if response.decisions.count < items.count {
                Self.logger.notice("triage partial decided=\(response.decisions.count, privacy: .public) requested=\(items.count, privacy: .public)")
            }

            return try response.decisions.map { decision in
                guard let item = itemsByID[decision.id] else {
                    throw TriageDecisionError.invalidResponse
                }
                return TriageDecision(
                    itemID: item.id,
                    disposition: decision.disposition,
                    priority: decision.priority,
                    confidence: decision.confidence,
                    summary: decision.summary,
                    reason: decision.reason,
                    nextAction: decision.nextAction,
                    fingerprint: item.fingerprint,
                    modelID: response.modelID,
                    decidedAt: now(),
                    rulesDigest: rules.digest,
                    instructionNote: decision.instructionNote,
                    // Only meaningful when we asked (the viewer acted since the last decision).
                    handled: contexts[item.id] == nil ? nil : decision.handled,
                    handledEvidence: contexts[item.id] == nil ? nil : decision.handledEvidence
                )
            }
        } catch let error as TriageDecisionError {
            Self.logger.error("triage failed reason=\(String(describing: error), privacy: .public)")
            throw error
        } catch let error as CopilotXPCError {
            Self.logger.error("triage failed xpcError=\(String(describing: error), privacy: .public)")
            authenticatedScope = nil
            self.helper = nil
            switch error {
            case .operationTimedOut:
                throw TriageDecisionError.timedOut
            case .runtimeUnavailable, .helperUnavailable, .processExited:
                throw TriageDecisionError.runtimeUnavailable
            default:
                throw TriageDecisionError.invalidResponse
            }
        } catch {
            Self.logger.error("triage failed errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            authenticatedScope = nil
            self.helper = nil
            throw TriageDecisionError.runtimeUnavailable
        }
    }

    private func authenticate(_ helper: any TriageCopilotHelping, scope: WorkspaceScope) async throws {
        let authentication = try await helper.authenticate(
            .init(accountID: scope.accountID, organizationID: scope.organizationID, allowsBrowser: false)
        ).authentication
        guard authentication.isAuthenticated,
              authentication.login.caseInsensitiveCompare(scope.viewerLogin) == .orderedSame
        else {
            authenticatedScope = nil
            throw TriageDecisionError.signInRequired
        }
        authenticatedScope = scope
        Self.logger.notice("Copilot session authenticated")
    }

    private static func item(
        _ item: PersonalWorkItem, hints: [String], context: TriageHandledContext?
    ) -> CopilotTriageItem {
        CopilotTriageItem(
            id: item.id.rawValue,
            kind: item.kind.rawValue,
            repository: item.repository,
            number: item.number,
            title: item.title,
            state: item.state.rawValue,
            author: item.author,
            updatedAt: item.updatedAt,
            relationships: item.relationships.map(\.rawValue).sorted(),
            labels: item.labels,
            assignees: item.assignees,
            body: item.body,
            pullRequest: item.pullRequest.map { pullRequest in
                CopilotTriagePullRequest(
                    isDraft: pullRequest.isDraft,
                    reviewDecision: pullRequest.reviewDecision?.rawValue,
                    requestedReviewers: pullRequest.requestedReviewers,
                    latestReviews: pullRequest.latestReviews.map { review in
                        CopilotTriageReview(
                            author: review.author,
                            state: review.state,
                            submittedAt: review.submittedAt
                        )
                    },
                    checks: pullRequest.checks?.rawValue,
                    mergeable: pullRequest.mergeable,
                    unresolvedReviewThreads: pullRequest.unresolvedReviewThreads,
                    additions: pullRequest.additions,
                    deletions: pullRequest.deletions
                )
            },
            recentActivity: item.recentActivity.map { activity in
                CopilotTriageActivity(
                    author: activity.author,
                    createdAt: activity.createdAt,
                    excerpt: activity.excerpt
                )
            },
            ruleHints: hints.isEmpty ? nil : hints,
            previousNextAction: context.map { String($0.previousNextAction.prefix(200)) },
            viewerActivity: context.map { Array($0.viewerActivity.prefix(10)) }
        )
    }
}
