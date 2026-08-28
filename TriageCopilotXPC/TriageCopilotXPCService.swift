import Foundation

final class TriageCopilotXPCService: NSObject, TriageCopilotHelper {
  private let queue = DispatchQueue(
    label: "com.triage.mac.copilot-xpc",
    qos: .userInitiated
  )

  func exchange(
    frame: Data,
    withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
  ) {
    do {
      try CopilotXPCCallerValidator.validateCurrentConnection()
    } catch let error as CopilotXPCServiceError {
      reply(nil, error.nsError)
      return
    } catch {
      reply(nil, CopilotXPCServiceError.callerNotAuthorized.nsError)
      return
    }

    queue.async {
      do {
        try CopilotXPCFrame.validate(frame, maximumPayloadBytes: 1_048_576)
        let response = try CopilotHelperProcess().exchange(frame: frame)
        try CopilotXPCFrame.validate(response, maximumPayloadBytes: 262_144)
        reply(response, nil)
      } catch let error as CopilotXPCServiceError {
        reply(nil, error.nsError)
      } catch {
        reply(nil, CopilotXPCServiceError.helperUnavailable.nsError)
      }
    }
  }

  func cancelActiveProcess() {
    CopilotHelperProcess.cancelActive()
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

  var nsError: NSError {
    NSError(
      domain: "com.triage.mac.copilot-xpc",
      code: rawValue,
      userInfo: [NSLocalizedDescriptionKey: String(describing: self)]
    )
  }
}
