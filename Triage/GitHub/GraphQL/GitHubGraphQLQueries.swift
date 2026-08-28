import Foundation

enum GitHubGraphQLQueries {
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
              __typename id databaseId number title body url state createdAt updatedAt closedAt
              author { ...ActorFields }
              repository { ...RepositoryFields }
              assignees(first: 50) { nodes { ...ActorFields } }
              labels(first: 100) { nodes { id name color } }
            }
            ... on PullRequest {
              __typename id databaseId number title body url state createdAt updatedAt closedAt mergedAt isDraft
              author { ...ActorFields }
              repository { ...RepositoryFields }
              assignees(first: 50) { nodes { ...ActorFields } }
              labels(first: 100) { nodes { id name color } }
              reviewRequests(first: 50) { nodes { requestedReviewer { ... on User { ...ActorFields } } } }
              closingIssuesReferences(first: 50) { nodes { id } }
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
}
