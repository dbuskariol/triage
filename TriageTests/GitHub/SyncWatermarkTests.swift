import XCTest
@testable import Triage

final class SyncWatermarkTests: XCTestCase {
    func testFirstSyncUsesConfiguredHistoricalStart() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            SyncWatermark(lastSuccessfulServerObservedAt: nil).searchStart(defaultStart: start),
            start
        )
    }

    func testIncrementalSyncOverlapsByTenMinutes() {
        let lastSuccess = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(
            SyncWatermark(lastSuccessfulServerObservedAt: lastSuccess).searchStart(defaultStart: .distantPast),
            Date(timeIntervalSince1970: 9_400)
        )
    }
}
