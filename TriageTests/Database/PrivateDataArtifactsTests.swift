import XCTest
@testable import Triage

final class PrivateDataArtifactsTests: XCTestCase {
    func testArtifactsAreAccountScopedAndEnumerateEveryAppOwnedLocation() {
        let artifacts = AccountPrivateDataArtifacts(
            accountID: AccountID(rawValue: "account-1")!,
            applicationSupportDirectory: URL(fileURLWithPath: "/support"),
            cachesDirectory: URL(fileURLWithPath: "/cache")
        )

        XCTAssertEqual(artifacts.artifacts.count, PrivateDataArtifactKind.allCases.count)
        XCTAssertTrue(artifacts.artifacts.allSatisfy { $0.url.path.contains("account-1") })
        XCTAssertTrue(artifacts.artifacts.contains { $0.kind == .vault })
        XCTAssertTrue(artifacts.artifacts.contains { $0.kind == .copilotState })
    }
}
