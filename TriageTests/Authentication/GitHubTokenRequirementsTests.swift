import Foundation
import Testing
@testable import Triage

struct GitHubTokenRequirementsTests {
    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test func fineGrainedLinkRequestsOnlyReadAccessForTheOrganization() {
        let url = GitHubTokenRequirements.fineGrainedTokenURL(organization: " acme ")
        #expect(url.host() == "github.com")
        #expect(url.path() == "/settings/personal-access-tokens/new")
        let query = query(url)
        #expect(query["target_name"] == "acme")
        #expect(query["name"] == "Triage")
        #expect(query["expires_in"] == "90")
        for permission in ["metadata", "issues", "pull_requests", "statuses", "contents", "members"] {
            #expect(query[permission] == "read", "\(permission)")
        }
        let accessLevels = Set(query.filter { !["name", "description", "target_name", "expires_in"].contains($0.key) }.values)
        #expect(accessLevels == ["read"])
    }

    @Test func organizationPermissionsNeedAnOrganization() {
        let query = query(GitHubTokenRequirements.fineGrainedTokenURL(organization: ""))
        #expect(query["target_name"] == nil)
        #expect(query["members"] == nil)
        #expect(query["issues"] == "read")
    }

    @Test func classicLinkSelectsRepoAndReadOrg() {
        let url = GitHubTokenRequirements.classicTokenURL
        #expect(url.path() == "/settings/tokens/new")
        #expect(query(url)["scopes"] == "repo,read:org")
    }
}
