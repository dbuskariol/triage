import XCTest
@testable import Triage

final class GitHubMarkdownPolicyTests: XCTestCase {
    func testSanitizerOmitsRemoteImagesAndExecutableElements() {
        let source = "![pixel](https://tracker.example/pixel.png)<script>alert(1)</script><img src=\"https://tracker.example/second.png\">Text"

        let sanitized = GitHubMarkdownPolicy.sanitizedSource(source)

        XCTAssertFalse(sanitized.contains("alert"))
        XCTAssertFalse(sanitized.contains("tracker.example"))
        XCTAssertTrue(sanitized.contains("remote image omitted"))
        XCTAssertTrue(sanitized.contains("Text"))
    }

    func testSanitizerOmitsUnclosedExecutableMarkupAndItsExternalURL() {
        let source = "Before<script src=\"https://tracker.example/collect.js\">alert(1)"

        let sanitized = GitHubMarkdownPolicy.sanitizedSource(source)

        XCTAssertFalse(sanitized.contains("<script"))
        XCTAssertFalse(sanitized.contains("tracker.example"))
        XCTAssertTrue(sanitized.contains("embedded content omitted"))
    }

    func testOnlyHTTPSExternalLinksArePermitted() {
        XCTAssertTrue(GitHubMarkdownPolicy.permitsExternalNavigation(to: URL(string: "https://github.com/openai")!))
        XCTAssertFalse(GitHubMarkdownPolicy.permitsExternalNavigation(to: URL(string: "http://github.com/openai")!))
        XCTAssertFalse(GitHubMarkdownPolicy.permitsExternalNavigation(to: URL(string: "file:///tmp/example")!))
    }

    func testSanitizerBoundsUntrustedSourceSize() {
        let source = String(repeating: "a", count: GitHubMarkdownPolicy.maximumSourceCharacters + 5)
        XCTAssertEqual(GitHubMarkdownPolicy.sanitizedSource(source).count, GitHubMarkdownPolicy.maximumSourceCharacters)
    }

    func testSanitizerStripsHTMLDestinationsButPreservesMarkdownLinksAndTaskState() {
        let source = """
        <a href="https://tracker.example/click">tracked</a> [safe](https://github.com/openai)
        - [ ] review
        - [x] shipped
        """

        let sanitized = GitHubMarkdownPolicy.sanitizedSource(source)

        XCTAssertFalse(sanitized.contains("tracker.example"))
        XCTAssertTrue(sanitized.contains("tracked"))
        XCTAssertTrue(sanitized.contains("[safe](https://github.com/openai)"))
        XCTAssertTrue(sanitized.contains("To do: review"))
        XCTAssertTrue(sanitized.contains("Completed: shipped"))
    }
}
