import Foundation

final class TriageCopilotXPCService: NSObject, TriageCopilotHelper, @unchecked Sendable {
  private static let queue = DispatchQueue(
    label: "com.triage.mac.copilot-xpc",
    qos: .userInitiated
  )
  private let callerValidator: () throws -> Void
  private let helperProcess: any CopilotHelperProcessing

  override init() {
    callerValidator = CopilotXPCCallerValidator.validateCurrentConnection
    helperProcess = CopilotHelperProcess()
    super.init()
  }

  init(
    callerValidator: @escaping () throws -> Void,
    helperProcess: any CopilotHelperProcessing
  ) {
    self.callerValidator = callerValidator
    self.helperProcess = helperProcess
    super.init()
  }

  func exchange(
    frame: Data,
    withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
  ) {
    do {
      try callerValidator()
    } catch let error as CopilotXPCServiceError {
      reply(nil, error.nsError)
      return
    } catch {
      reply(nil, CopilotXPCServiceError.callerNotAuthorized.nsError)
      return
    }

    // `frame` is NSXPC-owned and therefore immutable. Do not capture that
    // credential-bearing value into the asynchronous queue. Instead make one
    // forced deep copy with exclusive ownership; the queue captures only the
    // box, which clears its bytes on every completion path.
    let ownedRequestFrame = CopilotOwnedRequestFrame(copying: frame)
    Self.queue.async { [ownedRequestFrame] in
      do {
        try ownedRequestFrame.withWipedFrame { requestFrame in
          let request = try CopilotXPCFrame.validatedRequestHeader(requestFrame)
          var response = try self.helperProcess.exchangeAndWipe(frame: &requestFrame)
          defer { CopilotXPCFrame.wipe(&response) }
          switch try CopilotXPCFrame.responseForForwarding(response, matches: request) {
          case .original:
            reply(response, nil)
          case var .fixedAuthenticationFailure(safeResponse):
            defer { CopilotXPCFrame.wipe(&safeResponse) }
            reply(safeResponse, nil)
          }
        }
      } catch let error as CopilotXPCServiceError {
        reply(nil, error.nsError)
      } catch {
        reply(nil, CopilotXPCServiceError.helperUnavailable.nsError)
      }
    }
  }

  func cancelActiveProcess() {
    helperProcess.cancel()
  }
}

/// Owns a deep copy of a sensitive XPC frame during the queue handoff. The
/// input `Data` belongs to NSXPC and cannot be mutated by this service; this
/// class ensures no immutable app-owned alias is retained after enqueueing.
final class CopilotOwnedRequestFrame: @unchecked Sendable {
  private var storage: Data

  init(copying source: Data) {
    storage = source.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return Data() }
      return Data(bytes: baseAddress, count: bytes.count)
    }
  }

  func withWipedFrame<Result>(
    _ body: (inout Data) throws -> Result
  ) rethrows -> Result {
    defer { CopilotXPCFrame.wipe(&storage) }
    return try body(&storage)
  }

  var isWipedForTesting: Bool {
    storage.isEmpty
  }
}

enum CopilotXPCServiceError: Int, Error {
  case callerNotAuthorized = 1
  case malformedFrame
  case frameTooLarge
  case helperUnavailable
  case helperLocationInvalid
  case helperNotExecutable
  case codeSignatureNotValidated
  case processLaunchFailed
  case processExited
  case operationCancelled
  case operationTimedOut
  case invalidAccountID
  case accountDeletionInProgress
  case runtimeUnavailable
  case runtimeCorrupt
  case responseIdentityMismatch

  var nsError: NSError {
    NSError(
      domain: "com.triage.mac.copilot-xpc",
      code: rawValue,
      userInfo: [NSLocalizedDescriptionKey: String(describing: self)]
    )
  }
}
