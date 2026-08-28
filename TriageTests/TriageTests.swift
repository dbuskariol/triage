import XCTest
@testable import Triage

final class TriageTests: XCTestCase {
    func testUpdateIntervalsRemainStable() {
        XCTAssertEqual(AppUpdateCheckInterval.daily.rawValue, 86_400)
        XCTAssertEqual(AppUpdateCheckInterval.weekly.rawValue, 604_800)
        XCTAssertEqual(AppUpdateCheckInterval.daily.title, "Daily")
        XCTAssertEqual(AppUpdateCheckInterval.weekly.title, "Weekly")
    }

    func testMetadataFormatsVersionAndBuild() {
        let metadata = AppMetadata(bundle: .main)
        XCTAssertEqual(metadata.displayVersion, "\(metadata.version) (\(metadata.build))")
        XCTAssertFalse(metadata.bundleIdentifier.isEmpty)
    }
}
