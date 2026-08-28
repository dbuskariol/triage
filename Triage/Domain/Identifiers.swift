import Foundation

protocol TriageIdentifier: Codable, Hashable, Sendable, RawRepresentable, CustomStringConvertible
    where RawValue == String
{
    init?(rawValue: String)
}

extension TriageIdentifier {
    var description: String {
        rawValue
    }
}

private func isValidIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.unicodeScalars.allSatisfy { !$0.properties.isWhitespace }
}

struct AccountID: TriageIdentifier {
    let rawValue: String

    init? (rawValue: String) {
        guard isValidIdentifier(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    static func make() -> Self {
        Self(rawValue: UUID().uuidString.lowercased())!
    }
}

struct OrganizationID: TriageIdentifier {
    let rawValue: String

    init?(rawValue: String) {
        guard isValidIdentifier(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

struct RepositoryID: TriageIdentifier {
    let rawValue: String

    init?(rawValue: String) {
        guard isValidIdentifier(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

struct ActorID: TriageIdentifier {
    let rawValue: String

    init?(rawValue: String) {
        guard isValidIdentifier(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

struct TeamID: TriageIdentifier {
    let rawValue: String

    init?(rawValue: String) {
        guard isValidIdentifier(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

struct GitHubNodeID: TriageIdentifier {
    let rawValue: String

    init?(rawValue: String) {
        guard isValidIdentifier(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

struct GitHubEventID: TriageIdentifier {
    let rawValue: String

    init?(rawValue: String) {
        guard isValidIdentifier(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

struct WorkItemID: TriageIdentifier {
    let rawValue: String

    init?(rawValue: String) {
        guard isValidIdentifier(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    static func make() -> Self {
        Self(rawValue: UUID().uuidString.lowercased())!
    }
}

struct ActionItemID: TriageIdentifier {
    let rawValue: String

    init?(rawValue: String) {
        guard isValidIdentifier(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    static func make() -> Self {
        Self(rawValue: UUID().uuidString.lowercased())!
    }
}

struct EvidenceID: TriageIdentifier {
    let rawValue: String

    init?(rawValue: String) {
        guard isValidIdentifier(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

struct SyncStreamID: TriageIdentifier {
    let rawValue: String

    init?(rawValue: String) {
        guard isValidIdentifier(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

struct AIRequestID: TriageIdentifier {
    let rawValue: String

    init?(rawValue: String) {
        guard isValidIdentifier(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    static func make() -> Self {
        Self(rawValue: UUID().uuidString.lowercased())!
    }
}

struct CredentialID: TriageIdentifier {
    let rawValue: String

    init?(rawValue: String) {
        guard isValidIdentifier(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    static func make() -> Self {
        Self(rawValue: UUID().uuidString.lowercased())!
    }
}

struct CredentialRevision: TriageIdentifier {
    let rawValue: String

    init?(rawValue: String) {
        guard isValidIdentifier(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

struct CapabilityRevision: TriageIdentifier {
    let rawValue: String

    init?(rawValue: String) {
        guard isValidIdentifier(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

struct OAuthState: TriageIdentifier {
    let rawValue: String

    init?(rawValue: String) {
        guard isValidIdentifier(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

struct OAuthCodeVerifier: TriageIdentifier {
    let rawValue: String

    init?(rawValue: String) {
        guard (43...128).contains(rawValue.count),
              rawValue.unicodeScalars.allSatisfy({
                  $0.isASCII
                      && ($0.properties.isAlphabetic
                          || $0.properties.numericType != nil
                          || "-._~".unicodeScalars.contains($0))
              })
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    var description: String {
        "<redacted OAuth PKCE verifier>"
    }
}

struct SecretValue: Codable, Equatable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String {
        "<redacted>"
    }
}
