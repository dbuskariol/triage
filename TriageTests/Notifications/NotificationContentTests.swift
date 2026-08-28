import XCTest

@testable import Triage

final class NotificationContentTests: XCTestCase {
  func testNotificationsAreOptInAndGenericByDefault() {
    XCTAssertEqual(
      NotificationPreferences(), NotificationPreferences(isEnabled: false, privacy: .generic))

    let content = NotificationContentFactory.make(
      preferences: .init(),
      presentation: .init(title: "Private issue title", body: "Private comment body")
    )

    XCTAssertEqual(content.title, "New Triage item")
    XCTAssertEqual(content.body, "Open Triage to view it.")
    XCTAssertFalse(content.title.contains("Private"))
    XCTAssertFalse(content.body.contains("Private"))
  }

  func testDetailedContentRequiresExplicitPrivacyChoice() {
    let content = NotificationContentFactory.make(
      preferences: .init(isEnabled: true, privacy: .showDetails),
      presentation: .init(title: "Review requested", body: "Private pull request title")
    )

    XCTAssertEqual(content.title, "Review requested")
    XCTAssertEqual(content.body, "Private pull request title")
  }
}
