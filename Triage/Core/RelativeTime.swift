import Foundation

/// How Triage says when something happened. Timestamps on their own use the
/// compact form (`25m`, `2h`, `5d`, `3mo`); time inside a sentence uses words
/// ("Updated 3 minutes ago").
enum RelativeTime {
    /// `now`, `25m`, `2h`, `5d`, `3mo`, `2y`. Future dates read `in 2h`.
    static func compact(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        let magnitude = abs(seconds)
        let value: String
        switch magnitude {
        case ..<60: return "now"
        case ..<3_600: value = "\(Int(magnitude / 60))m"
        case ..<86_400: value = "\(Int(magnitude / 3_600))h"
        case ..<(30 * 86_400): value = "\(Int(magnitude / 86_400))d"
        case ..<(365 * 86_400): value = "\(Int(magnitude / (30 * 86_400)))mo"
        default: value = "\(Int(magnitude / (365 * 86_400)))y"
        }
        return seconds >= 0 ? value : "in \(value)"
    }

    /// "3 minutes ago", "yesterday", "in 2 hours", for use in sentences.
    static func phrase(_ date: Date, now: Date = .now) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    /// The exact date and time, for help tags behind compact timestamps.
    static func exact(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
