import Foundation
import OSLog

/// One authenticated Copilot helper connection, reused across requests.
/// Authenticates once per scope, re-authenticates once if the helper's
/// session ended, and maps transport failures to `TriageDecisionError`.
/// Each connection runs one request at a time, so independent features
/// (triage batches, drafts) own separate sessions.
actor CopilotHelperSession {
    private static let logger = Logger(subsystem: "com.triage.mac", category: "Copilot")
    private let makeHelper: @Sendable () -> any TriageCopilotHelping
    private var helper: (any TriageCopilotHelping)?
    private var authenticatedScope: WorkspaceScope?

    init(makeHelper: @escaping @Sendable () -> any TriageCopilotHelping) {
        self.makeHelper = makeHelper
    }

    static let production: @Sendable () -> any TriageCopilotHelping = {
        CopilotHelperClient(transport: CopilotXPCFrameTransport(service: CopilotXPCServiceClient()))
    }

    func run<Response: Sendable>(
        scope: WorkspaceScope,
        _ request: @Sendable (any TriageCopilotHelping) async throws -> Response
    ) async throws -> Response {
        do {
            return try await attempt(scope: scope, request)
        } catch CopilotXPCError.helperUnavailable, CopilotXPCError.processExited {
            // The connection dropped (the service restarted, the app was
            // updated, the Mac slept). Reconnect once before reporting it.
            Self.logger.notice("Copilot helper connection lost; reconnecting")
            reset()
            do {
                return try await attempt(scope: scope, request)
            } catch let error as CopilotXPCError {
                throw map(error)
            }
        } catch let error as CopilotXPCError {
            throw map(error)
        }
    }

    private func attempt<Response: Sendable>(
        scope: WorkspaceScope,
        _ request: @Sendable (any TriageCopilotHelping) async throws -> Response
    ) async throws -> Response {
        let helper = self.helper ?? makeHelper()
        self.helper = helper
        do {
            if authenticatedScope != scope {
                try await authenticate(helper, scope: scope)
            }
            do {
                return try await request(helper)
            } catch CopilotXPCError.runtimeUnavailable {
                // The session ended (idle expiry, sign-in elsewhere). Re-establish once.
                Self.logger.notice("Copilot session missing; re-authenticating")
                authenticatedScope = nil
                try await authenticate(helper, scope: scope)
                return try await request(helper)
            }
        } catch let error as TriageDecisionError {
            throw error
        } catch let error as CopilotXPCError {
            Self.logger.error("Copilot request failed xpcError=\(String(describing: error), privacy: .public)")
            reset()
            throw error
        } catch {
            Self.logger.error("Copilot request failed errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            reset()
            throw TriageDecisionError.runtimeUnavailable
        }
    }

    private func map(_ error: CopilotXPCError) -> TriageDecisionError {
        switch error {
        case .operationTimedOut: .timedOut
        case .runtimeUnavailable, .helperUnavailable, .processExited: .runtimeUnavailable
        case .callerRejected: .appReplacedWhileRunning
        default: .invalidResponse
        }
    }

    private func reset() {
        authenticatedScope = nil
        helper = nil
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
}
