import Foundation

enum GitHubTimelineNormalizationError: Error, Equatable, Sendable {
    case invalidEventID
    case invalidEventName
    case invalidEventDate
    case invalidEventPayload
    case eventPayloadTooLarge
    case duplicateEventID
}

struct NormalizedGitHubTimelineEvent: Sendable {
    let id: GitHubEventID
    let kind: TimelineEventKind
    let actor: ActorSummary?
    let occurredAt: Date
    let payload: Data
}

enum GitHubTimelineNormalizer {
    static let maximumEventPayloadBytes = 512 * 1_024

    static func normalize(_ events: [GitHubTimelineEventDTO]) throws -> [NormalizedGitHubTimelineEvent] {
        var normalized = [NormalizedGitHubTimelineEvent]()
        var eventIDs = Set<GitHubEventID>()
        for event in events {
            guard let rawID = event.id, rawID.count <= 512, let id = GitHubEventID(rawValue: rawID) else {
                throw GitHubTimelineNormalizationError.invalidEventID
            }
            guard let rawEvent = event.event,
                  !rawEvent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw GitHubTimelineNormalizationError.invalidEventName
            }
            guard let occurredAt = event.createdAt, occurredAt.timeIntervalSince1970.isFinite else {
                throw GitHubTimelineNormalizationError.invalidEventDate
            }
            guard event.payload.isBounded() else {
                throw GitHubTimelineNormalizationError.invalidEventPayload
            }
            let payload: Data
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                payload = try encoder.encode(event.payload)
            } catch is EncodingError {
                throw GitHubTimelineNormalizationError.invalidEventPayload
            }
            guard payload.count <= maximumEventPayloadBytes else {
                throw GitHubTimelineNormalizationError.eventPayloadTooLarge
            }
            guard eventIDs.insert(id).inserted else {
                throw GitHubTimelineNormalizationError.duplicateEventID
            }
            normalized.append(
                NormalizedGitHubTimelineEvent(
                    id: id,
                    kind: kind(for: rawEvent),
                    actor: actor(from: event.actor),
                    occurredAt: occurredAt,
                    payload: payload
                )
            )
        }
        return normalized
    }

    static func kind(for event: String?) -> TimelineEventKind {
        switch event {
        case "assigned": .assigned
        case "unassigned": .unassigned
        case "commented": .commented
        case "reviewed": .reviewed
        case "review_requested": .reviewRequested
        case "review_request_removed": .reviewRequestRemoved
        case "review_dismissed": .reviewDismissed
        case "labeled": .labeled
        case "unlabeled": .unlabeled
        case "mentioned": .mentioned
        case "cross-referenced": .crossReferenced
        case "committed": .committed
        case "closed": .closed
        case "reopened": .reopened
        case "merged": .merged
        case "transferred": .transferred
        case "added_to_project", "moved_columns_in_project", "project_v2_item_status_changed":
            .addedToProject
        case "removed_from_project": .removedFromProject
        case "milestoned", "demilestoned": .milestoneChanged
        case "renamed": .renamed
        default: .unknown
        }
    }

    private static func actor(from actor: GitHubTimelineEventDTO.Actor?) -> ActorSummary? {
        guard let actor,
              let rawNodeID = actor.nodeID,
              let nodeID = GitHubNodeID(rawValue: rawNodeID),
              let login = actor.login,
              !login.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let id = ActorID(rawValue: rawNodeID)
        else {
            return nil
        }
        return ActorSummary(id: id, nodeID: nodeID, login: login, displayName: nil, avatarURL: nil)
    }
}
