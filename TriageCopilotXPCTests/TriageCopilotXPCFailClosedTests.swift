import Foundation
import XCTest

final class TriageCopilotXPCFailClosedTests: XCTestCase {
  func testMissingHelperRejectsBeforeProcessLaunch() throws {
    let bundle = try makeFixtureBundle(helperPermissions: nil)
    var didLaunch = false
    let process = CopilotHelperProcess(
      bundle: bundle,
      processLauncher: { _ in didLaunch = true }
    )

    XCTAssertThrowsError(try process.exchange(frame: Data())) { error in
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
      processLauncher: { _ in didLaunch = true }
    )

    XCTAssertThrowsError(try process.exchange(frame: Data())) { error in
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
      processLauncher: { _ in didLaunch = true }
    )

    XCTAssertThrowsError(try process.exchange(frame: Data())) { error in
      XCTAssertEqual(error as? CopilotXPCServiceError, .codeSignatureNotValidated)
    }
    XCTAssertFalse(didLaunch)
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
