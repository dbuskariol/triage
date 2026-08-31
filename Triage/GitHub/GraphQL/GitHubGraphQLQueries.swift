import Foundation

enum GitHubGraphQLQueries {
    private static let productionOperationNames = [
        "TriageViewer",
        "TriageHydrateNodes",
        "TriagePullRequestReviewThreads",
        "TriagePullRequestReviewThreadComments",
        "TriageRepositoryDiscussions",
        "TriageDiscussionComments",
        "TriageDiscussionCommentReplies",
        "TriageOrganizationProjectsV2",
        "TriageProjectV2Items",
        "TriageProjectV2ItemFieldValues"
    ]

    /// Every operation permitted to cross the GraphQL transport boundary.
    /// Keep this inventory exhaustive: callers cannot send dynamically-built
    /// documents, even when they are read-only.
    static func registeredQueries() throws -> [GitHubGraphQLQuery] {
        let queries = try [
            viewer(),
            hydrateNodes(),
            pullRequestReviewThreads(),
            pullRequestReviewThreadComments(),
            repositoryDiscussions(),
            discussionComments(),
            discussionCommentReplies(),
            organizationProjectsV2(),
            projectV2Items(),
            projectV2ItemFieldValues()
        ]
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
            ) != nil
            else {
                throw GitHubGraphQLError.invalidQuery
            }
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

    static func hydrateNodes() throws -> GitHubGraphQLQuery {
        try GitHubGraphQLQuery(
        document: """
        query TriageHydrateNodes($ids: [ID!]!) {
          nodes(ids: $ids) {
            ... on Issue {
              __typename id databaseId number title body url state createdAt updatedAt closedAt locked
              author { ...ActorFields }
              repository { ...RepositoryFields }
              assignees(first: 50) { nodes { ...ActorFields } pageInfo { hasNextPage } }
              labels(first: 100) { nodes { id name color } pageInfo { hasNextPage } }
              comments { totalCount }
            }
            ... on PullRequest {
              __typename id databaseId number title body url state createdAt updatedAt closedAt mergedAt isDraft
              mergeable headRefName baseRefName reviewDecision
              author { ...ActorFields }
              repository { ...RepositoryFields }
              assignees(first: 50) { nodes { ...ActorFields } pageInfo { hasNextPage } }
              labels(first: 100) { nodes { id name color } pageInfo { hasNextPage } }
              reviewRequests(first: 50) {
                nodes {
                  requestedReviewer {
                    ... on User { ...ActorFields }
                    ... on Team { id slug avatarUrl }
                  }
                }
                pageInfo { hasNextPage }
              }
              closingIssuesReferences(first: 50) {
                nodes { id }
                pageInfo { hasNextPage }
              }
            }
          }
          rateLimit { cost remaining resetAt }
        }
        fragment ActorFields on Actor { id login avatarUrl }
        fragment RepositoryFields on Repository { id nameWithOwner isPrivate isArchived hasDiscussions url }
        """,
        operationName: "TriageHydrateNodes"
        )
    }

    static func pullRequestReviewThreads() throws -> GitHubGraphQLQuery {
        try GitHubGraphQLQuery(
            document: """
            query TriagePullRequestReviewThreads($pullRequestID: ID!, $after: String) {
              node(id: $pullRequestID) {
                ... on PullRequest {
                  id
                  reviewThreads(first: 50, after: $after) {
                    nodes {
                      id
                      isResolved
                      isOutdated
                    }
                    pageInfo { hasNextPage endCursor }
                  }
                }
              }
              rateLimit { cost remaining resetAt }
            }
            """,
            operationName: "TriagePullRequestReviewThreads"
        )
    }

    static func pullRequestReviewThreadComments() throws -> GitHubGraphQLQuery {
        try GitHubGraphQLQuery(
            document: """
            query TriagePullRequestReviewThreadComments($threadID: ID!, $after: String) {
              node(id: $threadID) {
                ... on PullRequestReviewThread {
                  id
                  comments(first: 50, after: $after) {
                    nodes {
                      id
                      body
                      createdAt
                      updatedAt
                      url
                      author { id login avatarUrl }
                    }
                    pageInfo { hasNextPage endCursor }
                  }
                }
              }
              rateLimit { cost remaining resetAt }
            }
            """,
            operationName: "TriagePullRequestReviewThreadComments"
        )
    }

    static func repositoryDiscussions() throws -> GitHubGraphQLQuery {
        try GitHubGraphQLQuery(
            document: """
            query TriageRepositoryDiscussions($repositoryID: ID!, $after: String) {
              node(id: $repositoryID) {
                ... on Repository {
                  id
                  discussions(first: 50, after: $after, orderBy: { field: UPDATED_AT, direction: DESC }) {
                    nodes {
                      id number title body url createdAt updatedAt closedAt isAnswered
                      category { name }
                      answer { id }
                      comments { totalCount }
                    }
                    pageInfo { hasNextPage endCursor }
                  }
                }
              }
              rateLimit { cost remaining resetAt }
            }
            """,
            operationName: "TriageRepositoryDiscussions"
        )
    }

    static func discussionComments() throws -> GitHubGraphQLQuery {
        try GitHubGraphQLQuery(
            document: """
            query TriageDiscussionComments($discussionID: ID!, $after: String) {
              node(id: $discussionID) {
                ... on Discussion {
                  id
                  comments(first: 50, after: $after) {
                    nodes { id body createdAt updatedAt url author { id login avatarUrl } replies { totalCount } }
                    pageInfo { hasNextPage endCursor }
                  }
                }
              }
              rateLimit { cost remaining resetAt }
            }
            """,
            operationName: "TriageDiscussionComments"
        )
    }

    static func discussionCommentReplies() throws -> GitHubGraphQLQuery {
        try GitHubGraphQLQuery(
            document: """
            query TriageDiscussionCommentReplies($commentID: ID!, $after: String) {
              node(id: $commentID) {
                ... on DiscussionComment {
                  id
                  replies(first: 50, after: $after) {
                    nodes { id body createdAt updatedAt url author { id login avatarUrl } }
                    pageInfo { hasNextPage endCursor }
                  }
                }
              }
              rateLimit { cost remaining resetAt }
            }
            """,
            operationName: "TriageDiscussionCommentReplies"
        )
    }

    static func organizationProjectsV2() throws -> GitHubGraphQLQuery {
        try GitHubGraphQLQuery(
            document: """
            query TriageOrganizationProjectsV2($organizationID: ID!, $after: String) {
              node(id: $organizationID) {
                ... on Organization {
                  id
                  projectsV2(first: 50, after: $after) {
                    nodes { id number title shortDescription closed url updatedAt }
                    pageInfo { hasNextPage endCursor }
                  }
                }
              }
              rateLimit { cost remaining resetAt }
            }
            """,
            operationName: "TriageOrganizationProjectsV2"
        )
    }

    static func projectV2Items() throws -> GitHubGraphQLQuery {
        try GitHubGraphQLQuery(
            document: """
            query TriageProjectV2Items($projectID: ID!, $after: String) {
              node(id: $projectID) {
                ... on ProjectV2 {
                  id
                  items(first: 50, after: $after) {
                    nodes {
                      id type updatedAt
                      content {
                        __typename
                        ... on Issue { id }
                        ... on PullRequest { id }
                        ... on DraftIssue { id }
                      }
                    }
                    pageInfo { hasNextPage endCursor }
                  }
                }
              }
              rateLimit { cost remaining resetAt }
            }
            """,
            operationName: "TriageProjectV2Items"
        )
    }

    static func projectV2ItemFieldValues() throws -> GitHubGraphQLQuery {
        try GitHubGraphQLQuery(
            document: """
            query TriageProjectV2ItemFieldValues($itemID: ID!, $after: String) {
              node(id: $itemID) {
                ... on ProjectV2Item {
                  id
                  fieldValues(first: 50, after: $after) {
                    nodes {
                      __typename
                      ... on ProjectV2ItemFieldTextValue { text field { ...ProjectField } }
                      ... on ProjectV2ItemFieldNumberValue { number field { ...ProjectField } }
                      ... on ProjectV2ItemFieldDateValue { date field { ...ProjectField } }
                      ... on ProjectV2ItemFieldSingleSelectValue { name field { ...ProjectField } }
                      ... on ProjectV2ItemFieldIterationValue { title field { ...ProjectField } }
                      ... on ProjectV2ItemFieldUserValue { users(first: 50) { nodes { id } pageInfo { hasNextPage } } field { ...ProjectField } }
                      ... on ProjectV2ItemFieldLabelValue { labels(first: 50) { nodes { id name } pageInfo { hasNextPage } } field { ...ProjectField } }
                      ... on ProjectV2ItemFieldMilestoneValue { milestone { id title } field { ...ProjectField } }
                      ... on ProjectV2ItemFieldRepositoryValue { repository { id nameWithOwner } field { ...ProjectField } }
                      ... on ProjectV2ItemFieldPullRequestValue { pullRequests(first: 50) { nodes { id } pageInfo { hasNextPage } } field { ...ProjectField } }
                      ... on ProjectV2ItemFieldIssueValue { issue { id } field { ...ProjectField } }
                    }
                    pageInfo { hasNextPage endCursor }
                  }
                }
              }
              rateLimit { cost remaining resetAt }
            }
            fragment ProjectField on ProjectV2FieldConfiguration {
              ... on ProjectV2FieldCommon { id name dataType }
            }
            """,
            operationName: "TriageProjectV2ItemFieldValues"
        )
    }
}
