import Foundation

/// Why an item ranks where it does: Copilot's assessment, a few fixed,
/// explainable factors, and the user's Rank rules.
///
/// `total = clamp(0…100, copilot + factors (±20) + rules (±40))`
struct PriorityBreakdown: Equatable, Sendable {
    struct Part: Equatable, Sendable, Identifiable {
        let title: String
        let points: Int
        var id: String { title }
    }

    static let maximumFactorAdjustment = 20

    /// Copilot's priority before anything else.
    let copilot: Int
    let factors: [Part]
    let rules: [Part]

    var factorAdjustment: Int {
        max(-Self.maximumFactorAdjustment, min(Self.maximumFactorAdjustment, factors.reduce(0) { $0 + $1.points }))
    }

    var ruleAdjustment: Int {
        max(-TriageRules.maximumRankAdjustment, min(TriageRules.maximumRankAdjustment, rules.reduce(0) { $0 + $1.points }))
    }

    var total: Int { min(100, max(0, copilot + factorAdjustment + ruleAdjustment)) }

    var isAdjusted: Bool { total != copilot }

    /// The fixed factors for `entry`. Weights live here, are tested, and are
    /// never user-editable; users shape ranking with Rank rules instead.
    static func factors(for entry: TriageEntry, viewer: String, now: Date) -> [Part] {
        let item = entry.item
        var parts: [Part] = []
        switch item.reviewRequestKind(viewer: viewer) {
        case .direct?: parts.append(Part(title: "Review requested from you directly", points: 6))
        case .team?: parts.append(Part(title: "Review requested only through a team", points: -6))
        case nil: break
        }
        let viewerLast = item.latestViewerActivity(viewer: viewer)
        if entry.decision?.disposition.isInbox == true,
           let othersLast = item.latestActivity(excluding: viewer), othersLast > (viewerLast ?? .distantPast) {
            let days = WorkInsights.days(since: othersLast, now: now)
            if days > 7 {
                parts.append(Part(title: "Waiting on you for \(days) days", points: 8))
            } else if days > 3 {
                parts.append(Part(title: "Waiting on you for \(days) days", points: 4))
            }
        }
        if item.relationships.contains(.authored), item.pullRequest?.hasFailingRequiredCheck == true {
            parts.append(Part(title: "A required check is failing on your pull request", points: 6))
        }
        if item.mentionsViewer(after: viewerLast ?? .distantPast, viewer: viewer) {
            parts.append(Part(title: "Mentioned since you last acted", points: 5))
        }
        if now.timeIntervalSince(item.updatedAt) >= 30 * 86_400 {
            parts.append(Part(title: "No activity for over a month", points: -6))
        }
        return parts
    }
}

extension PersonalWorkItem {
    /// The viewer's newest comment, review, or pushed commit.
    func latestViewerActivity(viewer: String) -> Date? {
        guard !viewer.isEmpty else { return nil }
        func isViewer(_ login: String) -> Bool { login.caseInsensitiveCompare(viewer) == .orderedSame }
        var dates = recentActivity.filter { isViewer($0.author) }.map(\.createdAt)
        if let facts = pullRequest {
            dates += facts.latestReviews.filter { isViewer($0.author) }.compactMap(\.submittedAt)
            if let at = facts.lastCommitAt, (facts.lastCommitAuthors ?? []).contains(where: isViewer) { dates.append(at) }
        }
        return dates.max()
    }

    /// Whether someone else @mentioned `viewer` after `date`.
    func mentionsViewer(after date: Date, viewer: String) -> Bool {
        guard !viewer.isEmpty else { return false }
        let mention = "@\(viewer)"
        return recentActivity.contains { comment in
            guard comment.createdAt > date, comment.author.caseInsensitiveCompare(viewer) != .orderedSame,
                  let range = comment.excerpt.range(of: mention, options: .caseInsensitive) else { return false }
            // `@me` must not match `@meg`.
            return comment.excerpt[range.upperBound...].first.map { !($0.isLetter || $0.isNumber || $0 == "-") } ?? true
        }
    }
}
