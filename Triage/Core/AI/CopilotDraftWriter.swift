import Foundation

/// Drafts replies the user reviews, edits, and posts themselves. Triage never
/// posts to GitHub. Uses its own helper connection so a draft never waits
/// behind a triage batch.
actor CopilotDraftWriter {
    static let requestTimeout: TimeInterval = 100

    private let authorize: @Sendable (WorkspaceScope) async throws -> CopilotTriageAuthorization
    private let now: @Sendable () -> Date
    private let session: CopilotHelperSession

    init(
        makeHelper: @escaping @Sendable () -> any TriageCopilotHelping = CopilotHelperSession.production,
        authorize: @escaping @Sendable (WorkspaceScope) async throws -> CopilotTriageAuthorization,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        session = CopilotHelperSession(makeHelper: makeHelper)
        self.authorize = authorize
        self.now = now
    }

    /// A reply for `item` that accomplishes `goal`, in the user's `writingStyle`.
    func draft(_ item: PersonalWorkItem, goal: String?, writingStyle: String?, scope: WorkspaceScope) async throws -> String {
        let authorization = try await CopilotTriageAuthorization.require(authorize, scope: scope)
        let wireItem = CopilotTriageDecider.item(item)
        let goal = goal.map { String($0.utf8.prefix(CopilotDraftRequest.maximumGoalBytes)) ?? "" }
        let style = writingStyle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = self.now
        return try await session.run(scope: scope) { helper in
            try await helper.draft(CopilotDraftRequest(
                accountID: scope.accountID,
                organizationID: scope.organizationID,
                viewerLogin: scope.viewerLogin,
                item: wireItem,
                modelID: authorization.reply.modelID,
                deadline: now().addingTimeInterval(Self.requestTimeout),
                goal: goal,
                writingStyle: style?.isEmpty == false ? style : nil,
                reasoningEffort: authorization.reply.reasoningEffort,
                contextTier: authorization.reply.contextTier
            ))
        }.draft
    }
}
