import Foundation

enum RuntimeOAuthConfigurationError: Error, Equatable, Sendable {
    case missingClientID
    case invalidBrokerURL
    case invalidApplicationVersion
}

struct RuntimeOAuthConfiguration: Sendable {
    let oauth: GitHubOAuthConfiguration
    let brokerURL: URL
    let applicationVersion: String

    init(bundle: Bundle = .main) throws {
        try self.init(
            clientID: bundle.object(forInfoDictionaryKey: "TRIAGE_GITHUB_OAUTH_CLIENT_ID") as? String,
            brokerURLString: bundle.object(forInfoDictionaryKey: "TRIAGE_AUTH_BROKER_URL") as? String,
            applicationVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
    }

    /// This initializer keeps all runtime prerequisites testable without
    /// substituting a process bundle. Production continues to source them
    /// exclusively from the signed application bundle above.
    init(
        clientID: String?,
        brokerURLString: String?,
        applicationVersion: String?
    ) throws {
        guard let clientID,
              !clientID.isEmpty,
              !clientID.hasPrefix("$(")
        else {
            throw RuntimeOAuthConfigurationError.missingClientID
        }
        guard let brokerURLString, let brokerURL = URL(string: brokerURLString) else {
            throw RuntimeOAuthConfigurationError.invalidBrokerURL
        }
        do {
            try AuthBrokerClient.validate(baseURL: brokerURL)
        } catch {
            throw RuntimeOAuthConfigurationError.invalidBrokerURL
        }
        guard let applicationVersion,
              AuthBrokerProtocol.isValidApplicationVersion(applicationVersion)
        else {
            throw RuntimeOAuthConfigurationError.invalidApplicationVersion
        }
        oauth = try GitHubOAuthConfiguration(
            clientID: clientID,
            redirectURI: URL(string: "triage://oauth-callback")!
        )
        self.brokerURL = brokerURL
        self.applicationVersion = applicationVersion
    }
}
