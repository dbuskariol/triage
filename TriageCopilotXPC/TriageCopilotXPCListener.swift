import Foundation

final class TriageCopilotXPCListener: NSObject, NSXPCListenerDelegate {
  private let service = TriageCopilotXPCService()

  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    newConnection.exportedInterface = NSXPCInterface(with: TriageCopilotHelper.self)
    newConnection.exportedObject = service
    newConnection.invalidationHandler = { [weak self] in
      self?.service.cancelActiveProcess()
    }
    newConnection.resume()
    return true
  }
}
