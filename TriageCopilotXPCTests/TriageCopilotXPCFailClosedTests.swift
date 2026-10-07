import Foundation
import XCTest

final class TriageCopilotXPCFailClosedTests: XCTestCase {
  func testCopilotProfileSurvivesSessionCleanupAndTheNextConnection() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "CopilotPersistentProfile-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let accountID = UUID().uuidString.lowercased()
    let bundle = try makeFixtureBundle(helperPermissions: 0o700)
    let profile = root.appending(path: "Triage/CopilotXPC/\(accountID)/copilot-home")
    let marker = profile.appending(path: "fixture-marker")
    for attempt in 0..<2 {
      let process = CopilotHelperProcess(
        bundle: bundle,
        applicationSupportDirectory: root,
        signatureValidator: { _, _ in },
        runtimeVerifier: TestRuntimeVerifier.trusted(),
        processLauncher: { _ in throw CopilotXPCServiceError.processLaunchFailed }
      )
      XCTAssertThrowsError(try process.exchange(frame: authenticatedRequest(
        accountID: accountID, requestID: UUID().uuidString.lowercased(), credential: "fixture"
      )))
      XCTAssertTrue(FileManager.default.fileExists(atPath: profile.path))
      if attempt == 0 { try Data("nonsecret fixture".utf8).write(to: marker) }
      process.cancel()
      XCTAssertEqual(try Data(contentsOf: marker), Data("nonsecret fixture".utf8))
    }
  }

  func testEmbeddedServiceDeclaresLaunchMetadataAndUsesTheSigningTeam() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appending(path: "Configuration/TriageCopilotXPC-Info.plist"))
    let plist = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    )
    let service = try XCTUnwrap(plist["XPCService"] as? [String: String])
    XCTAssertEqual(service["ServiceType"], "Application")
    XCTAssertEqual(service["RunLoopType"], "NSRunLoop")
    XCTAssertEqual(plist["TriageExpectedTeamIdentifier"] as? String, "$(DEVELOPMENT_TEAM)")
  }

  func testAuthenticationStageMessagesAreStrictlyAllowlisted() throws {
    let accountID = UUID().uuidString.lowercased()
    let requestID = UUID().uuidString.lowercased()
    let request = try CopilotXPCFrame.validatedRequestHeader(authenticatedRequest(
      accountID: accountID, requestID: requestID, credential: "fixture-only"
    ))
    let safeMessage = "Copilot browser login exited before authorization completed."
    for message in [safeMessage, safeMessage + " secret-must-not-escape"] {
      let response = try framedJSON([
        "protocol_version": 2, "request_id": requestID,
        "account_id": accountID, "organization_id": "org-1", "status": "failure",
        "failure": ["code": "authentication_failed", "message": message],
      ])
      guard case let .fixedAuthenticationFailure(frame) =
        try CopilotXPCFrame.responseForForwarding(response, matches: request)
      else { return XCTFail("Authentication errors must use a fixed response.") }
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.dropFirst(4))) as? [String: Any])
      let failure = try XCTUnwrap(object["failure"] as? [String: String])
      XCTAssertFalse(failure["message"]!.contains("secret-must-not-escape"))
      XCTAssertEqual(failure["message"] == safeMessage, message == safeMessage)
    }
  }

  func testOwnedRequestFrameDeepCopiesAndWipesAfterQueueUse() throws {
    let secret = Data("gho_owned-frame-must-not-survive-queue-use".utf8)
    var source = secret
    let owned = CopilotOwnedRequestFrame(copying: source)
    source.resetBytes(in: source.startIndex..<source.endIndex)
    var observed = Data()
    defer { CopilotXPCFrame.wipe(&observed) }

    try owned.withWipedFrame { frame in
      observed = frame
      XCTAssertEqual(frame, secret)
      frame.replaceSubrange(frame.startIndex..<frame.endIndex, with: [])
    }

    XCTAssertEqual(observed, secret)
    XCTAssertTrue(owned.isWipedForTesting)
  }

  func testMissingHelperRejectsBeforeProcessLaunch() throws {
    let bundle = try makeFixtureBundle(helperPermissions: nil)
    var didLaunch = false
    let process = CopilotHelperProcess(
      bundle: bundle,
      runtimeVerifier: TestRuntimeVerifier.trusted(),
      processLauncher: { _ in didLaunch = true }
    )

    XCTAssertThrowsError(try process.exchange(frame: framedRequest(accountID: fixtureAccountID))) { error in
      XCTAssertEqual(error as? CopilotXPCServiceError, .helperUnavailable)
    }
    XCTAssertFalse(didLaunch)
  }

  func testNonExecutableHelperRejectsBeforeSignatureValidationOrLaunch() throws {
    let bundle = try makeFixtureBundle(helperPermissions: 0o600)
    var didValidate = false
    var didLaunch = false
    let process = CopilotHelperProcess(
      bundle: bundle,
      signatureValidator: { _, _ in didValidate = true },
      runtimeVerifier: TestRuntimeVerifier.trusted(),
      processLauncher: { _ in didLaunch = true }
    )

    XCTAssertThrowsError(try process.exchange(frame: framedRequest(accountID: fixtureAccountID))) { error in
      XCTAssertEqual(error as? CopilotXPCServiceError, .helperNotExecutable)
    }
    XCTAssertFalse(didValidate)
    XCTAssertFalse(didLaunch)
  }

  func testRejectedHelperSignatureNeverLaunchesProcess() throws {
    let bundle = try makeFixtureBundle(helperPermissions: 0o700)
    var didLaunch = false
    let process = CopilotHelperProcess(
      bundle: bundle,
      signatureValidator: { _, _ in throw CopilotXPCServiceError.codeSignatureNotValidated },
      runtimeVerifier: TestRuntimeVerifier.trusted(),
      processLauncher: { _ in didLaunch = true }
    )

    XCTAssertThrowsError(try process.exchange(frame: framedRequest(accountID: fixtureAccountID))) { error in
      XCTAssertEqual(error as? CopilotXPCServiceError, .codeSignatureNotValidated)
    }
    XCTAssertFalse(didLaunch)
  }

  func testNonOpaqueScratchOwnerRejectsBeforeProcessLaunch() throws {
    let bundle = try makeFixtureBundle(helperPermissions: 0o700)
    var didLaunch = false
    var signedIdentifier: String?
    let process = CopilotHelperProcess(
      bundle: bundle,
      signatureValidator: { _, identifier in signedIdentifier = identifier },
      runtimeVerifier: TestRuntimeVerifier.trusted(),
      processLauncher: { _ in didLaunch = true }
    )
    let payload = Data(
      #"{"protocol_version":2,"request_id":"00000000-0000-4000-8000-000000000001","account_id":"not-an-opaque-account","organization_id":"org-1","operation":"authenticate","credential":"test-fixture-credential"}"#
        .utf8
    )
    var length = UInt32(payload.count).bigEndian
    var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
    frame.append(payload)

    XCTAssertThrowsError(try process.exchange(frame: frame)) { error in
      XCTAssertEqual(error as? CopilotXPCServiceError, .invalidAccountID)
    }
    XCTAssertNil(signedIdentifier)
    XCTAssertFalse(didLaunch)
  }

  func testAccountDeletionJournalFencesScratchCreationBeforeProcessLaunch() throws {
    let accountID = UUID().uuidString.lowercased()
    let applicationSupport = FileManager.default.temporaryDirectory
      .appending(path: "TriageCopilotXPCDeletionFence-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: applicationSupport) }
    let recovery = applicationSupport
      .appending(path: "Triage")
      .appending(path: "Recovery")
      .appending(path: accountID)
    addTeardownBlock { try? FileManager.default.removeItem(at: recovery) }
    try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
    try Data("deletion in progress".utf8).write(
      to: recovery.appending(path: "account-deletion.json")
    )

    let bundle = try makeFixtureBundle(helperPermissions: 0o700)
    var didLaunch = false
    let process = CopilotHelperProcess(
      bundle: bundle,
      applicationSupportDirectory: applicationSupport,
      signatureValidator: { _, _ in },
      runtimeVerifier: TestRuntimeVerifier.trusted(),
      processLauncher: { _ in didLaunch = true }
    )

    XCTAssertThrowsError(try process.exchange(frame: framedRequest(accountID: accountID))) { error in
      XCTAssertEqual(error as? CopilotXPCServiceError, .accountDeletionInProgress)
    }
    XCTAssertFalse(didLaunch)
  }

  func testSymlinkedScratchAncestorRejectsBeforeProcessLaunch() throws {
    let accountID = UUID().uuidString.lowercased()
    let applicationSupport = FileManager.default.temporaryDirectory
      .appending(path: "TriageCopilotXPCSymlinkScratch-\(UUID().uuidString)")
    let external = FileManager.default.temporaryDirectory
      .appending(path: "TriageCopilotXPCSymlinkExternal-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: applicationSupport)
      try? FileManager.default.removeItem(at: external)
    }
    try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: applicationSupport.appending(path: "Triage"),
      withDestinationURL: external
    )

    let bundle = try makeFixtureBundle(helperPermissions: 0o700)
    var didLaunch = false
    let process = CopilotHelperProcess(
      bundle: bundle,
      applicationSupportDirectory: applicationSupport,
      signatureValidator: { _, _ in },
      runtimeVerifier: TestRuntimeVerifier.trusted(),
      processLauncher: { _ in didLaunch = true }
    )

    XCTAssertThrowsError(try process.exchange(frame: framedRequest(accountID: accountID))) { error in
      XCTAssertEqual(error as? CopilotXPCServiceError, .processLaunchFailed)
    }
    XCTAssertFalse(didLaunch)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(at: external, includingPropertiesForKeys: nil),
      []
    )
  }

  func testMissingRuntimeRejectsBeforeScratchOrHelperLaunch() throws {
    let applicationSupport = FileManager.default.temporaryDirectory
      .appending(path: "TriageCopilotXPCMissingRuntime-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: applicationSupport) }
    try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)

    let bundle = try makeFixtureBundle(helperPermissions: 0o700)
    var didLaunch = false
    let process = CopilotHelperProcess(
      bundle: bundle,
      applicationSupportDirectory: applicationSupport,
      signatureValidator: { _, _ in },
      processLauncher: { _ in didLaunch = true }
    )

    XCTAssertThrowsError(try process.exchange(frame: framedRequest(accountID: UUID().uuidString.lowercased()))) { error in
      XCTAssertEqual(error as? CopilotXPCServiceError, .runtimeUnavailable)
    }
    XCTAssertFalse(didLaunch)
    XCTAssertFalse(FileManager.default.fileExists(atPath: applicationSupport.appending(path: "Triage/CopilotXPC").path))
  }

  func testRuntimeTrustFailuresNeverLaunchHelper() throws {
    let bundle = try makeFixtureBundle(helperPermissions: 0o700)
    let accountID = UUID().uuidString.lowercased()
    for failure in [
      CopilotXPCServiceError.runtimeCorrupt, // swapped leaf
      .runtimeCorrupt, // symlink or hard link
      .runtimeCorrupt, // hash mismatch
      .runtimeCorrupt, // Mach-O architecture mismatch
      .runtimeCorrupt, // signature or hardened-runtime mismatch
      .runtimeUnavailable,
    ] {
      var didLaunch = false
      let process = CopilotHelperProcess(
        bundle: bundle,
        signatureValidator: { _, _ in },
        runtimeVerifier: TestRuntimeVerifier(failure: failure),
        processLauncher: { _ in didLaunch = true }
      )
      XCTAssertThrowsError(try process.exchange(frame: framedRequest(accountID: accountID))) { error in
        XCTAssertEqual(error as? CopilotXPCServiceError, failure)
      }
      XCTAssertFalse(didLaunch)
    }
  }

  func testRuntimeTrustPinsTheExtractedExecutableRatherThanItsArchive() {
    XCTAssertEqual(
      CopilotRuntimeHostArchitecture.arm64.expectedExecutableSHA256,
      "2f4238eebaa42e1196e4f9473a06d03fca612fd6fed09bb9033d9c506d4a5e9a"
    )
    XCTAssertEqual(
      CopilotRuntimeHostArchitecture.x86_64.expectedExecutableSHA256,
      "8da653f6c4944d6be001af17aaf6d685066c91b1f62af543bbc3ebb35b85435c"
    )
    XCTAssertNotEqual(
      CopilotRuntimeHostArchitecture.arm64.expectedExecutableSHA256,
      "7d693bfdc82f1a1223d4fe034903faeb16063cbc0075d0f45e04af1ea7914871"
    )
    XCTAssertNotEqual(
      CopilotRuntimeHostArchitecture.x86_64.expectedExecutableSHA256,
      "1fb04e8e040525ae39cf53cce7f9e44b7d3fbb200bc9bfe38e2e7436d7dd3b74"
    )
  }

  func testVerifiedRuntimePathsAreAbsentFromHelperArgumentsAndEnvironment() throws {
    let applicationSupport = FileManager.default.temporaryDirectory
      .appending(path: "TriageCopilotXPCRuntimeHandoff-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: applicationSupport) }
    let runtime = CopilotTrustedRuntime(
      executableURL: URL(fileURLWithPath: "/private/triage-runtime/copy/copilot"),
      lockURL: URL(fileURLWithPath: "/private/triage-runtime/.runtime.lock")
    )
    let bundle = try makeFixtureBundle(helperPermissions: 0o700)
    var capturedArguments: [String] = []
    var capturedEnvironment: [String: String] = [:]
    let process = CopilotHelperProcess(
      bundle: bundle,
      applicationSupportDirectory: applicationSupport,
      signatureValidator: { _, _ in },
      runtimeVerifier: TestRuntimeVerifier(runtime: runtime),
      processLauncher: { launched in
        capturedArguments = launched.arguments ?? []
        capturedEnvironment = launched.environment ?? [:]
        throw CopilotXPCServiceError.processLaunchFailed
      }
    )

    XCTAssertThrowsError(try process.exchange(frame: framedRequest(accountID: UUID().uuidString.lowercased())))
    XCTAssertTrue(capturedArguments.isEmpty)
    XCTAssertFalse(capturedArguments.contains { $0.contains("/private/") })
    XCTAssertFalse(capturedEnvironment.values.contains { $0.contains("/private/") })
    XCTAssertNil(capturedEnvironment["HOME"])
    XCTAssertNil(capturedEnvironment["COPILOT_HOME"])
    XCTAssertNil(capturedEnvironment["PATH"])
    XCTAssertNil(capturedEnvironment["COPILOT_CLI_PATH"])
    XCTAssertEqual(capturedEnvironment["COPILOT_SKIP_CLI_DOWNLOAD"], "1")
  }

  func testMalformedTeamIdentifiersAreRejectedBeforeCodeValidation() {
    for teamIdentifier in [nil, "", "not-a-team", "ABCDE1234!"] {
      XCTAssertThrowsError(
        try CopilotCodeSignatureValidator.validatedTeamIdentifier(teamIdentifier)
      ) { error in
        XCTAssertEqual(error as? CopilotXPCServiceError, .codeSignatureNotValidated)
      }
      XCTAssertThrowsError(
        try CopilotXPCCallerValidator.validatedTeamIdentifier(teamIdentifier)
      ) { error in
        XCTAssertEqual(error as? CopilotXPCServiceError, .callerNotAuthorized)
      }
    }
  }

  func testUnauthorizedCallerNeverInvokesHelper() {
    let helper = RecordingHelperProcess()
    let service = TriageCopilotXPCService(
      callerValidator: { throw CopilotXPCServiceError.callerNotAuthorized },
      helperProcess: helper
    )
    let reply = ReplyCapture()

    service.exchange(frame: Data()) { data, error in
      reply.record(data: data, error: error)
    }

    XCTAssertNil(reply.data)
    XCTAssertEqual(reply.error?.domain, "com.triage.mac.copilot-xpc")
    XCTAssertEqual(reply.error?.code, CopilotXPCServiceError.callerNotAuthorized.rawValue)
    XCTAssertEqual(helper.exchangeCount, 0)
  }

  func testMalformedFrameNeverInvokesHelper() {
    let helper = RecordingHelperProcess()
    let service = TriageCopilotXPCService(
      callerValidator: {},
      helperProcess: helper
    )
    let expectation = expectation(description: "malformed frame reply")
    let reply = ReplyCapture(expectation: expectation)

    service.exchange(frame: Data()) { data, error in
      reply.record(data: data, error: error)
    }

    wait(for: [expectation], timeout: 1)
    XCTAssertNil(reply.data)
    XCTAssertEqual(reply.error?.code, CopilotXPCServiceError.malformedFrame.rawValue)
    XCTAssertEqual(helper.exchangeCount, 0)
  }

  func testEachConnectionOwnsItsHelperCancellation() {
    let first = CancellationRecordingHelper()
    let second = CancellationRecordingHelper()
    var helpers = [first, second]
    let listener = TriageCopilotXPCListener(makeHelperProcess: {
      helpers.removeFirst()
    })
    let firstService = listener.makeServiceForConnection()
    let secondService = listener.makeServiceForConnection()

    firstService.cancelActiveProcess()
    XCTAssertEqual(first.cancelCount, 1)
    XCTAssertEqual(second.cancelCount, 0)

    secondService.cancelActiveProcess()
    XCTAssertEqual(first.cancelCount, 1)
    XCTAssertEqual(second.cancelCount, 1)
  }

  func testAuthenticatedExchangeBindsHeadersWithoutExposingCredential() throws {
    let accountID = UUID().uuidString.lowercased()
    let requestID = UUID().uuidString.lowercased()
    let credential = "gho_auth-token-must-not-escape"
    let request = try framedJSON([
      "protocol_version": 2,
      "request_id": requestID,
      "account_id": accountID,
      "organization_id": "org-1",
      "operation": "authenticate",
      "credential": credential,
    ])
    let response = try framedJSON([
      "protocol_version": 2,
      "request_id": requestID,
      "account_id": accountID,
      "organization_id": "org-1",
      "status": "authentication",
      "authentication": [
        "host": "github.com",
        "login": "octocat",
        "auth_type": "token",
        "is_authenticated": true,
      ],
    ])
    let service = TriageCopilotXPCService(
      callerValidator: {},
      helperProcess: FrameReturningHelper(response: response)
    )
    let expectation = expectation(description: "authenticated reply")
    let reply = ReplyCapture(expectation: expectation)

    service.exchange(frame: request) { data, error in
      reply.record(data: data, error: error)
    }

    wait(for: [expectation], timeout: 1)
    XCTAssertNil(reply.error)
    XCTAssertFalse(String(data: try XCTUnwrap(reply.data), encoding: .utf8)!.contains(credential))
  }

  func testAuthenticatedExchangeRejectsMismatchedResponseIdentityWithoutCredentialLeak() throws {
    let accountID = UUID().uuidString.lowercased()
    let requestID = UUID().uuidString.lowercased()
    let credential = "gho_cross-account-token-must-not-escape"
    let request = try authenticatedRequest(
      accountID: accountID,
      requestID: requestID,
      credential: credential
    )
    let response = try framedJSON([
      "protocol_version": 2,
      "request_id": requestID,
      "account_id": UUID().uuidString.lowercased(),
      "organization_id": "org-1",
      "status": "authentication",
      "authentication": [
        "host": "github.com", "login": "octocat", "auth_type": "token", "is_authenticated": true,
      ],
    ])
    let service = TriageCopilotXPCService(
      callerValidator: {},
      helperProcess: FrameReturningHelper(response: response)
    )
    let expectation = expectation(description: "identity mismatch reply")
    let reply = ReplyCapture(expectation: expectation)

    service.exchange(frame: request) { data, error in
      reply.record(data: data, error: error)
    }

    wait(for: [expectation], timeout: 1)
    XCTAssertNil(reply.data)
    XCTAssertEqual(reply.error?.code, CopilotXPCServiceError.responseIdentityMismatch.rawValue)
    XCTAssertFalse(reply.error!.localizedDescription.contains(credential))
    XCTAssertFalse(String(describing: reply.error!).contains(credential))
  }

  func testCredentialEchoInHelperResponseIsRejectedBeforeReply() throws {
    let accountID = UUID().uuidString.lowercased()
    let requestID = UUID().uuidString.lowercased()
    let credential = "gho_response-echo-must-not-escape"
    let response = try framedJSON([
      "protocol_version": 2,
      "request_id": requestID,
      "account_id": accountID,
      "organization_id": "org-1",
      "status": "authentication",
      "credential": credential,
    ])
    let service = TriageCopilotXPCService(
      callerValidator: {},
      helperProcess: FrameReturningHelper(response: response)
    )
    let expectation = expectation(description: "credential echo rejection")
    let reply = ReplyCapture(expectation: expectation)

    service.exchange(frame: try authenticatedRequest(
      accountID: accountID,
      requestID: requestID,
      credential: credential
    )) { data, error in
      reply.record(data: data, error: error)
    }

    wait(for: [expectation], timeout: 1)
    XCTAssertNil(reply.data)
    XCTAssertEqual(reply.error?.code, CopilotXPCServiceError.malformedFrame.rawValue)
    XCTAssertFalse(reply.error!.localizedDescription.contains(credential))
  }

  func testAuthenticationFailureMessageIsReplacedBeforeReply() throws {
    let accountID = UUID().uuidString.lowercased()
    let requestID = UUID().uuidString.lowercased()
    let credential = "gho_failure-message-must-not-escape"
    let response = try framedJSON([
      "protocol_version": 2,
      "request_id": requestID,
      "account_id": accountID,
      "organization_id": "org-1",
      "status": "failure",
      "failure": [
        "code": "runtime_error",
        "message": credential,
      ],
    ])
    let service = TriageCopilotXPCService(
      callerValidator: {},
      helperProcess: FrameReturningHelper(response: response)
    )
    let expectation = expectation(description: "safe authentication failure reply")
    let reply = ReplyCapture(expectation: expectation)

    service.exchange(frame: try authenticatedRequest(
      accountID: accountID,
      requestID: requestID,
      credential: credential
    )) { data, error in
      reply.record(data: data, error: error)
    }

    wait(for: [expectation], timeout: 1)
    XCTAssertNil(reply.error)
    let frame = try XCTUnwrap(reply.data)
    XCTAssertFalse(String(data: frame, encoding: .utf8)!.contains(credential))
    let payload = Data(frame.dropFirst(MemoryLayout<UInt32>.size))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    let failure = try XCTUnwrap(object["failure"] as? [String: String])
    XCTAssertEqual(failure["code"], "authentication_failed")
    XCTAssertEqual(
      failure["message"],
      "Copilot authentication could not be completed. Authenticate again after checking your GitHub connection."
    )
  }

  func testSyntheticSessionReusesAuthenticatedEngineForModelsAndAnalyze() throws {
    let harness = SyntheticHelperSessionHarness()
    let accountID = UUID().uuidString.lowercased()
    let process = try makeSyntheticSessionProcess(harness: harness)

    _ = try process.exchange(frame: framedSessionRequest(
      accountID: accountID, organizationID: "org-1", operation: "authenticate"
    ))
    _ = try process.exchange(frame: framedSessionRequest(
      accountID: accountID, organizationID: "org-1", operation: "models"
    ))
    _ = try process.exchange(frame: framedSessionRequest(
      accountID: accountID, organizationID: "org-1", operation: "analyze"
    ))

    XCTAssertEqual(harness.operations, ["authenticate", "models", "analyze"])
  }

  func testSeparateConnectionProcessesKeepAuthenticatedScopesIndependent() throws {
    let firstHarness = SyntheticHelperSessionHarness()
    let secondHarness = SyntheticHelperSessionHarness()
    let accountID = UUID().uuidString.lowercased()
    let first = try makeSyntheticSessionProcess(harness: firstHarness)
    let second = try makeSyntheticSessionProcess(harness: secondHarness)

    _ = try first.exchange(frame: framedSessionRequest(
      accountID: accountID, organizationID: "org-1", operation: "authenticate"
    ))
    _ = try second.exchange(frame: framedSessionRequest(
      accountID: accountID, organizationID: "org-2", operation: "authenticate"
    ))
    _ = try first.exchange(frame: framedSessionRequest(
      accountID: accountID, organizationID: "org-1", operation: "models"
    ))
    _ = try second.exchange(frame: framedSessionRequest(
      accountID: accountID, organizationID: "org-2", operation: "models"
    ))

    XCTAssertEqual(firstHarness.operations, ["authenticate", "models"])
    XCTAssertEqual(secondHarness.operations, ["authenticate", "models"])
  }

  func testSyntheticSessionRejectsScopeRotationThenAllowsReauthentication() throws {
    let harness = SyntheticHelperSessionHarness()
    let accountID = UUID().uuidString.lowercased()
    let process = try makeSyntheticSessionProcess(harness: harness)

    _ = try process.exchange(frame: framedSessionRequest(
      accountID: accountID, organizationID: "org-1", operation: "authenticate"
    ))
    XCTAssertThrowsError(try process.exchange(frame: framedSessionRequest(
      accountID: accountID, organizationID: "org-2", operation: "models"
    ))) { error in
      XCTAssertEqual(error as? CopilotXPCServiceError, .runtimeUnavailable)
    }
    _ = try process.exchange(frame: framedSessionRequest(
      accountID: accountID, organizationID: "org-2", operation: "authenticate"
    ))
    _ = try process.exchange(frame: framedSessionRequest(
      accountID: accountID, organizationID: "org-2", operation: "models"
    ))

    XCTAssertEqual(harness.operations, ["authenticate", "authenticate", "models"])
  }

  func testSyntheticSessionCancellationIdleAndCrashRequireFreshAuthentication() throws {
    let harness = SyntheticHelperSessionHarness()
    let accountID = UUID().uuidString.lowercased()
    let process = try makeSyntheticSessionProcess(harness: harness, maximumIdleInterval: 10)

    _ = try process.exchange(frame: framedSessionRequest(
      accountID: accountID, organizationID: "org-1", operation: "authenticate"
    ))
    process.cancel()
    XCTAssertThrowsError(try process.exchange(frame: framedSessionRequest(
      accountID: accountID, organizationID: "org-1", operation: "analyze"
    ))) { error in
      // Cancel is an immediate session eviction, not a deferred operation
      // marker. A later request must authenticate again rather than inherit
      // a dead helper or its private scratch directory.
      XCTAssertEqual(error as? CopilotXPCServiceError, .runtimeUnavailable)
    }

    _ = try process.exchange(frame: framedSessionRequest(
      accountID: accountID, organizationID: "org-1", operation: "authenticate"
    ))
    harness.advance(by: 11)
    XCTAssertThrowsError(try process.exchange(frame: framedSessionRequest(
      accountID: accountID, organizationID: "org-1", operation: "models"
    ))) { error in
      XCTAssertEqual(error as? CopilotXPCServiceError, .runtimeUnavailable)
    }

    _ = try process.exchange(frame: framedSessionRequest(
      accountID: accountID, organizationID: "org-1", operation: "authenticate"
    ))
    harness.isRunning = false
    XCTAssertThrowsError(try process.exchange(frame: framedSessionRequest(
      accountID: accountID, organizationID: "org-1", operation: "models"
    ))) { error in
      XCTAssertEqual(error as? CopilotXPCServiceError, .runtimeUnavailable)
    }
    harness.isRunning = true
    _ = try process.exchange(frame: framedSessionRequest(
      accountID: accountID, organizationID: "org-1", operation: "authenticate"
    ))
    _ = try process.exchange(frame: framedSessionRequest(
      accountID: accountID, organizationID: "org-1", operation: "models"
    ))

    XCTAssertEqual(
      harness.operations,
      ["authenticate", "authenticate", "shutdown", "authenticate", "authenticate", "models"]
    )
  }

  func testSupervisorForceKillsATermIgnoringHelperWithinBoundedGrace() throws {
    let supervisor = CopilotProcessSupervisor()
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    helper.arguments = ["-c", "trap '' TERM; printf ready; while :; do :; done"]
    let output = Pipe()
    helper.standardOutput = output
    try supervisor.run(helper, launchingWith: { try $0.run() })
    let ready = try output.fileHandleForReading.read(upToCount: 5)
    XCTAssertEqual(ready, Data("ready".utf8))

    let started = Date()
    supervisor.terminateAndReap(helper)

    XCTAssertFalse(helper.isRunning)
    XCTAssertLessThan(Date().timeIntervalSince(started), 2)
  }

  func testCancelEvictsTheExactAuthenticatedScratchDirectoryImmediately() throws {
    let harness = SyntheticHelperSessionHarness()
    let accountID = UUID().uuidString.lowercased()
    let root = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "TriageCopilotXPCCancelCleanup-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let process = try makeSyntheticSessionProcess(harness: harness, root: root)

    _ = try process.exchange(frame: framedSessionRequest(
      accountID: accountID, organizationID: "org-1", operation: "authenticate"
    ))
    let accountDirectory = root.appending(path: "Triage/CopilotXPC/\(accountID)")
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(at: accountDirectory, includingPropertiesForKeys: nil).count,
      1
    )

    process.cancel()

    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(at: accountDirectory, includingPropertiesForKeys: nil),
      []
    )
  }

  private func makeSyntheticSessionProcess(
    harness: SyntheticHelperSessionHarness,
    maximumIdleInterval: TimeInterval = 300,
    root suppliedRoot: URL? = nil
  ) throws -> CopilotHelperProcess {
    let root = suppliedRoot ?? FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "TriageCopilotXPCSyntheticSession-\(UUID().uuidString)")
    if suppliedRoot == nil {
      addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return CopilotHelperProcess(
      bundle: try makeFixtureBundle(helperPermissions: 0o700),
      applicationSupportDirectory: root,
      signatureValidator: { _, _ in },
      runtimeVerifier: TestRuntimeVerifier.trusted(),
      syntheticSessionExchange: { frame in try harness.reply(to: frame) },
      syntheticSessionIsRunning: { harness.isRunning },
      now: { harness.currentDate },
      maximumIdleInterval: maximumIdleInterval
    )
  }

  private func framedSessionRequest(
    accountID: String,
    organizationID: String,
    operation: String
  ) -> Data {
    try! framedJSON([
      "protocol_version": 2,
      "request_id": UUID().uuidString.lowercased(),
      "account_id": accountID,
      "organization_id": organizationID,
      "operation": operation,
    ])
  }

  private func makeFixtureBundle(helperPermissions: NSNumber?) throws -> Bundle {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "TriageCopilotXPCFailClosedTests-\(UUID().uuidString).xpc")
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let contents = directory.appending(path: "Contents")
    try FileManager.default.createDirectory(
      at: contents,
      withIntermediateDirectories: true
    )
    let info = [
      "CFBundleIdentifier": "com.triage.mac.fixture",
      "CFBundleName": "Fixture",
      "CFBundlePackageType": "XPC!",
      "CFBundleVersion": "1"
    ] as [String: Any]
    let infoData = try PropertyListSerialization.data(
      fromPropertyList: info,
      format: .xml,
      options: 0
    )
    try infoData.write(to: contents.appending(path: "Info.plist"), options: .atomic)

    if let helperPermissions {
      let helper = contents.appending(path: "Resources/TriageCopilotHelper")
      try FileManager.default.createDirectory(
        at: helper.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("fixture".utf8).write(to: helper)
      try FileManager.default.setAttributes(
        [.posixPermissions: helperPermissions],
        ofItemAtPath: helper.path
      )
    }
    return try XCTUnwrap(Bundle(url: directory))
  }

  private var fixtureAccountID: String {
    "00000000-0000-4000-8000-000000000002"
  }

  private func framedRequest(accountID: String) -> Data {
    try! framedJSON([
      "protocol_version": 2,
      "request_id": "00000000-0000-4000-8000-000000000001",
      "account_id": accountID,
      "organization_id": "org-1",
      "operation": "authenticate",
      "credential": "test-fixture-credential",
    ])
  }

  private func authenticatedRequest(accountID: String, requestID: String, credential: String) throws -> Data {
    try framedJSON([
      "protocol_version": 2,
      "request_id": requestID,
      "account_id": accountID,
      "organization_id": "org-1",
      "operation": "authenticate",
      "credential": credential,
    ])
  }

  private func framedJSON(_ object: [String: Any]) throws -> Data {
    let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    var length = UInt32(payload.count).bigEndian
    var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
    frame.append(payload)
    return frame
  }
}

private final class RecordingHelperProcess: CopilotHelperProcessing, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var exchangeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func cancel() {}

  func exchange(frame: Data) throws -> Data {
    lock.lock()
    count += 1
    lock.unlock()
    throw CopilotXPCServiceError.helperUnavailable
  }
}

private final class CancellationRecordingHelper: CopilotHelperProcessing, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var cancelCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func cancel() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  func exchange(frame _: Data) throws -> Data {
    throw CopilotXPCServiceError.helperUnavailable
  }
}

private final class FrameReturningHelper: CopilotHelperProcessing, @unchecked Sendable {
  private let response: Data

  init(response: Data) {
    self.response = response
  }

  func cancel() {}

  func exchange(frame _: Data) throws -> Data {
    response
  }
}

private final class TestRuntimeVerifier: CopilotRuntimeTrustVerifying {
  static func trusted() -> TestRuntimeVerifier {
    TestRuntimeVerifier(runtime: .init(
      executableURL: URL(fileURLWithPath: "/private/triage-test-runtime/copilot"),
      lockURL: URL(fileURLWithPath: "/private/triage-test-runtime/.runtime.lock")
    ))
  }

  private let runtime: CopilotTrustedRuntime?
  private let failure: CopilotXPCServiceError?

  init(runtime: CopilotTrustedRuntime) {
    self.runtime = runtime
    failure = nil
  }

  init(failure: CopilotXPCServiceError) {
    runtime = nil
    self.failure = failure
  }

  func withVerifiedRuntime<Result>(
    _ body: (CopilotTrustedRuntime) throws -> Result
  ) throws -> Result {
    if let failure { throw failure }
    return try body(runtime!)
  }
}

/// A deterministic framed engine used only to exercise the Swift session
/// fence. It has no process arguments, environment, runtime path, or
/// credential persistence surface.
private final class SyntheticHelperSessionHarness: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedOperations: [String] = []
  private var running = true
  private var date = Date(timeIntervalSince1970: 1_000)

  var operations: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recordedOperations
  }

  var isRunning: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return running
    }
    set {
      lock.lock()
      running = newValue
      lock.unlock()
    }
  }

  var currentDate: Date {
    lock.lock()
    defer { lock.unlock() }
    return date
  }

  func advance(by interval: TimeInterval) {
    lock.lock()
    date = date.addingTimeInterval(interval)
    lock.unlock()
  }

  func reply(to frame: Data) throws -> Data {
    let payload = Data(frame.dropFirst(MemoryLayout<UInt32>.size))
    let request = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    let operation = try XCTUnwrap(request["operation"] as? String)
    let requestID = try XCTUnwrap(request["request_id"] as? String)
    let accountID = try XCTUnwrap(request["account_id"] as? String)
    let organizationID = try XCTUnwrap(request["organization_id"] as? String)
    lock.lock()
    recordedOperations.append(operation)
    lock.unlock()

    var response: [String: Any] = [
      "protocol_version": 2,
      "request_id": requestID,
      "account_id": accountID,
      "organization_id": organizationID,
      "status": operation == "authenticate" ? "authentication" : operation,
    ]
    if operation == "authenticate" {
      response["authentication"] = [
        "host": "github.com",
        "login": "octocat",
        "auth_type": "token",
        "is_authenticated": true,
      ]
    }
    let responsePayload = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
    var length = UInt32(responsePayload.count).bigEndian
    var responseFrame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
    responseFrame.append(responsePayload)
    return responseFrame
  }
}

private final class ReplyCapture: @unchecked Sendable {
  private let lock = NSLock()
  private let expectation: XCTestExpectation?
  private(set) var data: Data?
  private(set) var error: NSError?

  init(expectation: XCTestExpectation? = nil) {
    self.expectation = expectation
  }

  func record(data: Data?, error: NSError?) {
    lock.lock()
    self.data = data
    self.error = error
    lock.unlock()
    expectation?.fulfill()
  }
}
