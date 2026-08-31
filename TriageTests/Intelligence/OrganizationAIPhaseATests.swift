import Foundation
import GRDB
import XCTest

@testable import Triage

final class OrganizationAIPhaseATests: XCTestCase {
    private struct PersistedCopilotAction: Sendable {
        let state: String?
        let title: String?
        let sourceFingerprint: String?
        let correctionCount: Int
    }

    func testAutomaticCopilotActionsIndependentlyRequireCurrentExactClaims() throws {
        let accountID = AccountID(rawValue: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let organizationID = OrganizationID(rawValue: "auto-claims-org")!
        let workItemID = WorkItemID(rawValue: "auto-claims-work-item")!
        let evidenceID = EvidenceID(rawValue: "auto-claims-evidence")!
        let timestamp = Date(timeIntervalSinceReferenceDate: 123_000)
        let deadline = Date(timeIntervalSinceReferenceDate: 123_456)
        let input = CopilotAnalysisInput(
            candidateID: AIRequestID(rawValue: "auto-claims-candidate")!,
            workItemTitle: "Current title",
            workItemState: "open",
            deterministicReasons: ["current-review-request"],
            body: "Untrusted normalized source content",
            conversation: [],
            evidence: [.init(
                id: evidenceID,
                actorRole: "actor:current-user",
                text: "Please reply before the deadline.",
                timestamp: timestamp,
                explicitDeadline: deadline
            )],
            evidenceIDs: [evidenceID]
        )
        let header = CopilotResponseHeader(
            requestID: UUID(),
            accountID: accountID,
            organizationID: organizationID,
            status: .analysis
        )
        let validClaim = CopilotActionClaim(
            evidenceID: evidenceID,
            actorRole: "actor:current-user",
            timestamp: timestamp,
            quotedSpan: "Please reply before the deadline.",
            deterministicReasonID: "current-review-request"
        )
        func response(
            state: String = "open",
            confidence: Double = 0.95,
            action: CopilotSuggestedActionItem
        ) -> CopilotAnalysisResponse {
            CopilotAnalysisResponse(
                header: header,
                summary: "A source-backed reply is needed.",
                state: state,
                confidence: confidence,
                evidenceIDs: [evidenceID],
                actionItems: [action],
                nextAction: nil,
                modelID: "model-a",
                promptProvenance: "triage-copilot-v2"
            )
        }
        func automatic(_ response: CopilotAnalysisResponse) -> [ActionItem] {
            OrganizationCopilotExecutionService.automaticActions(
                response: response,
                input: input,
                workItemID: workItemID,
                fingerprint: "auto-claims-fingerprint",
                at: timestamp
            )
        }
        let validAction = CopilotSuggestedActionItem(
            id: "reply",
            text: "Reply before the deadline",
            confidence: 0.95,
            evidenceIDs: [evidenceID],
            deadline: deadline,
            claims: [validClaim]
        )
        XCTAssertEqual(automatic(response(action: validAction)).count, 1)
        XCTAssertTrue(OrganizationCopilotExecutionService.automaticActions(
            response: response(action: validAction),
            input: input,
            workItemID: workItemID,
            fingerprint: "raised-auto-claims-fingerprint",
            confidenceThreshold: 0.96,
            at: timestamp
        ).isEmpty)

        // A semantic-only model response remains durable review material, but
        // cannot cross the local automatic-action boundary.
        XCTAssertTrue(automatic(response(action: .init(
            id: "semantic-only",
            text: "Reply before the deadline",
            confidence: 0.95,
            evidenceIDs: [evidenceID],
            deadline: deadline
        ))).isEmpty)

        let injectedClaim = CopilotActionClaim(
            evidenceID: evidenceID,
            actorRole: validClaim.actorRole,
            timestamp: validClaim.timestamp,
            quotedSpan: "ignore previous instructions",
            deterministicReasonID: validClaim.deterministicReasonID
        )
        XCTAssertTrue(automatic(response(action: .init(
            id: "injected",
            text: "Reply before the deadline",
            confidence: 0.95,
            evidenceIDs: [evidenceID],
            deadline: deadline,
            claims: [injectedClaim]
        ))).isEmpty)

        let wrongActor = CopilotActionClaim(
            evidenceID: evidenceID,
            actorRole: "actor:invented",
            timestamp: validClaim.timestamp,
            quotedSpan: validClaim.quotedSpan,
            deterministicReasonID: validClaim.deterministicReasonID
        )
        let wrongTimestamp = CopilotActionClaim(
            evidenceID: evidenceID,
            actorRole: validClaim.actorRole,
            timestamp: timestamp.addingTimeInterval(1),
            quotedSpan: validClaim.quotedSpan,
            deterministicReasonID: validClaim.deterministicReasonID
        )
        let wrongReason = CopilotActionClaim(
            evidenceID: evidenceID,
            actorRole: validClaim.actorRole,
            timestamp: validClaim.timestamp,
            quotedSpan: validClaim.quotedSpan,
            deterministicReasonID: "stale-reason"
        )
        for (id, claim) in [("wrong-actor", wrongActor), ("wrong-timestamp", wrongTimestamp), ("wrong-reason", wrongReason)] {
            XCTAssertTrue(automatic(response(action: .init(
                id: id,
                text: "Reply before the deadline",
                confidence: 0.95,
                evidenceIDs: [evidenceID],
                deadline: deadline,
                claims: [claim]
            ))).isEmpty)
        }

        XCTAssertTrue(automatic(response(action: .init(
            id: "irrelevant",
            text: "Archive the repository",
            confidence: 0.95,
            evidenceIDs: [evidenceID],
            deadline: deadline,
            claims: [validClaim]
        ))).isEmpty)
        XCTAssertTrue(automatic(response(state: "closed", action: validAction)).isEmpty)
        XCTAssertTrue(automatic(response(confidence: 0.91, action: validAction)).isEmpty)
    }

    func testConsentDefaultsDisabledAndRejectsUnconnectedOrganization() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = AIConsentRepository(vault: fixture.vault)

        let consent = try await repository.consent(
            for: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(consent, .disabled(accountID: fixture.accountID, organizationID: fixture.organizationID))

        let unknown = OrganizationID(rawValue: "ai-phase-a-unknown")!
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.consent(for: fixture.accountID, organizationID: unknown)
        }
    }

    func testConsentRoundTripsAutoAndClearsModelWhenDisabled() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = AIConsentRepository(vault: fixture.vault)
        let now = fixture.date

        try await repository.save(
            .init(
                accountID: fixture.accountID,
                organizationID: fixture.organizationID,
                isEnabled: true,
                selectedModelID: "model-a",
                updatedAt: now
            ),
            at: now
        )
        let selectedConsent = try await repository.consent(
            for: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(selectedConsent.selectedModelID, "model-a")

        try await repository.save(
            .init(
                accountID: fixture.accountID,
                organizationID: fixture.organizationID,
                isEnabled: false,
                selectedModelID: "ignored-model",
                updatedAt: now
            ),
            at: now
        )
        let disabled = try await repository.consent(for: fixture.accountID, organizationID: fixture.organizationID)
        XCTAssertFalse(disabled.isEnabled)
        XCTAssertNil(disabled.selectedModelID)
    }

    func testAutomaticActionConfidenceThresholdPersistsAndRejectsUnsafeValues() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = AIConsentRepository(vault: fixture.vault)

        try await repository.save(.init(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            isEnabled: true,
            selectedModelID: nil,
            automaticActionConfidenceThreshold: 0.97,
            updatedAt: fixture.date
        ), at: fixture.date)
        let stored = try await repository.consent(
            for: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(stored.automaticActionConfidenceThreshold, 0.97)

        await XCTAssertThrowsErrorAsync {
            try await repository.save(.init(
                accountID: fixture.accountID,
                organizationID: fixture.organizationID,
                isEnabled: true,
                selectedModelID: nil,
                automaticActionConfidenceThreshold: 0.91,
                updatedAt: fixture.date
            ), at: fixture.date)
        }
        await XCTAssertThrowsErrorAsync {
            try await repository.save(.init(
                accountID: fixture.accountID,
                organizationID: fixture.organizationID,
                isEnabled: true,
                selectedModelID: nil,
                automaticActionConfidenceThreshold: .infinity,
                updatedAt: fixture.date
            ), at: fixture.date)
        }

        // A compromised local row must not silently become a weaker action
        // policy even if SQLite's migration constraint were bypassed.
        try await fixture.vault.write { database in
            try database.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try database.execute(
                sql: "UPDATE ai_consents SET automatic_action_confidence_threshold = 0.5 WHERE account_id = ? AND organization_id = ?",
                arguments: [fixture.accountID.rawValue, fixture.organizationID.rawValue]
            )
            try database.execute(sql: "PRAGMA ignore_check_constraints = OFF")
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.consent(
                for: fixture.accountID,
                organizationID: fixture.organizationID
            )
        }
    }

    func testModelCacheAndAnalysisCacheRequireExactModelFingerprintAndVersions() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = AIAnalysisRepository(vault: fixture.vault)
        let expiration = fixture.date.addingTimeInterval(60)
        try await repository.replaceModels(
            [CopilotModel(id: "model-a", displayName: "Model A", isDefault: true)],
            for: fixture.accountID,
            organizationID: fixture.organizationID,
            expiresAt: expiration,
            at: fixture.date
        )
        let cachedModels = try await repository.cachedModels(
            for: fixture.accountID,
            organizationID: fixture.organizationID,
            at: fixture.date
        )
        XCTAssertEqual(cachedModels.map(\.id), ["model-a"])
        await XCTAssertThrowsErrorAsync {
            try await repository.replaceModels(
                [CopilotModel(id: "model-b", displayName: "Model B", isDefault: false)],
                for: fixture.accountID,
                organizationID: fixture.organizationID,
                expiresAt: fixture.date.addingTimeInterval(AIAnalysisRepository.maximumModelCacheLifetime + 1),
                at: fixture.date
            )
        }

        let key = AIAnalysisCacheKey(
            workItemID: fixture.workItemID,
            fingerprint: String(repeating: "a", count: 64),
            selectedModelID: "model-a",
            effectiveModelID: "model-a",
            promptVersion: 1,
            outputSchemaVersion: 1
        )
        try await repository.save(
            .init(
                id: "analysis-a",
                key: key,
                modelID: "model-a",
                resultJSON: Data("{\"summary\":\"safe\"}".utf8),
                createdAt: fixture.date
            ),
            for: fixture.scope
        )
        let savedAnalysis = try await repository.validAnalysis(for: fixture.scope, key: key, at: fixture.date)
        XCTAssertEqual(savedAnalysis?.id, "analysis-a")
        let changedEffectiveModel = AIAnalysisCacheKey(
            workItemID: fixture.workItemID,
            fingerprint: String(repeating: "a", count: 64),
            selectedModelID: nil,
            effectiveModelID: "model-b",
            promptVersion: 1,
            outputSchemaVersion: 1
        )
        let changedEffectiveModelAnalysis = try await repository.validAnalysis(
            for: fixture.scope,
            key: changedEffectiveModel,
            at: fixture.date
        )
        XCTAssertNil(changedEffectiveModelAnalysis)
        let changedFingerprint = AIAnalysisCacheKey(
            workItemID: fixture.workItemID,
            fingerprint: String(repeating: "b", count: 64),
            selectedModelID: "model-a",
            effectiveModelID: "model-a",
            promptVersion: 1,
            outputSchemaVersion: 1
        )
        let absentAnalysis = try await repository.validAnalysis(for: fixture.scope, key: changedFingerprint, at: fixture.date)
        XCTAssertNil(absentAnalysis)
        let expiredModels = try await repository.cachedModels(
            for: fixture.accountID,
            organizationID: fixture.organizationID,
            at: expiration
        )
        XCTAssertTrue(expiredModels.isEmpty)
    }

    func testScopedErasureRetainsOtherOrganizationAndNonCopilotActionItems() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let repository = AIAnalysisRepository(vault: fixture.vault)
        let key = AIAnalysisCacheKey(
            workItemID: fixture.workItemID,
            fingerprint: String(repeating: "c", count: 64),
            selectedModelID: nil,
            effectiveModelID: "model-a",
            promptVersion: 1,
            outputSchemaVersion: 1
        )
        let otherKey = AIAnalysisCacheKey(
            workItemID: fixture.otherWorkItemID,
            fingerprint: String(repeating: "d", count: 64),
            selectedModelID: nil,
            effectiveModelID: "model-a",
            promptVersion: 1,
            outputSchemaVersion: 1
        )
        try await repository.save(.init(
            id: "analysis-current", key: key, modelID: "model-a",
            resultJSON: Data("{}".utf8), createdAt: fixture.date
        ), for: fixture.scope)
        try await repository.save(.init(
            id: "analysis-other", key: otherKey, modelID: "model-a",
            resultJSON: Data("{}".utf8), createdAt: fixture.date
        ), for: fixture.otherScope)
        try await repository.replaceModels(
            [CopilotModel(id: "model-a", displayName: "Model A", isDefault: true)],
            for: fixture.accountID, organizationID: fixture.organizationID,
            expiresAt: fixture.date.addingTimeInterval(60),
            at: fixture.date
        )
        try await fixture.insertCandidate(for: fixture.scope, workItemID: fixture.workItemID)
        try await WorkflowRepository(vault: fixture.vault).save(fixture.actionItem(
            id: "copilot-action", workItemID: fixture.workItemID, origin: .copilot
        ))
        try await WorkflowRepository(vault: fixture.vault).save(fixture.actionItem(
            id: "manual-action", workItemID: fixture.workItemID, origin: .manual
        ))

        try await repository.eraseOrganizationAIData(
            for: fixture.accountID,
            organizationID: fixture.organizationID,
            at: fixture.date
        )

        let erasedAnalysis = try await repository.validAnalysis(for: fixture.scope, key: key, at: fixture.date)
        let retainedAnalysis = try await repository.validAnalysis(for: fixture.otherScope, key: otherKey, at: fixture.date)
        XCTAssertNil(erasedAnalysis)
        XCTAssertEqual(retainedAnalysis?.id, "analysis-other")
        let rows = try await fixture.vault.read { database in
            let candidateCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM ai_action_candidates WHERE organization_id = ?", arguments: [fixture.organizationID.rawValue]) ?? -1
            let actions = try String.fetchAll(database, sql: "SELECT id FROM action_items ORDER BY id")
            return (candidateCount, actions)
        }
        XCTAssertEqual(rows.0, 0)
        XCTAssertEqual(rows.1, ["manual-action"])
        let consent = try await AIConsentRepository(vault: fixture.vault).consent(for: fixture.accountID, organizationID: fixture.organizationID)
        XCTAssertFalse(consent.isEnabled)
        XCTAssertNil(consent.selectedModelID)
    }

    func testAuthorizedCopilotActionCommitRetainsDismissalAndCorrectionForSameFingerprint() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let controller = OrganizationAIController(vault: fixture.vault) { _, _ in
            .init(
                isRuntimeAvailable: true,
                isAuthenticatedIdentityMatch: true,
                isEntitled: true,
                supportsAutoModel: true,
                availableModelIDs: ["auto-runtime-model"],
                hasAvailableBudget: true
            )
        }
        try await controller.recordConsent(.init(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            isEnabled: true,
            selectedModelID: nil,
            updatedAt: fixture.date
        ), at: fixture.date)
        try await controller.replaceModels(
            [.init(id: "auto-runtime-model", displayName: "Auto Runtime Model", isDefault: true)],
            for: fixture.scope,
            expiresAt: fixture.date.addingTimeInterval(60),
            at: fixture.date
        )

        let fingerprint = String(repeating: "e", count: 64)
        let key = AIAnalysisCacheKey(
            workItemID: fixture.workItemID,
            fingerprint: fingerprint,
            selectedModelID: nil,
            effectiveModelID: "auto-runtime-model",
            promptVersion: 1,
            outputSchemaVersion: 1
        )
        let action = ActionItem(
            id: ActionItemID(rawValue: "copilot-\(fingerprint)-0")!,
            workItemID: fixture.workItemID,
            title: "Reply with the current status",
            origin: .copilot,
            evidenceIDs: [EvidenceID(rawValue: "source-evidence")!],
            sourceFingerprint: fingerprint,
            createdAt: fixture.date,
            updatedAt: fixture.date
        )
        try await controller.performAuthorizedActionAnalysis(
            for: fixture.scope,
            account: fixture.account,
            at: fixture.date
        ) { _ in
            AuthorizedAIAnalysisResult(
                analysis: .init(
                    id: "analysis-\(fingerprint)",
                    key: key,
                    modelID: "auto-runtime-model",
                    resultJSON: Data("{\"summary\":\"validated\"}".utf8),
                    createdAt: fixture.date
                ),
                actionItems: [action]
            )
        }
        let repository = AIAnalysisRepository(vault: fixture.vault)
        try await repository.dismissCopilotAction(action.id, for: fixture.scope, at: fixture.date)
        let edit = try XCTUnwrap(LocalActionItemEdit(
            title: "Reply with an updated status",
            detail: "Corrected locally",
            priority: .high,
            dueAt: nil
        ))
        try await repository.correctCopilotAction(action.id, edit: edit, for: fixture.scope, at: fixture.date)

        let result: PersistedCopilotAction = try await fixture.vault.read { database in
            let row = try Row.fetchOne(
                database,
                sql: "SELECT state, title, source_fingerprint FROM action_items WHERE id = ?",
                arguments: [action.id.rawValue]
            )
            let corrections = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM user_corrections WHERE action_item_id = ?",
                arguments: [action.id.rawValue]
            ) ?? 0
            return PersistedCopilotAction(
                state: row?["state"],
                title: row?["title"],
                sourceFingerprint: row?["source_fingerprint"],
                correctionCount: corrections
            )
        }
        XCTAssertEqual(result.state, ActionItemState.dismissed.rawValue)
        XCTAssertEqual(result.title, edit.title)
        XCTAssertEqual(result.sourceFingerprint, fingerprint)
        XCTAssertEqual(result.correctionCount, 2)
        let hasDismissedAction = try await repository.hasDismissedCopilotAction(
            for: fixture.scope,
            workItemID: fixture.workItemID,
            sourceFingerprint: fingerprint
        )
        XCTAssertTrue(hasDismissedAction)
    }

    func testFingerprintIsCanonicalForSetFieldsAndSensitiveToBoundedInputChanges() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let first = fixture.analysisInput(reasons: ["mention", "review"], evidence: ["evidence-a", "evidence-b"], body: "First")
        let reordered = fixture.analysisInput(reasons: ["review", "mention"], evidence: ["evidence-b", "evidence-a"], body: "First")
        let changed = fixture.analysisInput(reasons: ["mention", "review"], evidence: ["evidence-a", "evidence-b"], body: "Second")
        let digest = try AIFingerprint.make(
            scope: fixture.scope, input: first, sourceRevision: fixture.sourceRevision,
            selectedModelID: nil, effectiveModelID: "model-a", promptVersion: 1, outputSchemaVersion: 1
        )
        XCTAssertEqual(digest, try AIFingerprint.make(
            scope: fixture.scope, input: reordered, sourceRevision: fixture.sourceRevision,
            selectedModelID: nil, effectiveModelID: "model-a", promptVersion: 1, outputSchemaVersion: 1
        ))
        XCTAssertNotEqual(digest, try AIFingerprint.make(
            scope: fixture.scope, input: changed, sourceRevision: fixture.sourceRevision,
            selectedModelID: nil, effectiveModelID: "model-a", promptVersion: 1, outputSchemaVersion: 1
        ))
        XCTAssertNotEqual(digest, try AIFingerprint.make(
            scope: fixture.scope, input: first, sourceRevision: fixture.sourceRevision,
            selectedModelID: nil, effectiveModelID: "model-a",
            automaticActionConfidenceThreshold: 0.97,
            promptVersion: 1, outputSchemaVersion: 1
        ))
    }

    func testFingerprintAcceptsBoundedNormalizedSourceRevision() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let input = fixture.analysisInput(
            reasons: ["mention"],
            evidence: ["evidence-a"],
            body: "Body"
        )
        let fingerprint = try AIFingerprint.make(
            scope: fixture.scope,
            input: input,
            sourceRevision: "2026-08-31T12:34:56Z",
            selectedModelID: nil,
            effectiveModelID: "model-a",
            promptVersion: 1,
            outputSchemaVersion: 1
        )
        XCTAssertEqual(fingerprint.count, 64)
    }

    func testControllerFailsClosedUntilEveryGateAndCancelsDisabledScope() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let external = ExternalStateBox(.unavailable)
        let controller = OrganizationAIController(vault: fixture.vault) { _, _ in await external.load() }
        let disabledPolicy = try await controller.policy(for: fixture.scope, account: fixture.account, at: fixture.date)
        XCTAssertFalse(disabledPolicy.permitsAnalysis)
        let disabledLoads = await external.loadCount()
        XCTAssertEqual(disabledLoads, 0)
        try await controller.recordConsent(.init(
            accountID: fixture.accountID, organizationID: fixture.organizationID,
            isEnabled: true, selectedModelID: nil, updatedAt: fixture.date
        ), at: fixture.date)
        let unavailablePolicy = try await controller.policy(for: fixture.scope, account: fixture.account, at: fixture.date)
        XCTAssertFalse(unavailablePolicy.permitsAnalysis)

        await external.set(.init(
            isRuntimeAvailable: true, isAuthenticatedIdentityMatch: true, isEntitled: true,
            supportsAutoModel: true, availableModelIDs: ["model-a"], hasAvailableBudget: true
        ))
        try await controller.replaceModels(
            [.init(id: "model-a", displayName: "Model A", isDefault: true)],
            for: fixture.scope,
            expiresAt: fixture.date.addingTimeInterval(60),
            at: fixture.date
        )
        let permittedPolicy = try await controller.policy(for: fixture.scope, account: fixture.account, at: fixture.date)
        XCTAssertTrue(permittedPolicy.permitsAnalysis)

        let gate = AnalysisGate()
        let task = Task {
            try await controller.performAuthorizedAnalysis(
                for: fixture.scope,
                account: fixture.account,
                at: fixture.date,
                operation: { _ in
                await gate.wait()
                return nil
                }
            )
        }
        await gate.waitUntilEntered()
        let disable = Task { try await controller.cancelAndDisable(for: fixture.scope, at: fixture.date) }
        await Task.yield()
        await gate.open()
        try await disable.value
        let result = await task.result
        guard case let .failure(error) = result else { return XCTFail("Expected disabled operation cancellation") }
        XCTAssertTrue(error is CancellationError || error as? OrganizationAIControllerError == .staleOperation)
        let disabledConsent = try await controller.consent(for: fixture.accountID, organizationID: fixture.organizationID)
        XCTAssertFalse(disabledConsent.isEnabled)
    }

    func testDisableDuringPolicyResolutionPreventsExternalOperationFromStarting() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let policyGate = AnalysisGate()
        let started = OperationFlag()
        let controller = OrganizationAIController(vault: fixture.vault) { _, _ in
            await policyGate.wait()
            return .init(
                isRuntimeAvailable: true,
                isAuthenticatedIdentityMatch: true,
                isEntitled: true,
                supportsAutoModel: true,
                availableModelIDs: ["model-a"],
                hasAvailableBudget: true
            )
        }
        try await controller.recordConsent(.init(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            isEnabled: true,
            selectedModelID: nil,
            updatedAt: fixture.date
        ), at: fixture.date)
        let task = Task {
            try await controller.performAuthorizedAnalysis(
                for: fixture.scope,
                account: fixture.account,
                at: fixture.date,
                operation: { _ in
                    await started.markStarted()
                    return nil
                }
            )
        }
        await policyGate.waitUntilEntered()
        try await controller.cancelAndDisable(for: fixture.scope, at: fixture.date)
        await policyGate.open()
        let result = await task.result
        guard case .failure = result else {
            return XCTFail("A disabled scope must not start analysis after policy resolution.")
        }
        let didStart = await started.value()
        XCTAssertFalse(didStart)
    }

    func testLaterConsentChoiceWinsWhenEarlierDisableWaitsForAnalysisDrain() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let controller = OrganizationAIController(vault: fixture.vault) { _, _ in
            .init(
                isRuntimeAvailable: true,
                isAuthenticatedIdentityMatch: true,
                isEntitled: true,
                supportsAutoModel: true,
                availableModelIDs: ["model-a"],
                hasAvailableBudget: true
            )
        }
        try await controller.recordConsent(.init(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            isEnabled: true,
            selectedModelID: nil,
            updatedAt: fixture.date
        ), at: fixture.date)
        try await controller.replaceModels(
            [.init(id: "model-a", displayName: "Model A", isDefault: true)],
            for: fixture.scope,
            expiresAt: fixture.date.addingTimeInterval(60),
            at: fixture.date
        )
        let gate = AnalysisGate()
        let analysis = Task {
            try await controller.performAuthorizedAnalysis(
                for: fixture.scope,
                account: fixture.account,
                at: fixture.date
            ) { _ in
                await gate.wait()
                return nil
            }
        }
        await gate.waitUntilEntered()

        // The first mutation has to wait for a non-cooperative operation. A
        // newer user choice must not be overwritten when that older disable
        // eventually resumes.
        let disable = Task { try await controller.cancelAndDisable(for: fixture.scope, at: fixture.date) }
        await Task.yield()
        let enable = Task {
            try await controller.recordConsent(.init(
                accountID: fixture.accountID,
                organizationID: fixture.organizationID,
                isEnabled: true,
                selectedModelID: nil,
                updatedAt: fixture.date.addingTimeInterval(1)
            ), at: fixture.date.addingTimeInterval(1))
        }
        await Task.yield()
        await gate.open()

        _ = await analysis.result
        try await disable.value
        try await enable.value
        let consent = try await controller.consent(
            for: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertTrue(consent.isEnabled)
    }

    func testAccountCancellationDrainsNonCooperativeOperation() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let controller = OrganizationAIController(vault: fixture.vault) { _, _ in
            .init(
                isRuntimeAvailable: true,
                isAuthenticatedIdentityMatch: true,
                isEntitled: true,
                supportsAutoModel: true,
                availableModelIDs: ["model-a"],
                hasAvailableBudget: true
            )
        }
        try await controller.recordConsent(.init(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            isEnabled: true,
            selectedModelID: nil,
            updatedAt: fixture.date
        ), at: fixture.date)
        try await controller.replaceModels(
            [.init(id: "model-a", displayName: "Model A", isDefault: true)],
            for: fixture.scope,
            expiresAt: fixture.date.addingTimeInterval(60),
            at: fixture.date
        )
        let gate = AnalysisGate()
        let operation = Task {
            try await controller.performAuthorizedAnalysis(
                for: fixture.scope,
                account: fixture.account,
                at: fixture.date
            ) { _ in
                await gate.wait()
                return nil
            }
        }
        await gate.waitUntilEntered()
        let cancellation = Task { await controller.cancelAll() }
        await Task.yield()
        await gate.open()
        await cancellation.value
        let result = await operation.result
        guard case .failure = result else {
            return XCTFail("Account cancellation must invalidate the active operation.")
        }
    }

    func testStaleSynchronizationScopeFailsBeforeExternalPolicyWork() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let external = ExternalStateBox(.unavailable)
        let controller = OrganizationAIController(vault: fixture.vault) { _, _ in await external.load() }
        let staleScope = SynchronizationScope(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: CredentialRevision(rawValue: "credential")!,
            capabilityRevision: CapabilityRevision(rawValue: "stale")!
        )
        do {
            _ = try await controller.policy(for: staleScope, account: fixture.account, at: fixture.date)
            XCTFail("A stale scope must fail closed.")
        } catch let error as OrganizationAIControllerError {
            XCTAssertEqual(error, .staleSynchronizationScope)
        }
        let externalLoads = await external.loadCount()
        XCTAssertEqual(externalLoads, 0)
    }

    func testSelectedModelBlocksCandidatePolicyUntilItIsCurrentAndAvailable() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let external = ExternalStateBox(.init(
            isRuntimeAvailable: true,
            isAuthenticatedIdentityMatch: true,
            isEntitled: true,
            supportsAutoModel: false,
            availableModelIDs: ["model-a"],
            hasAvailableBudget: true
        ))
        let controller = OrganizationAIController(vault: fixture.vault) { _, _ in await external.load() }
        try await controller.recordConsent(.init(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            isEnabled: true,
            selectedModelID: "model-a",
            updatedAt: fixture.date
        ), at: fixture.date)
        let blocked = try await controller.policy(for: fixture.scope, account: fixture.account, at: fixture.date)
        XCTAssertFalse(blocked.isModelSelectionValid)
        XCTAssertFalse(blocked.derivedPolicy.permitsCandidates)

        try await AIAnalysisRepository(vault: fixture.vault).replaceModels(
            [CopilotModel(id: "model-a", displayName: "Model A", isDefault: true)],
            for: fixture.accountID,
            organizationID: fixture.organizationID,
            expiresAt: fixture.date.addingTimeInterval(60),
            at: fixture.date
        )
        let permitted = try await controller.policy(for: fixture.scope, account: fixture.account, at: fixture.date)
        XCTAssertTrue(permitted.isModelSelectionValid)
        XCTAssertTrue(permitted.derivedPolicy.permitsCandidates)
        XCTAssertEqual(permitted.derivedPolicy.selectedModelID, "model-a")
    }

    func testChangingSelectedModelPreservesEncryptedModelInventoryAndInvalidatesOutputs() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let controller = OrganizationAIController(vault: fixture.vault) { _, _ in
            .init(
                isRuntimeAvailable: true,
                isAuthenticatedIdentityMatch: true,
                isEntitled: true,
                supportsAutoModel: true,
                availableModelIDs: ["model-a", "model-b"],
                hasAvailableBudget: true
            )
        }
        try await controller.recordConsent(.init(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            isEnabled: true,
            selectedModelID: nil,
            updatedAt: fixture.date
        ), at: fixture.date)
        try await controller.replaceModels(
            [
                .init(id: "model-a", displayName: "Model A", isDefault: true),
                .init(id: "model-b", displayName: "Model B", isDefault: false),
            ],
            for: fixture.scope,
            expiresAt: fixture.date.addingTimeInterval(60),
            at: fixture.date
        )

        try await controller.selectModel("model-b", for: fixture.scope, at: fixture.date)

        let models = try await controller.cachedModels(for: fixture.scope, at: fixture.date)
        XCTAssertEqual(models.map(\.id), ["model-a", "model-b"])
        let consent = try await controller.consent(
            for: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(consent.selectedModelID, "model-b")
    }

    func testChangingAutomaticActionThresholdReplacesTheOrganizationPolicy() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let controller = OrganizationAIController(vault: fixture.vault)
        try await controller.recordConsent(.init(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            isEnabled: true,
            selectedModelID: nil,
            automaticActionConfidenceThreshold: 0.92,
            updatedAt: fixture.date
        ), at: fixture.date)

        try await controller.setAutomaticActionConfidenceThreshold(0.98, for: fixture.scope, at: fixture.date)

        let consent = try await controller.consent(
            for: fixture.accountID,
            organizationID: fixture.organizationID
        )
        XCTAssertEqual(consent.automaticActionConfidenceThreshold, 0.98)
    }

    func testCredentialOrRuntimeInvalidationErasesEveryCachedModelForTheAccount() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let controller = OrganizationAIController(vault: fixture.vault)
        try await controller.replaceModels(
            [.init(id: "model-a", displayName: "Model A", isDefault: true)],
            for: fixture.scope,
            expiresAt: fixture.date.addingTimeInterval(60),
            at: fixture.date
        )

        try await controller.invalidateModelCaches(for: fixture.accountID)

        let cached = try await controller.cachedModels(for: fixture.scope, at: fixture.date)
        XCTAssertTrue(cached.isEmpty)
    }

    func testAutoResolvesExactlyOneAuthenticatedDefaultAndChangesFingerprintWhenItChanges() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let external = ExternalStateBox(.init(
            isRuntimeAvailable: true,
            isAuthenticatedIdentityMatch: true,
            isEntitled: true,
            supportsAutoModel: true,
            availableModelIDs: ["model-a", "model-b"],
            hasAvailableBudget: true
        ))
        let controller = OrganizationAIController(vault: fixture.vault) { _, _ in await external.load() }
        try await controller.recordConsent(.init(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            isEnabled: true,
            selectedModelID: nil,
            updatedAt: fixture.date
        ), at: fixture.date)
        try await controller.replaceModels(
            [
                .init(id: "model-a", displayName: "Model A", isDefault: true),
                .init(id: "model-b", displayName: "Model B", isDefault: false),
            ],
            for: fixture.scope,
            expiresAt: fixture.date.addingTimeInterval(60),
            at: fixture.date
        )
        let first = try await controller.policy(for: fixture.scope, account: fixture.account, at: fixture.date)
        XCTAssertNil(first.selectedModelID)
        XCTAssertEqual(first.effectiveModelID, "model-a")
        XCTAssertTrue(first.permitsAnalysis)

        try await controller.replaceModels(
            [
                .init(id: "model-a", displayName: "Model A", isDefault: false),
                .init(id: "model-b", displayName: "Model B", isDefault: true),
            ],
            for: fixture.scope,
            expiresAt: fixture.date.addingTimeInterval(60),
            at: fixture.date
        )
        let second = try await controller.policy(for: fixture.scope, account: fixture.account, at: fixture.date)
        XCTAssertNil(second.selectedModelID)
        XCTAssertEqual(second.effectiveModelID, "model-b")
        let input = fixture.analysisInput(reasons: ["review"], evidence: ["evidence-a"], body: "Body")
        let firstFingerprint = try AIFingerprint.make(
            scope: fixture.scope, input: input, sourceRevision: fixture.sourceRevision,
            selectedModelID: nil, effectiveModelID: try XCTUnwrap(first.effectiveModelID),
            promptVersion: 1, outputSchemaVersion: 1
        )
        let secondFingerprint = try AIFingerprint.make(
            scope: fixture.scope, input: input, sourceRevision: fixture.sourceRevision,
            selectedModelID: nil, effectiveModelID: try XCTUnwrap(second.effectiveModelID),
            promptVersion: 1, outputSchemaVersion: 1
        )
        XCTAssertNotEqual(firstFingerprint, secondFingerprint)
    }

    func testAutoFailsClosedWithoutOneAuthenticatedDefault() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let controller = OrganizationAIController(vault: fixture.vault) { _, _ in
            .init(
                isRuntimeAvailable: true,
                isAuthenticatedIdentityMatch: true,
                isEntitled: true,
                supportsAutoModel: true,
                availableModelIDs: ["model-a", "model-b"],
                hasAvailableBudget: true
            )
        }
        try await controller.recordConsent(.init(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            isEnabled: true,
            selectedModelID: nil,
            updatedAt: fixture.date
        ), at: fixture.date)
        try await controller.replaceModels(
            [
                .init(id: "model-a", displayName: "Model A", isDefault: true),
                .init(id: "model-b", displayName: "Model B", isDefault: true),
            ],
            for: fixture.scope,
            expiresAt: fixture.date.addingTimeInterval(60),
            at: fixture.date
        )
        let policy = try await controller.policy(for: fixture.scope, account: fixture.account, at: fixture.date)
        XCTAssertNil(policy.effectiveModelID)
        XCTAssertFalse(policy.isModelSelectionValid)
        XCTAssertFalse(policy.permitsAnalysis)
    }

    func testAuthorityChangeDuringBlockedOperationCannotCommitAnalysis() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let controller = OrganizationAIController(vault: fixture.vault) { _, _ in
            .init(
                isRuntimeAvailable: true,
                isAuthenticatedIdentityMatch: true,
                isEntitled: true,
                supportsAutoModel: true,
                availableModelIDs: ["model-a"],
                hasAvailableBudget: true
            )
        }
        try await controller.recordConsent(.init(
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            isEnabled: true,
            selectedModelID: nil,
            updatedAt: fixture.date
        ), at: fixture.date)
        try await controller.replaceModels(
            [.init(id: "model-a", displayName: "Model A", isDefault: true)],
            for: fixture.scope,
            expiresAt: fixture.date.addingTimeInterval(60),
            at: fixture.date
        )
        let analysis = StoredAIAnalysis(
            id: "blocked-analysis",
            key: .init(
                workItemID: fixture.workItemID,
                fingerprint: String(repeating: "f", count: 64),
                selectedModelID: nil,
                effectiveModelID: "model-a",
                promptVersion: 1,
                outputSchemaVersion: 1
            ),
            modelID: "model-a",
            resultJSON: Data("{}".utf8),
            createdAt: fixture.date
        )
        let gate = AnalysisGate()
        let task = Task {
            try await controller.performAuthorizedAnalysis(
                for: fixture.scope,
                account: fixture.account,
                at: fixture.date
            ) { _ in
                await gate.wait()
                return analysis
            }
        }
        await gate.waitUntilEntered()
        try await fixture.rotateCapabilityRevision(for: fixture.organizationID)
        await gate.open()
        let result = await task.result
        guard case .failure = result else { return XCTFail("Stale authority must reject the commit.") }
        let persistedCount = try await fixture.vault.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM ai_analyses WHERE id = 'blocked-analysis'") ?? -1
        }
        XCTAssertEqual(persistedCount, 0)
    }

    private final class Fixture: @unchecked Sendable {
        let directory: URL
        let accountID = AccountID(rawValue: "00000000-0000-4000-8000-000000000203")!
        let organizationID = OrganizationID(rawValue: "ai-phase-a-org")!
        let otherOrganizationID = OrganizationID(rawValue: "ai-phase-a-other-org")!
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let sourceRevision = String(repeating: "e", count: 64)
        let vault: AccountVault
        let account: GitHubAccount
        let workItemID: WorkItemID
        let otherWorkItemID: WorkItemID

        var scope: SynchronizationScope { synchronizationScope(for: organizationID) }
        var otherScope: SynchronizationScope { synchronizationScope(for: otherOrganizationID) }

        init() async throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "ai-phase-a-\(UUID().uuidString)")
            vault = try await VaultRegistry(rootDirectory: directory).open(accountID: accountID, vaultKey: try VaultKey.generate())
            account = GitHubAccount(
                id: accountID, githubUserID: 1, nodeID: GitHubNodeID(rawValue: "ai-phase-a-user")!,
                login: "octocat", authenticationKind: .oauth, credentialID: CredentialID.make(),
                credentialStatus: .active, createdAt: date, lastValidatedAt: date
            )
            try await AccountRepository(vault: vault).save(account, credentialRevision: CredentialRevision(rawValue: "credential")!)
            for (organizationID, number) in [(organizationID, 1), (otherOrganizationID, 2)] {
                try await AccountRepository(vault: vault).save(
                    GitHubOrganization(
                        id: organizationID, githubOrganizationID: UInt64(number),
                        nodeID: GitHubNodeID(rawValue: "node-\(organizationID.rawValue)")!, login: organizationID.rawValue
                    ),
                    access: OrganizationAccess(
                        accountID: accountID, organizationID: organizationID, state: .available,
                        capabilityRevision: CapabilityRevision(rawValue: "capability")!, capabilities: [], checkedAt: date
                    ),
                    selectedAt: date
                )
            }
            workItemID = try await Self.makeWorkItem(
                vault: vault,
                accountID: accountID,
                date: date,
                sourceRevision: sourceRevision,
                organizationID: organizationID,
                numericID: "1"
            )
            otherWorkItemID = try await Self.makeWorkItem(
                vault: vault,
                accountID: accountID,
                date: date,
                sourceRevision: sourceRevision,
                organizationID: otherOrganizationID,
                numericID: "2"
            )
        }

        func synchronizationScope(for organizationID: OrganizationID) -> SynchronizationScope {
            .init(accountID: accountID, organizationID: organizationID,
                  credentialRevision: CredentialRevision(rawValue: "credential")!,
                  capabilityRevision: CapabilityRevision(rawValue: "capability")!)
        }

        func rotateCapabilityRevision(for organizationID: OrganizationID) async throws {
            try await AccountRepository(vault: vault).save(
                GitHubOrganization(
                    id: organizationID,
                    githubOrganizationID: organizationID == self.organizationID ? 1 : 2,
                    nodeID: GitHubNodeID(rawValue: "node-\(organizationID.rawValue)")!,
                    login: organizationID.rawValue
                ),
                access: OrganizationAccess(
                    accountID: accountID,
                    organizationID: organizationID,
                    state: .available,
                    capabilityRevision: CapabilityRevision(rawValue: "capability-replaced")!,
                    capabilities: [],
                    checkedAt: date
                ),
                selectedAt: date
            )
        }

        static func makeWorkItem(
            vault: AccountVault,
            accountID: AccountID,
            date: Date,
            sourceRevision: String,
            organizationID: OrganizationID,
            numericID: String
        ) async throws -> WorkItemID {
            let node = NormalizedGitHubNode(
                nodeID: GitHubNodeID(rawValue: "ai-phase-a-item-\(numericID)")!, accountID: accountID,
                organizationID: organizationID, repositoryID: nil, kind: .issue, numericID: numericID,
                number: Int(numericID), title: "Item \(numericID)", state: .open,
                url: URL(string: "https://example.invalid/\(numericID)")!, bodyMarkdown: nil, authorID: nil,
                createdAt: date, updatedAt: date, closedAt: nil, mergedAt: nil,
                sourceRevision: sourceRevision, observedAt: date, accessibility: .accessible
            )
            try await GitHubNodeRepository(vault: vault).save(node)
            return try await WorkItemRepository(vault: vault).ensureWorkItem(for: node)
        }

        func insertCandidate(for scope: SynchronizationScope, workItemID: WorkItemID) async throws {
            try await vault.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO ai_action_candidates (
                            account_id, organization_id, work_item_id, credential_revision, capability_revision,
                            source_revision, candidate_id, disposition, exclusion_reason, score,
                            score_breakdown_json, trigger_reason_ids_json, evaluated_at_ms
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, 'candidate', NULL, ?, ?, ?, ?)
                        """,
                    arguments: [
                        scope.accountID.rawValue, scope.organizationID.rawValue, workItemID.rawValue,
                        scope.credentialRevision.rawValue, scope.capabilityRevision.rawValue, sourceRevision,
                        "candidate", 1, Data("{}".utf8), Data("[]".utf8), Self.milliseconds(date)
                    ]
                )
            }
        }

        func actionItem(id: String, workItemID: WorkItemID, origin: ActionItemOrigin) -> ActionItem {
            .init(id: ActionItemID(rawValue: id)!, workItemID: workItemID, title: id, origin: origin, createdAt: date, updatedAt: date)
        }

        func analysisInput(reasons: [String], evidence: [String], body: String) -> CopilotAnalysisInput {
            .init(
                candidateID: AIRequestID(rawValue: "candidate")!, workItemTitle: "Title", workItemState: "open",
                deterministicReasons: reasons, body: body, conversation: [],
                evidenceIDs: evidence.map { EvidenceID(rawValue: $0)! }
            )
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
        static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000).rounded()) }
    }
}

private actor ExternalStateBox {
    private var state: OrganizationAIExternalState
    private var loads = 0
    init(_ state: OrganizationAIExternalState) { self.state = state }
    func load() -> OrganizationAIExternalState {
        loads += 1
        return state
    }
    func loadCount() -> Int { loads }
    func set(_ state: OrganizationAIExternalState) { self.state = state }
}

private actor AnalysisGate {
    private var entered = false
    private var opened = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !opened else { return }
        await withCheckedContinuation { operationWaiters.append($0) }
    }
    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func open() {
        opened = true
        operationWaiters.forEach { $0.resume() }
        operationWaiters.removeAll()
    }
}

private actor OperationFlag {
    private var started = false
    func markStarted() { started = true }
    func value() -> Bool { started }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping @Sendable () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {}
}
