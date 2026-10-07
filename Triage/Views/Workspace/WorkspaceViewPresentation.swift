import Foundation

enum WorkspaceViewPresentation {
    static func priorityLabel(_ priority: Int) -> String {
        switch priority {
        case 70...: "High"
        case 40...: "Medium"
        default: "Low"
        }
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

    static func badges(for entry: TriageEntry) -> [String] {
        guard let facts = entry.item.pullRequest else { return [] }
        var badges: [String] = []
        if facts.checks == .failure || facts.checks == .error { badges.append("Checks failing") }
        if facts.reviewDecision == .changesRequested { badges.append("Changes requested") }
        if facts.mergeable?.uppercased() == "CONFLICTING" { badges.append("Conflicts") }
        if facts.isDraft { badges.append("Draft") }
        return badges
    }

    static func statusLine(_ status: TriageStatus, now: Date = .now) -> String {
        switch status.phase {
        case .searching(let found):
            return "Searching GitHub · \(found) found"
        case .analyzing(let completed, let total):
            return "Copilot is prioritizing · \(completed) of \(total)"
        case .idle:
            guard let refreshed = status.lastRefreshAt else { return "Starting…" }
            return "Updated \(refreshed.formatted(.relative(presentation: .named, unitsStyle: .wide)))"
        }
    }

    static func analysisLabel(_ analysis: AnalysisState, now: Date = .now) -> String? {
        switch analysis {
        case .pending:
            "Analyzing…"
        case .failed(let reason, let retryAt):
            "\(reason) · Retry \(retryAt.formatted(.relative(presentation: .named, unitsStyle: .wide)))"
        case .current:
            nil
        }
    }
}
