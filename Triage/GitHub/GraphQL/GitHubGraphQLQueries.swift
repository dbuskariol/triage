import Foundation

enum GitHubGraphQLQueries {
    private static let productionOperationNames = ["TriageViewer", "TriagePersonalWorkSearch"]

    /// Every operation permitted to cross the GraphQL transport boundary.
    /// Keep this inventory exhaustive: callers cannot send dynamically-built
    /// documents, even when they are read-only.
    static func registeredQueries() throws -> [GitHubGraphQLQuery] {
        let queries = try [viewer(), personalWorkSearch()]
        try validateProductionRegistry(queries)
        return queries
    }

    /// Fail-closed integrity check for the committed GraphQL inventory. The
    /// client runs this before constructing a request, so an accidental query
    /// edit cannot silently reach GitHub.
    static func validateProductionRegistry(_ queries: [GitHubGraphQLQuery]) throws {
        guard queries.map(\.operationName) == productionOperationNames else {
            throw GitHubGraphQLError.invalidQuery
        }
        for query in queries {
            guard query.document.range(
                of: #"\b(mutation|subscription)\b"#,
                options: [.regularExpression, .caseInsensitive]
            ) == nil,
            let declaredOperationName = operationName(in: query.document),
            declaredOperationName == query.operationName,
            query.document.range(
                of: #"\brateLimit\s*\{\s*cost\s+remaining\s+resetAt\s*\}"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil,
            try allExplicitConnectionLimits(in: query.document).allSatisfy({ $0 <= 50 })
            else {
                throw GitHubGraphQLError.invalidQuery
            }
        }
    }

    /// Connections that are not independently traversed must still be small
    /// enough to fail closed through their `hasNextPage` normalizer guards.
    /// Do not increase this without adding a separately cursor-paginated
    /// source contract.
    private static func allExplicitConnectionLimits(in document: String) throws -> [Int] {
        let expression = try NSRegularExpression(pattern: #"\bfirst\s*:\s*([0-9]+)\b"#)
        let range = NSRange(document.startIndex..., in: document)
        return try expression.matches(in: document, range: range).map { match in
            guard let valueRange = Range(match.range(at: 1), in: document),
                  let value = Int(document[valueRange])
            else {
                throw GitHubGraphQLError.invalidQuery
            }
            return value
        }
    }

    private static func operationName(in document: String) -> String? {
        let expression = try? NSRegularExpression(
            pattern: #"^query\s+([_A-Za-z][_0-9A-Za-z]*)"#
        )
        guard let match = expression?.firstMatch(
            in: document,
            range: NSRange(document.startIndex..., in: document)
        ),
        let range = Range(match.range(at: 1), in: document)
        else {
            return nil
        }
        return String(document[range])
    }

    static func viewer() throws -> GitHubGraphQLQuery {
        try GitHubGraphQLQuery(
        document: """
        query TriageViewer {
          viewer {
            id
            login
            name
            avatarUrl
          }

          rateLimit {
            cost
            remaining
            resetAt
          }
        }
        """,
        operationName: "TriageViewer"
        )
    }

    static func personalWorkSearch() throws -> GitHubGraphQLQuery {
        try GitHubGraphQLQuery(
        document: """
        query TriagePersonalWorkSearch($query: String!, $cursor: String, $searchType: SearchType!) {
          search(query: $query, type: $searchType, first: 25, after: $cursor) {
            issueCount
            pageInfo { hasNextPage endCursor }
            nodes {
              __typename
              ... on Issue {
                id number title url state createdAt updatedAt body
                author { login }
                repository { nameWithOwner isArchived }
                labels(first: 20) { nodes { name } }
                assignees(first: 20) { nodes { login } }
                comments(last: 5) { nodes { author { login } createdAt body } }
              }
              ... on PullRequest {
                id number title url state createdAt updatedAt body
                author { login }
                repository { nameWithOwner isArchived }
                labels(first: 20) { nodes { name } }
                assignees(first: 20) { nodes { login } }
                comments(last: 5) { nodes { author { login } createdAt body } }
                isDraft merged reviewDecision mergeable additions deletions
                reviewRequests(first: 20) {
                  nodes {
                    requestedReviewer {
                      __typename
                      ... on User { login }
                      ... on Team { combinedSlug }
                      ... on Bot { login }
                    }
                  }
                }
                latestReviews(first: 10) { nodes { author { login } state submittedAt } }
                commits(last: 1) { nodes { commit { committedDate statusCheckRollup { state } authors(first: 3) { nodes { user { login } } } } } }
                reviewThreads(first: 50) { nodes { isResolved } }
              }
              ... on Discussion {
                id number title url createdAt updatedAt body
                closed
                author { login }
                repository { nameWithOwner isArchived }
                category { name }
                labels(first: 20) { nodes { name } }
                comments(last: 5) { nodes { author { login } createdAt body } }
              }
            }
          }
          rateLimit { cost remaining resetAt }
        }
        """,
        operationName: "TriagePersonalWorkSearch"
        )
    }
}
