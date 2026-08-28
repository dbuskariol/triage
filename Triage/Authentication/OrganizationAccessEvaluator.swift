import Foundation

enum OrganizationAccessEvaluator {
    static func state(
        statusCode: Int,
        ssoHeader: GitHubSSOHeader?
    ) -> OrganizationAccessState {
        switch ssoHeader {
        case .authorizationRequired:
            .ssoAuthorizationRequired
        case .partialResults:
            .partialSSOAuthorization
        case .malformed:
            .unknown
        case nil:
            switch statusCode {
            case 200...299: .available
            case 401: .credentialExpired
            case 403: .insufficientPermission
            case 404: .inaccessible
            default: .unknown
            }
        }
    }
}
