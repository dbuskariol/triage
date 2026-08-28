import Foundation

enum RuntimeOAuthConfigurationError: Error, Equatable, Sendable {
    case missingClientID
    case invalidBrokerURL
}

struct RuntimeOAuthConfiguration: Sendable {
    let oauth: GitHubOAuthConfiguration
    let brokerURL: URL

    init(bundle: Bundle = .main) throws {
        guard let clientID = bundle.object(forInfoDictionaryKey: "TRIAGE_GITHUB_OAUTH_CLIENT_ID") as? String,
              !clientID.isEmpty,
              !clientID.hasPrefix("$(")
        else {
            throw RuntimeOAuthConfigurationError.missingClientID
        }
        guard let brokerURLString = bundle.object(forInfoDictionaryKey: "TRIAGE_AUTH_BROKER_URL") as? String,
              let brokerURL = URL(string: brokerURLString),
              brokerURL.scheme == "https",
              brokerURL.host != nil
        else {
            throw RuntimeOAuthConfigurationError.invalidBrokerURL
        }
        oauth = try GitHubOAuthConfiguration(
            clientID: clientID,
            redirectURI: URL(string: "triage://oauth-callback")!
        )
        self.brokerURL = brokerURL
    }
}
