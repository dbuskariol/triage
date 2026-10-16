import Foundation
import Security

enum CopilotXPCCallerValidator {
  static let applicationIdentifier = "com.triage.mac"

  static func validateCurrentConnection() throws {
    guard let connection = NSXPCConnection.current() else {
      throw CopilotXPCServiceError.callerNotAuthorized
    }
    let attributes: CFDictionary = [
      kSecGuestAttributePid: NSNumber(value: connection.processIdentifier)
    ] as CFDictionary
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
      let code
    else {
      throw CopilotXPCServiceError.callerNotAuthorized
    }

    let expectedTeam = Bundle.main.object(forInfoDictionaryKey: "TriageExpectedTeamIdentifier") as? String
    #if DEBUG
    if try allowsUnsignedDebugCaller(code, expectedTeamIdentifier: expectedTeam) {
      return
    }
    #endif
    let teamIdentifier = try validatedTeamIdentifier(expectedTeam)
    try requireAppleTeam(code, teamIdentifier: teamIdentifier)
  }

  #if DEBUG
  /// A local Debug build with no Apple team is ad-hoc. Accept only this app.
  /// A Debug build that has a team still uses the Apple team requirement.
  private static func allowsUnsignedDebugCaller(
    _ code: SecCode,
    expectedTeamIdentifier: String?
  ) throws -> Bool {
    let facts = try signatureFacts(code)
    return CopilotSignatureAuthorization.allows(
      identifier: facts.identifier,
      teamIdentifier: facts.teamIdentifier,
      isAdHoc: facts.isAdHoc,
      expectedIdentifier: applicationIdentifier,
      expectedTeamIdentifier: expectedTeamIdentifier,
      acceptAdHocDebugCaller: true
    )
  }
  #endif

  private static func requireAppleTeam(_ code: SecCode, teamIdentifier: String) throws {
    let requirementString =
      "anchor apple generic and identifier \"\(applicationIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
      let requirement,
      SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    else {
      throw CopilotXPCServiceError.callerNotAuthorized
    }
  }

  private static func signatureFacts(_ code: SecCode) throws -> (
    identifier: String?, teamIdentifier: String?, isAdHoc: Bool
  ) {
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
      throw CopilotXPCServiceError.callerNotAuthorized
    }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(
      staticCode,
      SecCSFlags(rawValue: kSecCSSigningInformation),
      &information
    ) == errSecSuccess,
      let info = information as? [CFString: Any]
    else {
      throw CopilotXPCServiceError.callerNotAuthorized
    }
    let flags = info[kSecCodeInfoFlags] as? UInt32 ?? 0
    return (
      info[kSecCodeInfoIdentifier] as? String,
      info[kSecCodeInfoTeamIdentifier] as? String,
      flags & 0x2 != 0
    )
  }

  static func validatedTeamIdentifier(_ value: String?) throws -> String {
    guard let value,
      value.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil
    else {
      throw CopilotXPCServiceError.callerNotAuthorized
    }
    return value
  }
}
