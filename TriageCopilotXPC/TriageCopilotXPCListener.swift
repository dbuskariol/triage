import Foundation

final class TriageCopilotXPCListener: NSObject, NSXPCListenerDelegate {
  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    let service = TriageCopilotXPCService()
    newConnection.exportedInterface = NSXPCInterface(with: TriageCopilotHelper.self)
    newConnection.exportedObject = service
    newConnection.invalidationHandler = {
      service.cancelActiveProcess()
    }
    newConnection.resume()
    return true
  }
}
