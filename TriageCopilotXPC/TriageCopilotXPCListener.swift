import Foundation

final class TriageCopilotXPCListener: NSObject, NSXPCListenerDelegate {
  // A connection owns its helper lifecycle.  An invalidation must never tear
  // down a session owned by another account/organization connection.
  private let makeHelperProcess: () -> any CopilotHelperProcessing

  override init() {
    makeHelperProcess = { CopilotHelperProcess() }
    super.init()
  }

  init(makeHelperProcess: @escaping () -> any CopilotHelperProcessing) {
    self.makeHelperProcess = makeHelperProcess
    super.init()
  }

  /// Kept internal for deterministic ownership tests. Each call deliberately
  /// returns a service with a newly-owned helper process.
  func makeServiceForConnection() -> TriageCopilotXPCService {
    TriageCopilotXPCService(
      callerValidator: CopilotXPCCallerValidator.validateCurrentConnection,
      helperProcess: makeHelperProcess()
    )
  }

  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    let service = makeServiceForConnection()
    newConnection.exportedInterface = NSXPCInterface(with: TriageCopilotHelper.self)
    newConnection.exportedObject = service
    newConnection.invalidationHandler = {
      service.cancelActiveProcess()
    }
    newConnection.resume()
    return true
  }
}
