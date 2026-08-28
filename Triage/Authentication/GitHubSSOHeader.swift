import Foundation

enum GitHubSSOHeader: Equatable, Sendable {
    case authorizationRequired(URL)
    case partialResults(Set<UInt64>)
    case malformed

    init?(value: String?) {
        guard let value, !value.isEmpty else { return nil }

        let components = value
            .split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let directive = components.first else {
            self = .malformed
            return
        }

        switch directive {
        case "required":
            guard let urlValue = components
                .dropFirst()
                .first(where: { $0.hasPrefix("url=") })
                .map({ String($0.dropFirst(4)) }),
                let url = URL(string: urlValue),
                url.scheme == "https",
                url.host == "github.com",
                url.user == nil,
                url.password == nil
            else {
                self = .malformed
                return
            }
            self = .authorizationRequired(url)
        case "partial-results":
            guard let organizationsValue = components
                .dropFirst()
                .first(where: { $0.hasPrefix("organizations=") })
                .map({ $0.dropFirst("organizations=".count) })
            else {
                self = .malformed
                return
            }
            let organizationIDs = organizationsValue
                .split(separator: ",", omittingEmptySubsequences: true)
                .compactMap { UInt64($0) }
            guard !organizationIDs.isEmpty,
                  organizationIDs.count == organizationsValue.split(separator: ",").count
            else {
                self = .malformed
                return
            }
            self = .partialResults(Set(organizationIDs))
        default:
            self = .malformed
        }
    }

    static func combined(_ headers: [GitHubSSOHeader?]) -> GitHubSSOHeader? {
        let values = headers.compactMap { $0 }
        if let authorizationRequired = values.first(where: {
            if case .authorizationRequired = $0 {
                return true
            }
            return false
        }) {
            return authorizationRequired
        }

        let partialOrganizationIDs = values.reduce(into: Set<UInt64>()) { ids, header in
            if case let .partialResults(partialIDs) = header {
                ids.formUnion(partialIDs)
            }
        }
        if !partialOrganizationIDs.isEmpty {
            return .partialResults(partialOrganizationIDs)
        }

        return values.contains(.malformed) ? .malformed : nil
    }

    func scoped(to organizationID: UInt64) -> GitHubSSOHeader? {
        guard case let .partialResults(organizationIDs) = self else {
            return self
        }
        guard organizationIDs.contains(organizationID) else {
            return nil
        }
        return .partialResults([organizationID])
    }
}
