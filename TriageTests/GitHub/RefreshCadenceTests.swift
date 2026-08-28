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

    func testInactiveAccountCadenceUsesLowerPriorityInterval() {
        XCTAssertEqual(RefreshCadence.inactiveAccount.nextInterval(randomUnit: 0), 1_200)
        XCTAssertEqual(RefreshCadence.inactiveAccount.nextInterval(randomUnit: 1), 1_500)
    }

    func testCapabilityProbeRunsNoMoreThanDaily() {
        XCTAssertEqual(RefreshCadence.dailyCapabilityProbe.nextInterval(randomUnit: 0), 86_400)
        XCTAssertEqual(RefreshCadence.dailyCapabilityProbe.nextInterval(randomUnit: 1), 90_000)
    }
}
