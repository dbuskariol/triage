import Foundation

enum GitHubProjectV2ClientError: Error, Equatable, Sendable {
    case paginationLoop([GitHubProjectV2RawPage])
    case paginationLimitExceeded([GitHubProjectV2RawPage])
    case queryCostExceeded([GitHubProjectV2RawPage])
    case missingRequestedNode([GitHubProjectV2RawPage])
    case incompleteConnection([GitHubProjectV2RawPage])
    case missingData([GitHubProjectV2RawPage])
    case undecodableResponse([GitHubProjectV2RawPage])
    case partialResponse([GitHubProjectV2RawPage])
    case ssoResponse([GitHubProjectV2RawPage], GitHubSSOHeader)
    case normalizationFailed([GitHubProjectV2RawPage])
    case aggregateLimitExceeded([GitHubProjectV2RawPage])
    case duplicateItem([GitHubProjectV2RawPage])
}

struct GitHubProjectV2RawPage: Equatable, Sendable {
    let endpoint: String
    /// Canonical GraphQL operation and exact variables for this raw page.
    let requestKey: String
    let payload: Data

    init(endpoint: String, requestKey: String? = nil, payload: Data) {
        self.endpoint = endpoint
        self.requestKey = requestKey ?? endpoint
        self.payload = payload
    }
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

    func allProjects(
        organizationNodeID: GitHubNodeID,
        githubOrganizationID: UInt64,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> GitHubProjectV2Inventory {
        try Task.checkCancellation()
        try await validateScope()
        let query = try GitHubGraphQLQueries.organizationProjectsV2()
        var pages = [GitHubProjectV2RawPage]()
        var projects = [GitHubProjectV2InventoryPayload.Project]()
        var after: String?
        var cursors = Set<String>()
        var budget = AggregateBudget()
        while true {
            try await validateScope()
            let response = try await execute(
                query,
                variables: OrganizationProjectsVariables(
                    organizationID: organizationNodeID.rawValue,
                    after: after
                ),
                endpoint: "graphql:TriageOrganizationProjectsV2/organization=\(organizationNodeID.rawValue)",
                requestKey: Self.requestKey(
                    operation: "TriageOrganizationProjectsV2",
                    target: "organization=\(organizationNodeID.rawValue)",
                    after: after
                ),
                page: pages.count + 1,
                priorPages: pages,
                githubOrganizationID: githubOrganizationID,
                as: GitHubProjectV2InventoryPayload.self
            )
            try Task.checkCancellation()
            try await validateScope()
            try validateSSO(
                response.response.metadata.ssoHeader,
                githubOrganizationID: githubOrganizationID,
                pages: pages + [response.raw]
            )
            let payload: GitHubProjectV2InventoryPayload = try completed(response, priorPages: pages)
            try budget.consume(response.raw, cost: payload.rateLimit.cost, priorPages: pages)
            pages.append(response.raw)
            guard let organization = payload.node, organization.id == organizationNodeID.rawValue else {
                throw GitHubProjectV2ClientError.missingRequestedNode(pages)
            }
            guard !organization.projectsV2.nodes.contains(where: { $0 == nil }) else {
                throw GitHubProjectV2ClientError.incompleteConnection(pages)
            }
            projects.append(contentsOf: organization.projectsV2.nodes.compactMap { $0 })
            guard organization.projectsV2.pageInfo.hasNextPage else { break }
            guard pages.count < Self.maximumPages,
                  let cursor = organization.projectsV2.pageInfo.endCursor,
                  cursors.insert(cursor).inserted
            else {
                throw pages.count >= Self.maximumPages
                    ? GitHubProjectV2ClientError.paginationLimitExceeded(pages)
                    : GitHubProjectV2ClientError.paginationLoop(pages)
            }
            after = cursor
        }
        do {
            return .init(projects: try GitHubProjectV2Normalizer.projects(projects), rawPages: pages)
        } catch {
            throw GitHubProjectV2ClientError.normalizationFailed(pages)
        }
    }

    func allItems(
        projectNodeID: GitHubNodeID,
        githubOrganizationID: UInt64,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> GitHubProjectV2Items {
        try Task.checkCancellation()
        try await validateScope()
        let query = try GitHubGraphQLQueries.projectV2Items()
        var rawPages = [GitHubProjectV2RawPage]()
        var items = [GitHubProjectV2ItemPayload.Item]()
        var after: String?
        var cursors = Set<String>()
        var budget = AggregateBudget()
        while true {
            try await validateScope()
            let response = try await execute(
                query,
                variables: ProjectItemsVariables(
                    projectID: projectNodeID.rawValue,
                    after: after
                ),
                endpoint: "graphql:TriageProjectV2Items/project=\(projectNodeID.rawValue)",
                requestKey: Self.requestKey(
                    operation: "TriageProjectV2Items",
                    target: "project=\(projectNodeID.rawValue)",
                    after: after
                ),
                page: rawPages.count + 1,
                priorPages: rawPages,
                githubOrganizationID: githubOrganizationID,
                as: GitHubProjectV2ItemPayload.self
            )
            try Task.checkCancellation()
            try await validateScope()
            try validateSSO(
                response.response.metadata.ssoHeader,
                githubOrganizationID: githubOrganizationID,
                pages: rawPages + [response.raw]
            )
            let payload: GitHubProjectV2ItemPayload = try completed(response, priorPages: rawPages)
            try budget.consume(response.raw, cost: payload.rateLimit.cost, priorPages: rawPages)
            rawPages.append(response.raw)
            guard let project = payload.node, project.id == projectNodeID.rawValue else {
                throw GitHubProjectV2ClientError.missingRequestedNode(rawPages)
            }
            guard !project.items.nodes.contains(where: { $0 == nil }) else {
                throw GitHubProjectV2ClientError.incompleteConnection(rawPages)
            }
            items.append(contentsOf: project.items.nodes.compactMap { $0 })
            guard project.items.pageInfo.hasNextPage else { break }
            guard rawPages.count < Self.maximumPages,
                  let cursor = project.items.pageInfo.endCursor,
                  cursors.insert(cursor).inserted
            else {
                throw rawPages.count >= Self.maximumPages
                    ? GitHubProjectV2ClientError.paginationLimitExceeded(rawPages)
                    : GitHubProjectV2ClientError.paginationLoop(rawPages)
            }
            after = cursor
        }
        let itemIDs = try uniqueItemIDs(items, rawPages: rawPages)
        var normalized = [GitHubProjectV2ItemRecord]()
        for (item, itemID) in zip(items, itemIDs) {
            try Task.checkCancellation()
            let values = try await allFieldValues(
                itemNodeID: itemID,
                githubOrganizationID: githubOrganizationID,
                rawPages: &rawPages,
                budget: &budget,
                validateScope: validateScope
            )
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
        githubOrganizationID: UInt64,
        rawPages: inout [GitHubProjectV2RawPage],
        budget: inout AggregateBudget,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> [GitHubProjectV2FieldValuePayload.Value] {
        let query = try GitHubGraphQLQueries.projectV2ItemFieldValues()
        var values = [GitHubProjectV2FieldValuePayload.Value]()
        var after: String?
        var cursors = Set<String>()
        var pageCount = 0
        while true {
            try await validateScope()
            let response = try await execute(
                query,
                variables: ProjectItemFieldValuesVariables(
                    itemID: itemNodeID.rawValue,
                    after: after
                ),
                endpoint: "graphql:TriageProjectV2ItemFieldValues/item=\(itemNodeID.rawValue)",
                requestKey: Self.requestKey(
                    operation: "TriageProjectV2ItemFieldValues",
                    target: "item=\(itemNodeID.rawValue)",
                    after: after
                ),
                page: pageCount + 1,
                priorPages: rawPages,
                githubOrganizationID: githubOrganizationID,
                as: GitHubProjectV2FieldValuePayload.self
            )
            try Task.checkCancellation()
            try await validateScope()
            try validateSSO(
                response.response.metadata.ssoHeader,
                githubOrganizationID: githubOrganizationID,
                pages: rawPages + [response.raw]
            )
            let payload: GitHubProjectV2FieldValuePayload = try completed(response, priorPages: rawPages)
            try budget.consume(response.raw, cost: payload.rateLimit.cost, priorPages: rawPages)
            rawPages.append(response.raw)
            guard let item = payload.node, item.id == itemNodeID.rawValue else {
                throw GitHubProjectV2ClientError.missingRequestedNode(rawPages)
            }
            guard !item.fieldValues.nodes.contains(where: { $0 == nil }) else {
                throw GitHubProjectV2ClientError.incompleteConnection(rawPages)
            }
            values.append(contentsOf: item.fieldValues.nodes.compactMap { $0 })
            pageCount += 1
            guard item.fieldValues.pageInfo.hasNextPage else { break }
            guard pageCount < Self.maximumPages,
                  let cursor = item.fieldValues.pageInfo.endCursor,
                  cursors.insert(cursor).inserted
            else {
                throw pageCount >= Self.maximumPages
                    ? GitHubProjectV2ClientError.paginationLimitExceeded(rawPages)
                    : GitHubProjectV2ClientError.paginationLoop(rawPages)
            }
            after = cursor
        }
        return values
    }

    private func execute<Value: Decodable & Sendable, Variables: Encodable & Sendable>(
        _ query: GitHubGraphQLQuery,
        variables: Variables,
        endpoint: String,
        requestKey: String,
        page: Int,
        priorPages: [GitHubProjectV2RawPage],
        githubOrganizationID: UInt64,
        as type: Value.Type
    ) async throws -> (response: GitHubGraphQLResponse<Value>, raw: GitHubProjectV2RawPage) {
        let decodingResult = try await client.executePreservingUndecodableResponse(
            query,
            variables: variables,
            as: type
        )
        switch decodingResult {
        case let .response(response):
            return (response, .init(endpoint: "\(endpoint)/page=\(page)", requestKey: requestKey, payload: response.payload))
        case let .undecodable(undecodable):
            let rawPage = GitHubProjectV2RawPage(
                endpoint: "\(endpoint)/page=\(page)",
                requestKey: requestKey,
                payload: undecodable.payload
            )
            if let header = undecodable.metadata.ssoHeader?.scoped(to: githubOrganizationID) {
                throw GitHubProjectV2ClientError.ssoResponse(priorPages + [rawPage], header)
            }
            throw GitHubProjectV2ClientError.undecodableResponse(priorPages + [rawPage])
        }
    }

    private func completed<Value>(
        _ result: (response: GitHubGraphQLResponse<Value>, raw: GitHubProjectV2RawPage),
        priorPages: [GitHubProjectV2RawPage]
    ) throws -> Value {
        let pages = priorPages + [result.raw]
        guard result.response.errors.isEmpty else { throw GitHubProjectV2ClientError.partialResponse(pages) }
        guard let data = result.response.data else { throw GitHubProjectV2ClientError.missingData(pages) }
        guard let cost = (data as? GitHubProjectV2InventoryPayload)?.rateLimit.cost
                ?? (data as? GitHubProjectV2ItemPayload)?.rateLimit.cost
                ?? (data as? GitHubProjectV2FieldValuePayload)?.rateLimit.cost,
              cost >= 0, cost <= Self.maximumQueryCost
        else { throw GitHubProjectV2ClientError.queryCostExceeded(pages) }
        return data
    }

    private func validateSSO(
        _ header: GitHubSSOHeader?,
        githubOrganizationID: UInt64,
        pages: [GitHubProjectV2RawPage]
    ) throws {
        guard let scoped = header?.scoped(to: githubOrganizationID) else { return }
        throw GitHubProjectV2ClientError.ssoResponse(pages, scoped)
    }

    private func uniqueItemIDs(
        _ items: [GitHubProjectV2ItemPayload.Item],
        rawPages: [GitHubProjectV2RawPage]
    ) throws -> [GitHubNodeID] {
        let identifiers = try items.map {
            guard let id = GitHubNodeID(rawValue: $0.id) else {
                throw GitHubProjectV2NormalizationError.missingItemID
            }
            return id
        }
        guard Set(identifiers).count == identifiers.count else {
            throw GitHubProjectV2ClientError.duplicateItem(rawPages)
        }
        return identifiers
    }

    private struct OrganizationProjectsVariables: Encodable, Sendable {
        let organizationID: String
        let after: String?
    }

    private struct ProjectItemsVariables: Encodable, Sendable {
        let projectID: String
        let after: String?
    }

    private struct ProjectItemFieldValuesVariables: Encodable, Sendable {
        let itemID: String
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

    private nonisolated static func requestKey(operation: String, target: String, after: String?) -> String {
        "graphql:\(operation)/\(target)/after=\(cursorComponent(after))"
    }

    private nonisolated static func cursorComponent(_ cursor: String?) -> String {
        guard let cursor else { return "none" }
        return Data(cursor.utf8).base64EncodedString()
    }

    private static let maximumPayloadBytes = 4 * 1_024 * 1_024
}
