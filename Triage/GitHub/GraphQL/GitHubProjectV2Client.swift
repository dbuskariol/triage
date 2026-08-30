import Foundation

enum GitHubProjectV2ClientError: Error, Equatable, Sendable {
    case paginationLoop
    case paginationLimitExceeded
    case queryCostExceeded
    case missingRequestedNode
    case incompleteConnection
    case partialResponse(GitHubProjectV2RawPage)
    case normalizationFailed([GitHubProjectV2RawPage])
    case aggregateLimitExceeded([GitHubProjectV2RawPage])
    case duplicateItem
}

struct GitHubProjectV2RawPage: Equatable, Sendable {
    let endpoint: String
    let payload: Data
}

struct GitHubProjectV2Inventory: Sendable {
    let projects: [GitHubProjectV2Record]
    let rawPages: [GitHubProjectV2RawPage]
}

struct GitHubProjectV2Items: Sendable {
    let items: [GitHubProjectV2ItemRecord]
    let rawPages: [GitHubProjectV2RawPage]
}

actor GitHubProjectV2Client {
    private static let maximumPages = 100
    private static let maximumQueryCost = 500
    private let client: GitHubGraphQLClient

    init(client: GitHubGraphQLClient) {
        self.client = client
    }

    func allProjects(organizationNodeID: GitHubNodeID) async throws -> GitHubProjectV2Inventory {
        let query = try GitHubGraphQLQueries.organizationProjectsV2()
        var pages = [GitHubProjectV2RawPage]()
        var projects = [GitHubProjectV2InventoryPayload.Project]()
        var after: String?
        var cursors = Set<String>()
        var budget = AggregateBudget()
        while true {
            let response = try await execute(
                query, variables: CursorVariables(nodeID: organizationNodeID.rawValue, after: after),
                endpoint: "graphql:TriageOrganizationProjectsV2/organization=\(organizationNodeID.rawValue)",
                page: pages.count + 1, as: GitHubProjectV2InventoryPayload.self
            )
            let payload: GitHubProjectV2InventoryPayload = try completed(response)
            try budget.consume(response.raw, cost: payload.rateLimit.cost, priorPages: pages)
            pages.append(response.raw)
            guard let organization = payload.node, organization.id == organizationNodeID.rawValue else {
                throw GitHubProjectV2ClientError.missingRequestedNode
            }
            guard !organization.projectsV2.nodes.contains(where: { $0 == nil }) else {
                throw GitHubProjectV2ClientError.incompleteConnection
            }
            projects.append(contentsOf: organization.projectsV2.nodes.compactMap { $0 })
            guard organization.projectsV2.pageInfo.hasNextPage else { break }
            guard pages.count < Self.maximumPages,
                  let cursor = organization.projectsV2.pageInfo.endCursor,
                  cursors.insert(cursor).inserted
            else {
                throw pages.count >= Self.maximumPages
                    ? GitHubProjectV2ClientError.paginationLimitExceeded
                    : GitHubProjectV2ClientError.paginationLoop
            }
            after = cursor
        }
        do {
            return .init(projects: try GitHubProjectV2Normalizer.projects(projects), rawPages: pages)
        } catch {
            throw GitHubProjectV2ClientError.normalizationFailed(pages)
        }
    }

    func allItems(projectNodeID: GitHubNodeID) async throws -> GitHubProjectV2Items {
        let query = try GitHubGraphQLQueries.projectV2Items()
        var rawPages = [GitHubProjectV2RawPage]()
        var items = [GitHubProjectV2ItemPayload.Item]()
        var after: String?
        var cursors = Set<String>()
        var budget = AggregateBudget()
        while true {
            let response = try await execute(
                query, variables: CursorVariables(nodeID: projectNodeID.rawValue, after: after),
                endpoint: "graphql:TriageProjectV2Items/project=\(projectNodeID.rawValue)", page: rawPages.count + 1,
                as: GitHubProjectV2ItemPayload.self
            )
            let payload: GitHubProjectV2ItemPayload = try completed(response)
            try budget.consume(response.raw, cost: payload.rateLimit.cost, priorPages: rawPages)
            rawPages.append(response.raw)
            guard let project = payload.node, project.id == projectNodeID.rawValue else {
                throw GitHubProjectV2ClientError.missingRequestedNode
            }
            guard !project.items.nodes.contains(where: { $0 == nil }) else {
                throw GitHubProjectV2ClientError.incompleteConnection
            }
            items.append(contentsOf: project.items.nodes.compactMap { $0 })
            guard project.items.pageInfo.hasNextPage else { break }
            guard rawPages.count < Self.maximumPages,
                  let cursor = project.items.pageInfo.endCursor,
                  cursors.insert(cursor).inserted
            else {
                throw rawPages.count >= Self.maximumPages
                    ? GitHubProjectV2ClientError.paginationLimitExceeded
                    : GitHubProjectV2ClientError.paginationLoop
            }
            after = cursor
        }
        let itemIDs = try uniqueItemIDs(items)
        var normalized = [GitHubProjectV2ItemRecord]()
        for (item, itemID) in zip(items, itemIDs) {
            let values = try await allFieldValues(itemNodeID: itemID, rawPages: &rawPages, budget: &budget)
            do {
                normalized.append(try GitHubProjectV2Normalizer.item(item, projectNodeID: projectNodeID, fieldValues: values))
            } catch {
                throw GitHubProjectV2ClientError.normalizationFailed(rawPages)
            }
        }
        return .init(items: normalized, rawPages: rawPages)
    }

    private func allFieldValues(
        itemNodeID: GitHubNodeID,
        rawPages: inout [GitHubProjectV2RawPage],
        budget: inout AggregateBudget
    ) async throws -> [GitHubProjectV2FieldValuePayload.Value] {
        let query = try GitHubGraphQLQueries.projectV2ItemFieldValues()
        var values = [GitHubProjectV2FieldValuePayload.Value]()
        var after: String?
        var cursors = Set<String>()
        var pageCount = 0
        while true {
            let response = try await execute(
                query, variables: CursorVariables(nodeID: itemNodeID.rawValue, after: after),
                endpoint: "graphql:TriageProjectV2ItemFieldValues/item=\(itemNodeID.rawValue)", page: pageCount + 1,
                as: GitHubProjectV2FieldValuePayload.self
            )
            let payload: GitHubProjectV2FieldValuePayload = try completed(response)
            try budget.consume(response.raw, cost: payload.rateLimit.cost, priorPages: rawPages)
            rawPages.append(response.raw)
            guard let item = payload.node, item.id == itemNodeID.rawValue else {
                throw GitHubProjectV2ClientError.missingRequestedNode
            }
            guard !item.fieldValues.nodes.contains(where: { $0 == nil }) else {
                throw GitHubProjectV2ClientError.incompleteConnection
            }
            values.append(contentsOf: item.fieldValues.nodes.compactMap { $0 })
            pageCount += 1
            guard item.fieldValues.pageInfo.hasNextPage else { break }
            guard pageCount < Self.maximumPages,
                  let cursor = item.fieldValues.pageInfo.endCursor,
                  cursors.insert(cursor).inserted
            else {
                throw pageCount >= Self.maximumPages
                    ? GitHubProjectV2ClientError.paginationLimitExceeded
                    : GitHubProjectV2ClientError.paginationLoop
            }
            after = cursor
        }
        return values
    }

    private func execute<Value: Decodable & Sendable>(
        _ query: GitHubGraphQLQuery,
        variables: CursorVariables,
        endpoint: String,
        page: Int,
        as type: Value.Type
    ) async throws -> (response: GitHubGraphQLResponse<Value>, raw: GitHubProjectV2RawPage) {
        let response = try await client.execute(query, variables: variables, as: type)
        return (response, .init(endpoint: "\(endpoint)/page=\(page)", payload: response.payload))
    }

    private func completed<Value>(_ result: (response: GitHubGraphQLResponse<Value>, raw: GitHubProjectV2RawPage)) throws -> Value {
        guard result.response.errors.isEmpty else { throw GitHubProjectV2ClientError.partialResponse(result.raw) }
        guard let data = result.response.data else { throw GitHubGraphQLError.missingData }
        guard let cost = (data as? GitHubProjectV2InventoryPayload)?.rateLimit.cost
                ?? (data as? GitHubProjectV2ItemPayload)?.rateLimit.cost
                ?? (data as? GitHubProjectV2FieldValuePayload)?.rateLimit.cost,
              cost >= 0, cost <= Self.maximumQueryCost
        else { throw GitHubProjectV2ClientError.queryCostExceeded }
        return data
    }

    private func uniqueItemIDs(_ items: [GitHubProjectV2ItemPayload.Item]) throws -> [GitHubNodeID] {
        let identifiers = try items.map {
            guard let id = GitHubNodeID(rawValue: $0.id) else {
                throw GitHubProjectV2NormalizationError.missingItemID
            }
            return id
        }
        guard Set(identifiers).count == identifiers.count else {
            throw GitHubProjectV2ClientError.duplicateItem
        }
        return identifiers
    }

    private struct CursorVariables: Encodable, Sendable {
        let nodeID: String
        let after: String?
    }

    private struct AggregateBudget {
        private var cost = 0
        private var bytes = 0

        mutating func consume(
            _ page: GitHubProjectV2RawPage,
            cost nextCost: Int,
            priorPages: [GitHubProjectV2RawPage]
        ) throws {
            guard cost <= GitHubProjectV2Client.maximumQueryCost - nextCost,
                  bytes <= GitHubProjectV2Client.maximumPayloadBytes - page.payload.count
            else {
                throw GitHubProjectV2ClientError.aggregateLimitExceeded(priorPages + [page])
            }
            cost += nextCost
            bytes += page.payload.count
        }
    }

    private static let maximumPayloadBytes = 4 * 1_024 * 1_024
}
