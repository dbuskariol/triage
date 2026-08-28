import Foundation

/// The only Objective-C-compatible interface exposed by the XPC service.
///
/// Requests and responses are complete length-framed JSON values. The service
/// rejects malformed frames before forwarding the payload to its helper.
@objc protocol TriageCopilotHelper {
  func exchange(
    frame: Data,
    withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
  )
}
