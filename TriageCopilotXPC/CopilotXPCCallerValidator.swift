import Foundation
import Security

enum CopilotXPCCallerValidator {
  static func validateCurrentConnection() throws {
    guard let connection = NSXPCConnection.current(),
      let teamIdentifier = Bundle.main.object(
        forInfoDictionaryKey: "TriageExpectedTeamIdentifier"
      ) as? String,
      teamIdentifier.range(
        of: #"^[A-Z0-9]{10}$"#,
        options: .regularExpression
      ) != nil
    else {
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

    let requirementString =
      "anchor apple generic and identifier \"com.triage.mac\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
      let requirement,
      SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    else {
      throw CopilotXPCServiceError.callerNotAuthorized
    }
  }
}
