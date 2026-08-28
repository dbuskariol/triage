import Foundation

struct SyncWatermark: Codable, Equatable, Sendable {
    static let overlap: TimeInterval = 10 * 60

    let lastSuccessfulServerObservedAt: Date?

    func searchStart(defaultStart: Date) -> Date {
        guard let lastSuccessfulServerObservedAt else { return defaultStart }
        return lastSuccessfulServerObservedAt.addingTimeInterval(-Self.overlap)
    }

    func advancing(afterSuccessfulSnapshotAt snapshotAt: Date) -> SyncWatermark {
        SyncWatermark(lastSuccessfulServerObservedAt: snapshotAt)
    }
}
