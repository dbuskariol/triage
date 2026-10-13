import Foundation

/// The read-only access Triage needs from a personal access token, and links
/// that open GitHub's token page with it already selected.
enum GitHubTokenRequirements {
    struct Permission: Equatable, Sendable {
        /// GitHub's query parameter for the permission.
        let parameter: String
        let title: String
    }

    /// Classic scopes: `repo` is the only classic scope that can read private
    /// repositories; `read:org` lists organizations and team review requests.
    static let classicScopes = ["repo", "read:org"]

    static let repositoryPermissions = [
        Permission(parameter: "metadata", title: "Metadata"),
        Permission(parameter: "issues", title: "Issues"),
        Permission(parameter: "pull_requests", title: "Pull requests"),
        Permission(parameter: "statuses", title: "Commit statuses"),
        Permission(parameter: "contents", title: "Contents"),
    ]

    static let organizationPermissions = [
        Permission(parameter: "members", title: "Members"),
    ]

    static let tokenName = "Triage"
    static let tokenDescription = "Read-only access for Triage to find the issues and pull requests that involve you. https://github.com/dbuskariol/triage"
    /// Triage warns a week before a token expires; organization policies may shorten this.
    static let fineGrainedExpirationDays = 90

    /// GitHub's fine-grained token form, pre-filled with read-only access to
    /// `organization`. https://docs.github.com/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens
    static func fineGrainedTokenURL(organization: String?) -> URL {
        var components = URLComponents(string: "https://github.com/settings/personal-access-tokens/new")!
        var items = [
            URLQueryItem(name: "name", value: tokenName),
            URLQueryItem(name: "description", value: tokenDescription),
            URLQueryItem(name: "expires_in", value: String(fineGrainedExpirationDays)),
        ]
        let organization = organization?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let organization, !organization.isEmpty {
            items.append(URLQueryItem(name: "target_name", value: organization))
            items += organizationPermissions.map { URLQueryItem(name: $0.parameter, value: "read") }
        }
        items += repositoryPermissions.map { URLQueryItem(name: $0.parameter, value: "read") }
        components.queryItems = items
        return components.url!
    }

    /// GitHub's classic token form with Triage's scopes selected.
    static var classicTokenURL: URL {
        var components = URLComponents(string: "https://github.com/settings/tokens/new")!
        components.queryItems = [
            URLQueryItem(name: "scopes", value: classicScopes.joined(separator: ",")),
            URLQueryItem(name: "description", value: tokenName),
        ]
        return components.url!
    }

    /// Where existing tokens of `kind` are listed, to regenerate one.
    static func tokenSettingsURL(for kind: AuthenticationKind) -> URL {
        kind == .fineGrainedPersonalAccessToken
            ? URL(string: "https://github.com/settings/personal-access-tokens")!
            : URL(string: "https://github.com/settings/tokens")!
    }
}
