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

    func testApprovedGitHubHostedImagesAreListedButNotLoadedByThePolicy() {
        let source = "![Triage](https://raw.githubusercontent.com/openai/triage/main/icon.png)"

        let sanitized = GitHubMarkdownPolicy.sanitizedSource(source)
        let images = GitHubMarkdownPolicy.hostedImageReferences(in: source)

        XCTAssertTrue(sanitized.contains("GitHub-hosted image available below: Triage"))
        XCTAssertEqual(images, [
            GitHubHostedImageReference(
                url: URL(string: "https://raw.githubusercontent.com/openai/triage/main/icon.png")!,
                altText: "Triage"
            )
        ])
    }

    func testHostedImagePolicyRejectsNonGitHubAndUnsafeAuthorities() {
        XCTAssertTrue(GitHubMarkdownPolicy.permitsGitHubHostedImage(URL(string: "https://raw.githubusercontent.com/openai/triage/main/icon.png")!))
        XCTAssertFalse(GitHubMarkdownPolicy.permitsGitHubHostedImage(URL(string: "https://tracker.example/pixel.png")!))
        XCTAssertFalse(GitHubMarkdownPolicy.permitsGitHubHostedImage(URL(string: "http://raw.githubusercontent.com/openai/triage/main/icon.png")!))
        XCTAssertFalse(GitHubMarkdownPolicy.permitsGitHubHostedImage(URL(string: "https://user@raw.githubusercontent.com/openai/triage/main/icon.png")!))
        XCTAssertFalse(GitHubMarkdownPolicy.permitsImageContentType("image/svg+xml"))
    }

    func testHostedImagePolicyBoundsAndDeduplicatesReferences() {
        let repeated = "![a](https://raw.githubusercontent.com/openai/triage/main/a.png)"
        let source = [repeated, repeated,
                      "![b](https://raw.githubusercontent.com/openai/triage/main/b.png)",
                      "![c](https://raw.githubusercontent.com/openai/triage/main/c.png)",
                      "![d](https://raw.githubusercontent.com/openai/triage/main/d.png)"].joined(separator: " ")

        let images = GitHubMarkdownPolicy.hostedImageReferences(in: source)

        XCTAssertEqual(images.count, GitHubMarkdownPolicy.maximumHostedImageCount)
        XCTAssertEqual(images.map(\.altText), ["a", "b", "c"])
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
