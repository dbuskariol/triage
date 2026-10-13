#if DEBUG
import CryptoKit
import Foundation

/// The launch gate and per-session storage for the Debug-only XCUITest
/// fixture. Release builds don't contain this type, and a Debug launch enters
/// the fixture only with both the `-triage-ui-fixture` argument and
/// `TRIAGE_UI_TEST_MODE=1`. A fixture process never reads the Keychain, the
/// user's vaults or preferences, GitHub, or the Copilot runtime.
struct TriageUITestFixtureLaunch: Sendable {
    enum Scenario: String, Sendable {
        /// Two accounts and three organizations with seeded work.
        case workspace
        /// `workspace`, with 10,000 items in the first organization.
        case performanceWorkspace = "performance-workspace"
        /// No accounts; the Setup Assistant is shown.
        case onboarding
        /// No accounts; used to inspect GitHub sign-in failure and the token sheet.
        case personalAccessToken = "personal-access-token"
        /// `workspace`, with the primary account connected by a classic token.
        case personalAccessTokenReplacement = "personal-access-token-replacement"
        /// `workspace`, then a notification opens an item in another organization.
        case notificationRoute = "notification-route"
        /// No usable accounts; one account's encrypted data can't be opened.
        case accountRecovery = "account-recovery"
        /// `workspace`, but every GitHub refresh fails, so only saved work is shown.
        case refreshFailure = "refresh-failure"

        var hasAccounts: Bool {
            switch self {
            case .onboarding, .personalAccessToken, .accountRecovery: false
            default: true
            }
        }

        var hasCompletedOnboarding: Bool {
            self != .onboarding && self != .personalAccessToken
        }
    }

    static let argument = "-triage-ui-fixture"

    let scenario: Scenario
    let session: String
    /// An isolated preferences suite for this test session.
    let defaultsSuiteName: String
    let vaultRoot: URL

    /// The fixture for this process, or `nil` for an ordinary launch.
    static let current: TriageUITestFixtureLaunch? = {
        let process = ProcessInfo.processInfo
        guard isRequested(arguments: process.arguments, environment: process.environment) else { return nil }
        do {
            return try TriageUITestFixtureLaunch(environment: process.environment)
        } catch {
            // Never fall back to the production composition once a fixture was requested.
            fatalError("Triage could not create its UI-test fixture: \(error)")
        }
    }()

    static func isRequested(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains(argument) && environment["TRIAGE_UI_TEST_MODE"] == "1"
    }

    init(environment: [String: String]) throws {
        guard let scenario = Scenario(rawValue: environment["TRIAGE_UI_TEST_SCENARIO"] ?? Scenario.workspace.rawValue) else {
            throw FixtureError.unknownScenario
        }
        let session = environment["TRIAGE_UI_TEST_SESSION"] ?? UUID().uuidString.lowercased()
        guard Self.isValidSession(session) else { throw FixtureError.invalidSession }
        let suiteName = "com.triage.mac.ui-fixture.\(session)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw FixtureError.invalidSession }
        let vaultRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TriageUITestFixture", isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
        if environment["TRIAGE_UI_TEST_RESET"] == "1" {
            defaults.removePersistentDomain(forName: suiteName)
            if FileManager.default.fileExists(atPath: vaultRoot.path) {
                try FileManager.default.removeItem(at: vaultRoot)
            }
        }
        try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        defaults.set(scenario.hasCompletedOnboarding, forKey: TriagePreferenceKeys.onboardingCompleted)
        // Defaults that keep the fixture still while a test interacts with it:
        // fixture work is static, so automatic refreshes would only add noise,
        // and a delayed mark-as-read would re-render rows under an open menu.
        defaults.register(defaults: [
            TriagePreferenceKeys.refreshIntervalMinutes: 0,
            TriagePreferenceKeys.markReadPolicy: MarkReadPolicy.manually.rawValue
        ])
        self.scenario = scenario
        self.session = session
        defaultsSuiteName = suiteName
        self.vaultRoot = vaultRoot
    }

    /// Sessions name a preferences suite and a directory, so only simple tokens are accepted.
    private static func isValidSession(_ session: String) -> Bool {
        (1...80).contains(session.count) && session.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
        }
    }

    private enum FixtureError: Error {
        case unknownScenario
        case invalidSession
    }
}

/// Builds the app's dependencies from local fixture data. Each account gets a
/// real encrypted vault under the session's temporary directory, keyed by a
/// key derived from the session, so the production store, engine, consent
/// repository, and live observation all run unchanged against fake data.
struct TriageUITestFixture: Sendable {
    let launch: TriageUITestFixtureLaunch
    private let vaultRegistry: VaultRegistry

    init(launch: TriageUITestFixtureLaunch) throws {
        self.launch = launch
        vaultRegistry = try VaultRegistry(rootDirectory: launch.vaultRoot)
    }

    func dependencies() throws -> TriageApplicationDependencies {
        let scenario = launch.scenario
        let snapshot = try FixtureData.snapshot(for: scenario)
        let vaults = FixtureVaults(registry: vaultRegistry, session: launch.session, snapshot: snapshot)
        let openVault: @Sendable (AccountID) async throws -> AccountVault = { try await vaults.open($0) }
        var dependencies = TriageApplicationDependencies(
            accountSession: FixtureAccountSession(snapshot: snapshot, vaultRegistry: vaultRegistry),
            copilotRuntimeAuthorization: NoopCopilotRuntimeAuthorizationProvider(),
            consent: { scope in
                try await AIConsentRepository(vault: openVault(scope.accountID))
                    .consent(for: scope.accountID, organizationID: scope.organizationID)
            },
            saveConsent: { scope, isEnabled, choice, reply in
                try await AIConsentRepository(vault: openVault(scope.accountID)).save(.init(
                    accountID: scope.accountID,
                    organizationID: scope.organizationID,
                    isEnabled: isEnabled,
                    selectedModelID: choice.modelID,
                    reasoningEffort: choice.reasoningEffort,
                    contextTier: choice.contextTier,
                    replyChoice: reply,
                    updatedAt: .now
                ))
            },
            makeWorkspace: { scope in
                let store = GRDBTriageStore(vault: try await openVault(scope.accountID))
                let items = FixtureData.items(for: scope, scenario: scenario)
                let decider = FixtureTriageDecider()
                // Seed once per session so saved work exists before the first
                // refresh, as it does for a returning user.
                if try await store.lastRefreshAt(scope: scope) == nil, !items.isEmpty {
                    try await store.replaceItems(items, scope: scope, at: FixtureData.date)
                    let rules = try await store.rules(scope: scope)
                    try await store.saveDecisions(
                        try await decider.decide(items, scope: scope, rules: rules, contexts: [:]), scope: scope
                    )
                }
                let discovery = FixtureDiscovery(
                    items: items,
                    failure: scenario == .refreshFailure ? .searchUnavailable : nil
                )
                let engine = TriageEngine(
                    store: store,
                    makeDiscovery: { _ in discovery },
                    decider: decider,
                    refreshInterval: nil,
                    autoMarkHandled: { false }
                )
                return WorkspaceRuntime(store: store, engine: engine)
            }
        )
        dependencies.oauthConfiguration = { throw RuntimeOAuthConfigurationError.missingClientID }
        return dependencies
    }

    /// Runs after accounts are restored, like a notification click arriving at launch.
    @MainActor
    func didRestoreAccounts(_ appModel: TriageAppModel) {
        guard launch.scenario == .notificationRoute else { return }
        // Round-trip through the notification payload, as a real click does.
        let notification = AttentionTarget(.item(FixtureData.betaItemID), organizationID: FixtureData.beta.id)
        guard let target = AttentionTarget(userInfo: notification.userInfo) else { return }
        appModel.open(target)
    }
}

/// Opens each account's fixture vault, first recording the account and its
/// organizations in it exactly as a GitHub connection would.
private actor FixtureVaults {
    private let registry: VaultRegistry
    private let session: String
    private let snapshot: AccountSessionSnapshot
    private var seeded: Set<AccountID> = []

    init(registry: VaultRegistry, session: String, snapshot: AccountSessionSnapshot) {
        self.registry = registry
        self.session = session
        self.snapshot = snapshot
    }

    func open(_ accountID: AccountID) async throws -> AccountVault {
        let vault = try await registry.open(
            accountID: accountID, vaultKey: FixtureData.vaultKey(session: session, accountID: accountID)
        )
        guard !seeded.contains(accountID), let account = snapshot.accounts.first(where: { $0.id == accountID }) else {
            return vault
        }
        let repository = AccountRepository(vault: vault)
        try await repository.save(account, credentialRevision: CredentialRevision(rawValue: "fixture-credential-revision")!)
        for organization in snapshot.organizationsByAccount[accountID] ?? [] {
            try await repository.save(organization, access: OrganizationAccess(
                accountID: accountID,
                organizationID: organization.id,
                state: .available,
                capabilityRevision: CapabilityRevision(rawValue: "fixture-capability-revision")!,
                capabilities: [],
                checkedAt: FixtureData.date
            ))
        }
        seeded.insert(accountID)
        return vault
    }
}

private enum FixtureFailure: Error {
    case unavailableInFixture
}

private actor FixtureAccountSession: AccountSessionServing {
    private var snapshot: AccountSessionSnapshot
    private let vaultRegistry: VaultRegistry

    init(snapshot: AccountSessionSnapshot, vaultRegistry: VaultRegistry) {
        self.snapshot = snapshot
        self.vaultRegistry = vaultRegistry
    }

    func restoreAccounts() async throws -> AccountSessionSnapshot { snapshot }

    func connectOAuth(_: AuthBrokerExchangeRequest) async throws -> AccountSessionSnapshot {
        throw FixtureFailure.unavailableInFixture
    }

    func connectPersonalAccessToken(
        _: PersonalAccessToken, resourceOwnerOrganization _: String?
    ) async throws -> AccountSessionSnapshot {
        throw FixtureFailure.unavailableInFixture
    }

    func replacePersonalAccessToken(
        _: PersonalAccessToken, replacing _: GitHubAccount
    ) async throws -> AccountSessionSnapshot {
        throw FixtureFailure.unavailableInFixture
    }

    func removeAccount(_ accountID: AccountID) async throws {
        try await vaultRegistry.remove(accountID: accountID)
        snapshot = try AccountSessionSnapshot(
            accounts: snapshot.accounts.filter { $0.id != accountID },
            organizationsByAccount: snapshot.organizationsByAccount.filter { $0.key != accountID },
            organizationAccessesByAccount: snapshot.organizationAccessesByAccount.filter { $0.key != accountID },
            accountCapabilitiesByAccount: snapshot.accountCapabilitiesByAccount.filter { $0.key != accountID },
            unavailableAccountIDs: snapshot.unavailableAccountIDs.subtracting([accountID])
        )
    }
}

private struct FixtureDiscovery: PersonalWorkDiscovering {
    let items: [PersonalWorkItem]
    let failure: PersonalWorkDiscoveryError?

    func discover(
        scope _: WorkspaceScope,
        progress: @escaping @Sendable (DiscoveryProgress) async -> Void
    ) async throws -> [PersonalWorkItem] {
        if let failure { throw failure }
        await progress(.init(relationship: .reviewRequested, found: items.count))
        return items
    }
}

/// Deterministic stand-in for Copilot: the same facts always get the same decision.
private struct FixtureTriageDecider: TriageDeciding {
    let maximumBatchSize = 500

    func decide(
        _ items: [PersonalWorkItem], scope _: WorkspaceScope, rules: TriageRules,
        contexts _: [GitHubNodeID: TriageHandledContext]
    ) async throws -> [TriageDecision] {
        items.map { item in
            let isFollowUp = item.relationships.contains(.assigned)
            return TriageDecision(
                itemID: item.id,
                disposition: isFollowUp ? .review : .act,
                priority: isFollowUp ? 55 : 85,
                confidence: 0.9,
                summary: "Fixture summary for \(item.reference).",
                reason: isFollowUp
                    ? "Deterministic fixture decision: worth a look soon."
                    : "Deterministic fixture decision: your review is requested.",
                nextAction: isFollowUp ? nil : "Review the fixture change.",
                fingerprint: item.fingerprint,
                modelID: "fixture",
                decidedAt: FixtureData.date,
                rulesDigest: rules.digest
            )
        }
    }
}

private enum FixtureData {
    static let date = Date(timeIntervalSince1970: 1_767_225_600)
    static let performanceItemCount = 10_000

    static let primary = account("00000000-0000-4000-8000-000000000001", userID: 1, login: "fixture-primary", name: "Fixture Primary")
    static let secondary = account("00000000-0000-4000-8000-000000000002", userID: 2, login: "fixture-secondary", name: "Fixture Secondary")
    static let unavailableAccountID = AccountID(rawValue: "00000000-0000-4000-8000-000000000009")!

    static let acme = organization("fixture-org-acme", databaseID: 101, login: "acme", name: "Fixture Acme")
    static let beta = organization("fixture-org-beta", databaseID: 102, login: "beta-labs", name: "Fixture Beta")
    static let studio = organization("fixture-org-studio", databaseID: 103, login: "studio", name: "Fixture Studio")

    static let betaItemID = GitHubNodeID(rawValue: "fixture-beta-1")!

    static func vaultKey(session: String, accountID: AccountID) throws -> VaultKey {
        try VaultKey(data: Data(SHA256.hash(data: Data("triage-ui-fixture/\(session)/\(accountID.rawValue)".utf8))))
    }

    static func snapshot(for scenario: TriageUITestFixtureLaunch.Scenario) throws -> AccountSessionSnapshot {
        if scenario == .accountRecovery {
            return try AccountSessionSnapshot(
                accounts: [], organizationsByAccount: [:], organizationAccessesByAccount: [:],
                accountCapabilitiesByAccount: [:], unavailableAccountIDs: [unavailableAccountID]
            )
        }
        guard scenario.hasAccounts else {
            return try AccountSessionSnapshot(
                accounts: [], organizationsByAccount: [:], organizationAccessesByAccount: [:], accountCapabilitiesByAccount: [:]
            )
        }
        let primary = scenario == .personalAccessTokenReplacement
            ? account(
                Self.primary.id.rawValue, userID: 1, login: "fixture-primary", name: "Fixture Primary",
                kind: .classicPersonalAccessToken
            )
            : Self.primary
        return try AccountSessionSnapshot(
            accounts: [primary, secondary],
            organizationsByAccount: [primary.id: [acme, beta], secondary.id: [studio]],
            organizationAccessesByAccount: [:],
            accountCapabilitiesByAccount: [:]
        )
    }

    static func items(for scope: WorkspaceScope, scenario: TriageUITestFixtureLaunch.Scenario) -> [PersonalWorkItem] {
        switch scope.organizationID {
        case acme.id:
            if scenario == .performanceWorkspace { return performanceItems() }
            return [
                item(
                    id: "fixture-acme-1", kind: .pullRequest, repository: "acme/widgets", number: 42,
                    title: "Fixture Acme keyboard accessibility smoke", relationships: [.reviewRequested],
                    body: "Adds keyboard shortcuts and VoiceOver labels to the widget list.\n\n- Arrow keys move the selection\n- Return opens the item",
                    pullRequest: PullRequestFacts(
                        isDraft: false, reviewDecision: .reviewRequired, requestedReviewers: [scope.viewerLogin],
                        latestReviews: [ReviewFact(author: "octocat", state: "COMMENTED", submittedAt: date)],
                        checks: .success, mergeable: "MERGEABLE", unresolvedReviewThreads: 1,
                        additions: 120, deletions: 30
                    ),
                    activity: [ActivityFact(author: "octocat", createdAt: date, excerpt: "Could you check the VoiceOver labels?")]
                ),
                item(
                    id: "fixture-acme-2", kind: .issue, repository: "acme/widgets", number: 43,
                    title: "Fixture Acme follow-up issue", relationships: [.assigned],
                    body: "Document the new keyboard shortcuts."
                )
            ]
        case beta.id:
            return [
                item(
                    id: "fixture-beta-2", kind: .pullRequest, repository: "beta-labs/api", number: 8,
                    title: "Fixture Beta release review", relationships: [.reviewRequested],
                    body: "Listed first, so selecting the notification's item proves routing."
                ),
                item(
                    id: betaItemID.rawValue, kind: .issue, repository: "beta-labs/api", number: 7,
                    title: "Fixture Beta notification route work", relationships: [.assigned],
                    body: "A notification opens this item."
                )
            ]
        case studio.id:
            return [item(
                id: "fixture-studio-1", kind: .pullRequest, repository: "studio/site", number: 3,
                title: "Fixture Studio account switch work", relationships: [.authored],
                body: "Only the secondary account sees this work."
            )]
        default:
            return []
        }
    }

    private static func performanceItems() -> [PersonalWorkItem] {
        (1...performanceItemCount).map { index in
            let ordinal = String(format: "%05d", index)
            return item(
                id: "fixture-performance-\(ordinal)", kind: .issue, repository: "acme/performance", number: index,
                title: "Performance fixture work \(ordinal)", relationships: [.reviewRequested],
                body: "", updatedAt: date.addingTimeInterval(TimeInterval(-index))
            )
        }
    }

    private static func item(
        id: String, kind: WorkKind, repository: String, number: Int, title: String,
        relationships: Set<WorkRelationship>, body: String, pullRequest: PullRequestFacts? = nil,
        activity: [ActivityFact] = [], updatedAt: Date = date
    ) -> PersonalWorkItem {
        PersonalWorkItem(
            id: GitHubNodeID(rawValue: id)!, kind: kind, repository: repository, number: number, title: title,
            url: URL(string: "https://github.example.invalid/\(repository)/\(kind == .pullRequest ? "pull" : "issues")/\(number)")!,
            state: .open, author: "octocat", createdAt: date.addingTimeInterval(-86_400), updatedAt: updatedAt,
            relationships: relationships, labels: ["fixture"], assignees: relationships.contains(.assigned) ? ["fixture-primary"] : [],
            body: body, pullRequest: pullRequest, recentActivity: activity
        )
    }

    private static func account(
        _ rawID: String, userID: UInt64, login: String, name: String, kind: AuthenticationKind = .oauth
    ) -> GitHubAccount {
        GitHubAccount(
            id: AccountID(rawValue: rawID)!,
            githubUserID: userID,
            nodeID: GitHubNodeID(rawValue: "fixture-node-\(login)")!,
            login: login,
            displayName: name,
            authenticationKind: kind,
            credentialID: CredentialID(rawValue: "fixture-credential-\(login)")!,
            credentialStatus: .active,
            createdAt: date,
            lastValidatedAt: date
        )
    }

    private static func organization(_ rawID: String, databaseID: UInt64, login: String, name: String) -> GitHubOrganization {
        GitHubOrganization(
            id: OrganizationID(rawValue: rawID)!,
            githubOrganizationID: databaseID,
            nodeID: GitHubNodeID(rawValue: "fixture-node-\(login)")!,
            login: login,
            displayName: name
        )
    }
}
#endif
