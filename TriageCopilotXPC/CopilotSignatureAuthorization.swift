import Foundation

/// Decides whether a signature may cross the Copilot helper boundary.
/// Release builds never pass `acceptAdHocDebugCaller`. A Debug build signed
/// with an Apple team still requires that team.
enum CopilotSignatureAuthorization {
  static func allows(
    identifier: String?,
    teamIdentifier: String?,
    isAdHoc: Bool,
    expectedIdentifier: String,
    expectedTeamIdentifier: String?,
    acceptAdHocDebugCaller: Bool
  ) -> Bool {
    guard identifier == expectedIdentifier else { return false }
    if isTeamIdentifier(expectedTeamIdentifier) {
      return !isAdHoc && teamIdentifier == expectedTeamIdentifier
    }
    return acceptAdHocDebugCaller && isAdHoc
  }

  static func isTeamIdentifier(_ value: String?) -> Bool {
    guard let value else { return false }
    return value.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil
  }
}
