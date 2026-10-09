import Foundation

enum WorkspaceViewPresentation {
    static func priorityLabel(_ priority: Int) -> String {
        PriorityBand(priority).title
    }

    static func confidenceLabel(_ confidence: Double) -> String {
        switch confidence {
        case 0.8...: "High"
        case 0.5...: "Medium"
        default: "Low"
        }
    }

    static func dispositionLabel(_ disposition: TriageDisposition) -> String {
        switch disposition {
        case .act: "Needs your action"
        case .review: "Worth a look"
        case .wait: "Waiting on others"
        case .none: "No action needed"
        }
    }

    static func badges(for entry: TriageEntry) -> [Badge] {
        guard let facts = entry.item.pullRequest else { return [] }
        var badges: [Badge] = []
        if facts.checks == .failure || facts.checks == .error { badges.append(.checksFailing) }
        if facts.reviewDecision == .changesRequested { badges.append(.changesRequested) }
        if facts.mergeable?.uppercased() == "CONFLICTING" { badges.append(.conflicts) }
        if facts.isDraft { badges.append(.draft) }
        return badges
    }

    /// Pull request states worth flagging in a row. Only blockers get color.
    enum Badge: String, CaseIterable, Sendable {
        case checksFailing = "Checks failing"
        case changesRequested = "Changes requested"
        case conflicts = "Conflicts"
        case draft = "Draft"

        var title: String { rawValue }

        var systemImage: String {
            switch self {
            case .checksFailing: "xmark.circle.fill"
            case .conflicts: "exclamationmark.triangle.fill"
            case .changesRequested: "arrow.uturn.backward.circle.fill"
            case .draft: "pencil.circle"
            }
        }

        var isBlocking: Bool { self != .draft }
        var isSevere: Bool { self == .checksFailing || self == .conflicts }
    }

    /// The window subtitle for a list: search results, else the refresh status.
    static func listSubtitle(search: WorkspaceSearch, resultCount: Int, status: TriageStatus, now: Date) -> String {
        guard search.isActive else { return statusLine(status, now: now) }
        return "\(resultCount) result\(resultCount == 1 ? "" : "s")\(search.scope == .all ? " in all work" : "")"
    }

    static func statusLine(_ status: TriageStatus, now: Date = .now) -> String {
        switch status.phase {
        case .searching(let found):
            return "Searching GitHub · \(found) found"
        case .analyzing(let completed, let total):
            return "Copilot is prioritizing · \(completed) of \(total)"
        case .idle:
            guard let refreshed = status.lastRefreshAt else { return "Starting…" }
            // Under a minute reads as "Just now" rather than a ticking seconds count.
            let handled = status.recentlyHandled > 0 ? " · \(status.recentlyHandled) handled by you" : ""
            if now.timeIntervalSince(refreshed) < 60 { return "Updated just now\(handled)" }
            return "Updated \(RelativeTime.phrase(refreshed))\(handled)"
        }
    }

    static func analysisLabel(_ analysis: AnalysisState, now: Date = .now) -> String? {
        switch analysis {
        case .pending:
            "Waiting for Copilot…"
        case .failed(let reason, let retryAt):
            retryAt <= now
                ? "\(reason) · Retrying now"
                : "\(reason) · Retry \(RelativeTime.phrase(retryAt))"
        case .current:
            nil
        }
    }
}
