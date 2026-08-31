import Foundation

enum GitHubProjectV2NormalizationError: Error, Equatable, Sendable {
    case missingProjectID
    case duplicateProjectID
    case invalidProject
    case missingItemID
    case duplicateItemID
    case invalidItem
    case malformedFieldUnion(String)
    case duplicateFieldName(String)
}

struct GitHubProjectV2Record: Equatable, Sendable {
    let nodeID: GitHubNodeID
    let number: Int
    let title: String
    let description: String?
    let url: URL
    let updatedAt: Date
    let state: GitHubItemState
}

struct GitHubProjectV2ItemRecord: Equatable, Sendable {
    let nodeID: GitHubNodeID
    let projectNodeID: GitHubNodeID
    let contentNodeID: GitHubNodeID?
    let contentKind: GitHubContentKind?
    let updatedAt: Date
    let fieldValues: [GitHubProjectV2FieldValueRecord]
    /// False means field values are diagnostic-only and must not replace prior values.
    let fieldValuesComplete: Bool
}

struct GitHubProjectV2FieldValueRecord: Equatable, Sendable {
    let fieldName: String
    let valueKind: String
    let displayValue: String?
    let dateValue: Date?
    let actorNodeID: GitHubNodeID?
    let context: String
    let isAuthoritative: Bool
}

struct GitHubProjectV2InventoryPayload: Decodable, Sendable {
    let node: Organization?
    let rateLimit: RateLimit
    struct Organization: Decodable, Sendable {
        let id: String
        let projectsV2: Connection
    }
    struct Connection: Decodable, Sendable {
        let nodes: [Project?]
        let pageInfo: PageInfo
    }
    struct Project: Decodable, Sendable {
        let id: String
        let number: Int
        let title: String
        let shortDescription: String?
        let closed: Bool
        let url: URL
        let updatedAt: Date
    }
    struct PageInfo: Decodable, Sendable {
        let hasNextPage: Bool
        let endCursor: String?
    }
    struct RateLimit: Decodable, Sendable {
        let cost: Int
        let remaining: Int
        let resetAt: Date
    }
}

struct GitHubProjectV2ItemPayload: Decodable, Sendable {
    let node: Project?
    let rateLimit: GitHubProjectV2InventoryPayload.RateLimit
    struct Project: Decodable, Sendable {
        let id: String
        let items: Connection
    }
    struct Connection: Decodable, Sendable {
        let nodes: [Item?]
        let pageInfo: PageInfo
    }
    struct Item: Decodable, Sendable {
        let id: String
        let type: String
        let updatedAt: Date
        let content: Content?
    }
    struct Content: Decodable, Sendable {
        let typeName: String
        let id: String?
        enum CodingKeys: String, CodingKey {
            case typeName = "__typename"
            case id
        }
    }
    struct PageInfo: Decodable, Sendable {
        let hasNextPage: Bool
        let endCursor: String?
    }
}

struct GitHubProjectV2FieldValuePayload: Decodable, Sendable {
    let node: Item?
    let rateLimit: GitHubProjectV2InventoryPayload.RateLimit
    struct Item: Decodable, Sendable {
        let id: String
        let fieldValues: Connection
    }
    struct Connection: Decodable, Sendable {
        let nodes: [Value?]
        let pageInfo: PageInfo
    }
    struct Value: Decodable, Sendable {
        let typeName: String
        let field: Field?
        let text: String?
        let number: Double?
        let date: String?
        let name: String?
        let title: String?
        let users: NodeConnection?
        let labels: LabelConnection?
        let milestone: NamedNode?
        let repository: NamedNode?
        let pullRequests: NodeConnection?
        let issue: NamedNode?
        enum CodingKeys: String, CodingKey {
            case typeName = "__typename"
            case field, text, number, date, name, title, users, labels, milestone, repository, pullRequests, issue
        }
    }
    struct Field: Decodable, Sendable {
        let id: String?
        let name: String?
        let dataType: String?
    }
    struct NodeConnection: Decodable, Sendable {
        let nodes: [NamedNode?]
        let pageInfo: NestedPageInfo
    }
    struct LabelConnection: Decodable, Sendable {
        let nodes: [NamedNode?]
        let pageInfo: NestedPageInfo
    }
    struct NamedNode: Decodable, Sendable {
        let id: String?
        let name: String?
        let title: String?
        let nameWithOwner: String?
    }
    struct NestedPageInfo: Decodable, Sendable { let hasNextPage: Bool }
    struct PageInfo: Decodable, Sendable {
        let hasNextPage: Bool
        let endCursor: String?
    }
}

enum GitHubProjectV2Normalizer {
    static func projects(_ values: [GitHubProjectV2InventoryPayload.Project]) throws -> [GitHubProjectV2Record] {
        var identifiers = Set<GitHubNodeID>()
        return try values.map {
            guard let id = GitHubNodeID(rawValue: $0.id) else {
                throw GitHubProjectV2NormalizationError.missingProjectID
            }
            guard identifiers.insert(id).inserted else {
                throw GitHubProjectV2NormalizationError.duplicateProjectID
            }
            guard $0.number > 0, !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  $0.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                  $0.url.scheme == "https", $0.url.host == "github.com"
            else { throw GitHubProjectV2NormalizationError.invalidProject }
            return .init(nodeID: id, number: $0.number, title: $0.title, description: $0.shortDescription,
                         url: $0.url, updatedAt: $0.updatedAt, state: $0.closed ? .closed : .open)
        }
    }

    static func item(
        _ value: GitHubProjectV2ItemPayload.Item,
        projectNodeID: GitHubNodeID,
        fieldValues: [GitHubProjectV2FieldValuePayload.Value]
    ) throws -> GitHubProjectV2ItemRecord {
        guard let id = GitHubNodeID(rawValue: value.id), value.updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw GitHubProjectV2NormalizationError.missingItemID
        }
        let content = try contentMapping(value.content)
        let normalizedFields = try fields(fieldValues)
        return .init(nodeID: id, projectNodeID: projectNodeID, contentNodeID: content.id, contentKind: content.kind,
                     updatedAt: value.updatedAt, fieldValues: normalizedFields,
                     fieldValuesComplete: normalizedFields.allSatisfy(\.isAuthoritative))
    }

    static func fields(_ values: [GitHubProjectV2FieldValuePayload.Value]) throws -> [GitHubProjectV2FieldValueRecord] {
        var names = Set<String>()
        return try values.enumerated().map { index, value in
            let known = [
                "ProjectV2ItemFieldTextValue", "ProjectV2ItemFieldNumberValue", "ProjectV2ItemFieldDateValue",
                "ProjectV2ItemFieldSingleSelectValue", "ProjectV2ItemFieldIterationValue", "ProjectV2ItemFieldUserValue",
                "ProjectV2ItemFieldLabelValue", "ProjectV2ItemFieldMilestoneValue", "ProjectV2ItemFieldRepositoryValue",
                "ProjectV2ItemFieldPullRequestValue", "ProjectV2ItemFieldIssueValue"
            ].contains(value.typeName)
            guard !known || (value.field?.name?.isEmpty == false) else {
                throw GitHubProjectV2NormalizationError.malformedFieldUnion(value.typeName)
            }
            let name = value.field?.name ?? "Unsupported field union \(value.typeName) #\(index + 1)"
            guard names.insert(name).inserted else {
                throw GitHubProjectV2NormalizationError.duplicateFieldName(name)
            }
            let usersComplete = value.users.map {
                !$0.pageInfo.hasNextPage && !$0.nodes.contains(where: { $0 == nil })
            } ?? true
            let labelsComplete = value.labels.map {
                !$0.pageInfo.hasNextPage && !$0.nodes.contains(where: { $0 == nil })
            } ?? true
            let pullRequestsComplete = value.pullRequests.map {
                !$0.pageInfo.hasNextPage && !$0.nodes.contains(where: { $0 == nil })
            } ?? true
            let nestedComplete = usersComplete && labelsComplete && pullRequestsComplete
            let date = value.date.flatMap(parseProjectDate)
            let validDate = value.date == nil || date != nil
            let display: String?
            switch value.typeName {
            case "ProjectV2ItemFieldTextValue": display = value.text
            case "ProjectV2ItemFieldNumberValue": display = value.number.map { String($0) }
            case "ProjectV2ItemFieldDateValue": display = value.date
            case "ProjectV2ItemFieldSingleSelectValue", "ProjectV2ItemFieldIterationValue": display = value.name ?? value.title
            case "ProjectV2ItemFieldUserValue": display = value.users?.nodes.compactMap(\.?).compactMap(\.id).joined(separator: ", ")
            case "ProjectV2ItemFieldLabelValue": display = value.labels?.nodes.compactMap(\.?).compactMap(\.name).joined(separator: ", ")
            case "ProjectV2ItemFieldMilestoneValue": display = value.milestone?.title
            case "ProjectV2ItemFieldRepositoryValue": display = value.repository?.nameWithOwner
            case "ProjectV2ItemFieldPullRequestValue": display = value.pullRequests?.nodes.compactMap(\.?).compactMap(\.id).joined(separator: ", ")
            case "ProjectV2ItemFieldIssueValue": display = value.issue?.id
            default: display = nil
            }
            let actorID = value.users?.nodes.compactMap(\.?).compactMap(\.id).first.flatMap(GitHubNodeID.init(rawValue:))
            let authoritative = known && nestedComplete && validDate
            let context: String
            if !known {
                context = "unsupported union"
            } else if !nestedComplete {
                context = "nested connection incomplete"
            } else if !validDate {
                context = "invalid UTC date-only scalar"
            } else {
                context = value.typeName
            }
            return .init(fieldName: name, valueKind: value.typeName,
                         displayValue: display, dateValue: date, actorNodeID: actorID,
                         context: context, isAuthoritative: authoritative)
        }
    }

    private static func parseProjectDate(_ value: String) -> Date? {
        guard value.count == 10 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            return nil
        }
        return date
    }

    private static func contentMapping(_ content: GitHubProjectV2ItemPayload.Content?) throws -> (id: GitHubNodeID?, kind: GitHubContentKind?) {
        guard let content else { return (nil, nil) }
        switch content.typeName {
        case "Issue":
            guard let id = content.id.flatMap(GitHubNodeID.init(rawValue:)) else {
                throw GitHubProjectV2NormalizationError.invalidItem
            }
            return (id, .issue)
        case "PullRequest":
            guard let id = content.id.flatMap(GitHubNodeID.init(rawValue:)) else {
                throw GitHubProjectV2NormalizationError.invalidItem
            }
            return (id, .pullRequest)
        case "DraftIssue":
            guard let id = content.id.flatMap(GitHubNodeID.init(rawValue:)) else {
                throw GitHubProjectV2NormalizationError.invalidItem
            }
            return (id, .projectDraftIssue)
        default: return (nil, nil)
        }
    }
}
