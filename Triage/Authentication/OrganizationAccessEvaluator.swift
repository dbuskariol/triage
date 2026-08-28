import Foundation

enum OrganizationAccessEvaluator {
    static func state(
        statusCode: Int,
        ssoHeader: GitHubSSOHeader?,
        accessRestriction: GitHubAccessRestriction? = nil
    ) -> OrganizationAccessState {
        switch ssoHeader {
        case .authorizationRequired:
            return .ssoAuthorizationRequired
        case .partialResults:
            return .partialSSOAuthorization
        case .malformed:
            return .unknown
        case nil:
            switch accessRestriction {
            case .organizationApprovalRequired:
                return .organizationApprovalRequired
            case .oauthApplicationApprovalRequired:
                return .oauthApplicationApprovalRequired
            case .organizationPolicyBlocked:
                return .organizationPolicyBlocked
            case nil:
                break
            }
            switch statusCode {
            case 200...299: return .available
            case 401: return .credentialExpired
            case 403: return .insufficientPermission
            case 404: return .inaccessible
            default: return .unknown
            }
        }
    }
}
