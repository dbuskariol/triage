import Foundation

final class TriageCopilotXPCListener: NSObject, NSXPCListenerDelegate {
  // Sessions are keyed and fenced by the helper process itself, rather than
  // by an incidental NSXPC connection. This lets a later models/analyze call
  // reuse the exact authenticated account/organization/runtime session.
  private let helperProcess: any CopilotHelperProcessing = CopilotHelperProcess()

  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    let service = TriageCopilotXPCService(
      callerValidator: CopilotXPCCallerValidator.validateCurrentConnection,
      helperProcess: helperProcess
    )
    newConnection.exportedInterface = NSXPCInterface(with: TriageCopilotHelper.self)
    newConnection.exportedObject = service
    newConnection.invalidationHandler = {
      service.cancelActiveProcess()
    }
    newConnection.resume()
    return true
  }
}
