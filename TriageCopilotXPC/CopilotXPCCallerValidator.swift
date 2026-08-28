import Foundation
import Security

enum CopilotXPCCallerValidator {
  static func validateCurrentConnection() throws {
    guard let connection = NSXPCConnection.current(),
      let teamIdentifier = Bundle.main.object(
        forInfoDictionaryKey: "TriageExpectedTeamIdentifier"
      ) as? String,
      !teamIdentifier.isEmpty
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
      "identifier \"com.triage.mac\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
      let requirement,
      SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    else {
      throw CopilotXPCServiceError.callerNotAuthorized
    }
  }
}
