import Foundation

struct WorkItemGroupingResult: Sendable {
    let memberGroups: [[GitHubNodeID]]
    let contextualRelations: [WorkRelation]
}

struct WorkItemGrouper: Sendable {
    private static let strongRelations: Set<WorkRelationKind> = [
        .closes,
        .closedBy,
        .linkedPullRequest,
        .containsReview,
        .containsThread,
        .containsComment,
        .projectWrapsContent
    ]

    func group(
        nodeIDs: [GitHubNodeID],
        relations: [WorkRelation],
        decisions: [WorkItemGroupingDecision]
    ) -> WorkItemGroupingResult {
        let nodes = Array(Set(nodeIDs)).sorted { $0.rawValue < $1.rawValue }
        var parent = Dictionary(uniqueKeysWithValues: nodes.map { ($0, $0) })

        func root(_ nodeID: GitHubNodeID) -> GitHubNodeID {
            var node = nodeID
            while parent[node] != node {
                node = parent[node]!
            }
            return node
        }

        func join(_ left: GitHubNodeID, _ right: GitHubNodeID) {
            let leftRoot = root(left)
            let rightRoot = root(right)
            guard leftRoot != rightRoot else { return }
            let first = leftRoot.rawValue < rightRoot.rawValue ? leftRoot : rightRoot
            let second = first == leftRoot ? rightRoot : leftRoot
            parent[second] = first
        }

        for relation in relations {
            guard Self.strongRelations.contains(relation.kind),
                  let object = relation.objectNodeID,
                  parent[relation.subjectNodeID] != nil,
                  parent[object] != nil
            else {
                continue
            }
            join(relation.subjectNodeID, object)
        }
        for decision in decisions where decision.strength != .contextual {
            guard parent[decision.sourceNodeID] != nil,
                  parent[decision.destinationNodeID] != nil
            else {
                continue
            }
            join(decision.sourceNodeID, decision.destinationNodeID)
        }

        let groups = Dictionary(grouping: nodes, by: root)
            .values
            .map { $0.sorted { $0.rawValue < $1.rawValue } }
            .sorted { ($0.first?.rawValue ?? "") < ($1.first?.rawValue ?? "") }

        let contextual = relations.filter {
            !Self.strongRelations.contains($0.kind)
        }
        return WorkItemGroupingResult(memberGroups: groups, contextualRelations: contextual)
    }
}
