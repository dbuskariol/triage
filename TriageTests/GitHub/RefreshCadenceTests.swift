import XCTest
@testable import Triage

final class RefreshCadenceTests: XCTestCase {
    func testJitterIsBoundedAndDeterministic() {
        let cadence = RefreshCadence(baseInterval: 240, maximumJitter: 60)

        XCTAssertEqual(cadence.nextInterval(randomUnit: 0), 240)
        XCTAssertEqual(cadence.nextInterval(randomUnit: 0.5), 270)
        XCTAssertEqual(cadence.nextInterval(randomUnit: 1), 300)
        XCTAssertEqual(cadence.nextInterval(randomUnit: 2), 300)
    }
}
