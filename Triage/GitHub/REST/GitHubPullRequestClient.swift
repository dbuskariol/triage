import Foundation

enum GitHubRepositoryPathError: Error, Equatable, Sendable {
    case invalidOwner
    case invalidRepository
    case invalidPullRequestNumber
}

enum GitHubPullRequestClientError: Error, Equatable, Sendable {
    case paginationLoop
    case paginationLimitExceeded
    case invalidPaginationLink
    case unexpectedConditionalResponse
    case pageObjectLimitExceeded
}

struct GitHubRepositoryPath: Sendable {
    let owner: String
    let repository: String

    init(owner: String, repository: String) throws {
        guard Self.isPathComponent(owner) else { throw GitHubRepositoryPathError.invalidOwner }
        guard Self.isPathComponent(repository) else { throw GitHubRepositoryPathError.invalidRepository }
        self.owner = owner
        self.repository = repository
    }

    var path: String { "/repos/\(owner)/\(repository)" }

    private static func isPathComponent(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100
            && value.unicodeScalars.allSatisfy {
                $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil || "-._".unicodeScalars.contains($0))
            }
    }
}

struct GitHubPullRequestReviewDTO: Codable, Sendable {
    let id: UInt64
    let nodeID: String
    let state: String
    let body: String?
    let submittedAt: Date?
    let user: Author? = nil

    struct Author: Codable, Sendable {
        let nodeID: String?
        let login: String?

        enum CodingKeys: String, CodingKey {
            case nodeID = "node_id"
            case login
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case nodeID = "node_id"
        case state, body, user
        case submittedAt = "submitted_at"
    }
}

struct GitHubRequestedReviewersDTO: Codable, Sendable {
    let users: [Reviewer]
    let teams: [Reviewer]

    struct Reviewer: Codable, Sendable {
        let nodeID: String
        let login: String?
        let slug: String?

        enum CodingKeys: String, CodingKey {
            case nodeID = "node_id"
            case login, slug
        }
    }
}

struct GitHubPullRequestReviewInventory: Sendable {
    let reviews: [GitHubPullRequestReviewDTO]
    let pages: [GitHubPage<GitHubPullRequestReviewDTO>]
    let ssoHeaders: [GitHubSSOHeader]

    var ssoHeader: GitHubSSOHeader? {
        GitHubSSOHeader.combined(ssoHeaders)
    }
}

/// Header-free raw evidence returned to the synchronizer. It is not durable
/// until the caller binds it to its exact synchronization scope.
struct GitHubPullRequestReviewRawPage: Sendable {
    let requestKey: String
    let ordinal: Int
    let payload: Data
    let eTag: String?
    let lastModified: String?
    let ssoHeader: GitHubSSOHeader?
}

enum GitHubPullRequestReviewTerminalFailure: Error, Sendable {
    case github(GitHubFailure)
    case transport
    case malformedResponse
    case pagination
    case normalization

    var ssoHeader: GitHubSSOHeader? {
        if case let .github(failure) = self { return failure.ssoHeader }
        return nil
    }
}

struct GitHubPullRequestReviewFetchFailure: Error, Sendable {
    let terminalRequestKey: String
    let rawPages: [GitHubPullRequestReviewRawPage]
    let terminalFailure: GitHubPullRequestReviewTerminalFailure

    var ssoHeaders: [GitHubSSOHeader] {
        rawPages.compactMap(\.ssoHeader)
            + [terminalFailure.ssoHeader].compactMap { $0 }
    }
}

enum GitHubPullRequestReviewFetchResult: Sendable {
    case inventory(GitHubPullRequestReviewInventory, [GitHubPullRequestReviewRawPage])
    case notModified(ssoHeader: GitHubSSOHeader?)
    case failure(GitHubPullRequestReviewFetchFailure)
}

enum GitHubRequestedReviewersFetchResult: Sendable {
    case response(GitHubResponse<GitHubRequestedReviewersDTO>)
    case notModified(ssoHeader: GitHubSSOHeader?)
    case failure(GitHubPullRequestReviewFetchFailure)
}

actor GitHubPullRequestClient {
    private static let maximumReviewPages = 100
    private static let maximumRequestedReviewerResponseBytes = 256 * 1_024

    private let client: GitHubRESTClient

    init(client: GitHubRESTClient) {
        self.client = client
    }

    func reviews(
        repository: GitHubRepositoryPath,
        number: Int
    ) async throws -> GitHubPage<GitHubPullRequestReviewDTO> {
        guard number > 0 else { throw GitHubRepositoryPathError.invalidPullRequestNumber }
        let page = try await client.getPage(
            GitHubPullRequestReviewDTO.self,
            request: GitHubRESTRequest(
                path: "\(repository.path)/pulls/\(number)/reviews",
                query: [URLQueryItem(name: "per_page", value: "100")]
            )
        )
        try Self.validatePageObjectCount(page)
        return page
    }

    func allReviews(
        repository: GitHubRepositoryPath,
        number: Int
    ) async throws -> GitHubPullRequestReviewInventory {
        switch try await allReviewsPreservingFailure(repository: repository, number: number) {
        case let .inventory(inventory, _):
            return inventory
        case .notModified:
            // This convenience API never supplies validators, so a 304 is
            // not an authoritative inventory and must not be normalized.
            throw GitHubPullRequestClientError.unexpectedConditionalResponse
        case let .failure(failure):
            throw failure
        }
    }

    /// Fetches the complete review history without discarding already received
    /// raw pages when a later page is rejected or fails. Cancellation is never
    /// converted into a durable candidate attempt.
    func allReviewsPreservingFailure(
        repository: GitHubRepositoryPath,
        number: Int,
        githubOrganizationID: UInt64? = nil,
        validators: GitHubHTTPValidators? = nil
    ) async throws -> GitHubPullRequestReviewFetchResult {
        guard number > 0 else { throw GitHubRepositoryPathError.invalidPullRequestNumber }
        let firstRequestKey = Self.reviewsRequestKey(repository: repository, number: number)
        var rawPages = [GitHubPullRequestReviewRawPage]()
        let initial: GitHubPage<GitHubPullRequestReviewDTO>
        do {
            initial = try await firstReviewPage(repository: repository, number: number, validators: validators)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as GitHubFailure where failure.statusCode == 304 && validators != nil {
            return .notModified(ssoHeader: failure.ssoHeader)
        } catch let error as GitHubPullRequestReviewUndecodablePageError {
            rawPages.append(error.rawPage)
            return .failure(.init(
                terminalRequestKey: firstRequestKey,
                rawPages: rawPages,
                terminalFailure: .malformedResponse
            ))
        } catch {
            return .failure(.init(
                terminalRequestKey: firstRequestKey,
                rawPages: rawPages,
                terminalFailure: Self.terminalFailure(for: error)
            ))
        }

        var page = initial
        var reviews: [GitHubPullRequestReviewDTO] = []
        var pages = [GitHubPage<GitHubPullRequestReviewDTO>]()
        var reviewNodeIDs = Set<String>()
        var ssoHeaders = [GitHubSSOHeader]()
        var visitedPageURLs = Set<String>()
        var pageCount = 0
        rawPages.append(Self.rawPage(page, requestKey: firstRequestKey))
        do {
            try Self.validatePageObjectCount(page)
        } catch {
            return .failure(.init(
                terminalRequestKey: firstRequestKey,
                rawPages: rawPages,
                terminalFailure: .malformedResponse
            ))
        }
        pages.append(page)
        if let ssoHeader = page.ssoHeader {
            ssoHeaders.append(ssoHeader)
        }
        pageCount = 1

        if let githubOrganizationID,
           page.ssoHeader?.scoped(to: githubOrganizationID) != nil {
            return .failure(.init(
                terminalRequestKey: firstRequestKey,
                rawPages: rawPages,
                terminalFailure: .github(.init(
                    kind: .forbidden,
                    statusCode: 403,
                    ssoHeader: page.ssoHeader
                ))
            ))
        }

        func append(_ values: [GitHubPullRequestReviewDTO]) {
            for review in values where reviewNodeIDs.insert(review.nodeID).inserted {
                reviews.append(review)
            }
        }
        append(page.values)

        do {
            try Self.validatePaginationLink(
                page.nextPageURL,
                rawLinkHeader: page.linkHeader,
                repository: repository,
                number: number,
                currentPage: pageCount
            )
        } catch {
            return .failure(.init(
                terminalRequestKey: firstRequestKey,
                rawPages: rawPages,
                terminalFailure: .pagination
            ))
        }

        while let nextPageURL = page.nextPageURL {
            do {
                try Task.checkCancellation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .failure(.init(
                    terminalRequestKey: Self.requestKey(for: nextPageURL),
                    rawPages: rawPages,
                    terminalFailure: .transport
                ))
            }
            guard visitedPageURLs.insert(nextPageURL.absoluteString).inserted,
                  pageCount < Self.maximumReviewPages
            else {
                return .failure(.init(
                    terminalRequestKey: Self.requestKey(for: nextPageURL),
                    rawPages: rawPages,
                    terminalFailure: .pagination
                ))
            }
            let requestKey = Self.requestKey(for: nextPageURL)
            do {
                page = try await nextReviewPage(nextPageURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as GitHubPullRequestReviewUndecodablePageError {
                rawPages.append(error.rawPage)
                return .failure(.init(
                    terminalRequestKey: requestKey,
                    rawPages: rawPages,
                    terminalFailure: .malformedResponse
                ))
            } catch {
                return .failure(.init(
                    terminalRequestKey: requestKey,
                    rawPages: rawPages,
                    terminalFailure: Self.terminalFailure(for: error)
                ))
            }
            rawPages.append(Self.rawPage(page, requestKey: requestKey))
            do {
                try Self.validatePageObjectCount(page)
            } catch {
                return .failure(.init(
                    terminalRequestKey: requestKey,
                    rawPages: rawPages,
                    terminalFailure: .malformedResponse
                ))
            }
            pageCount += 1
            pages.append(page)
            append(page.values)
            if let ssoHeader = page.ssoHeader {
                ssoHeaders.append(ssoHeader)
            }
            if let githubOrganizationID,
               page.ssoHeader?.scoped(to: githubOrganizationID) != nil {
                return .failure(.init(
                    terminalRequestKey: requestKey,
                    rawPages: rawPages,
                    terminalFailure: .github(.init(
                        kind: .forbidden,
                        statusCode: 403,
                        ssoHeader: page.ssoHeader
                    ))
                ))
            }
            do {
                try Self.validatePaginationLink(
                    page.nextPageURL,
                    rawLinkHeader: page.linkHeader,
                    repository: repository,
                    number: number,
                    currentPage: pageCount
                )
            } catch {
                return .failure(.init(
                    terminalRequestKey: requestKey,
                    rawPages: rawPages,
                    terminalFailure: .pagination
                ))
            }
        }

        return .inventory(
            GitHubPullRequestReviewInventory(
                reviews: reviews,
                pages: pages,
                ssoHeaders: ssoHeaders
            ),
            rawPages
        )
    }

    func requestedReviewers(
        repository: GitHubRepositoryPath,
        number: Int,
        validators: GitHubHTTPValidators? = nil
    ) async throws -> GitHubResponse<GitHubRequestedReviewersDTO> {
        guard number > 0 else { throw GitHubRepositoryPathError.invalidPullRequestNumber }
        return try await client.getResponse(
            GitHubRequestedReviewersDTO.self,
            request: GitHubRESTRequest(
                path: "\(repository.path)/pulls/\(number)/requested_reviewers",
                validators: validators,
                maximumResponseBodyBytes: Self.maximumRequestedReviewerResponseBytes
            )
        )
    }

    func requestedReviewersPreservingFailure(
        repository: GitHubRepositoryPath,
        number: Int,
        validators: GitHubHTTPValidators? = nil
    ) async throws -> GitHubRequestedReviewersFetchResult {
        guard number > 0 else { throw GitHubRepositoryPathError.invalidPullRequestNumber }
        let requestKey = Self.requestedReviewersRequestKey(repository: repository, number: number)
        do {
            switch try await client.getResponsePreservingUndecodablePayload(
                GitHubRequestedReviewersDTO.self,
                request: GitHubRESTRequest(
                    path: "\(repository.path)/pulls/\(number)/requested_reviewers",
                    validators: validators,
                    maximumResponseBodyBytes: Self.maximumRequestedReviewerResponseBytes
                )
            ) {
            case let .response(response):
                return .response(response)
            case let .undecodable(response):
                return .failure(.init(
                    terminalRequestKey: requestKey,
                    rawPages: [.init(
                        requestKey: requestKey,
                        ordinal: 1,
                        payload: response.payload,
                        eTag: response.etag,
                        lastModified: response.lastModified,
                        ssoHeader: response.ssoHeader
                    )],
                    terminalFailure: .malformedResponse
                ))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as GitHubFailure where failure.statusCode == 304 && validators != nil {
            return .notModified(ssoHeader: failure.ssoHeader)
        } catch {
            return .failure(.init(
                terminalRequestKey: requestKey,
                rawPages: [],
                terminalFailure: Self.terminalFailure(for: error)
            ))
        }
    }

    private func firstReviewPage(
        repository: GitHubRepositoryPath,
        number: Int,
        validators: GitHubHTTPValidators?
    ) async throws -> GitHubPage<GitHubPullRequestReviewDTO> {
        switch try await client.getPagePreservingUndecodablePayload(
            GitHubPullRequestReviewDTO.self,
            request: GitHubRESTRequest(
                path: "\(repository.path)/pulls/\(number)/reviews",
                query: [URLQueryItem(name: "per_page", value: "100")],
                validators: validators
            )
        ) {
        case let .page(page): return page
        case let .undecodable(page):
            throw GitHubPullRequestReviewUndecodablePageError(
                rawPage: .init(
                    requestKey: Self.reviewsRequestKey(repository: repository, number: number),
                    ordinal: 1,
                    payload: page.payload,
                    eTag: page.etag,
                    lastModified: page.lastModified,
                    ssoHeader: page.ssoHeader
                )
            )
        }
    }

    private func nextReviewPage(_ url: URL) async throws -> GitHubPage<GitHubPullRequestReviewDTO> {
        let requestKey = Self.requestKey(for: url)
        switch try await client.getPagePreservingUndecodablePayload(
            GitHubPullRequestReviewDTO.self,
            request: GitHubRESTRequest(nextPageURL: url)
        ) {
        case let .page(page): return page
        case let .undecodable(page):
            throw GitHubPullRequestReviewUndecodablePageError(
                rawPage: .init(
                    requestKey: requestKey,
                    ordinal: 1,
                    payload: page.payload,
                    eTag: page.etag,
                    lastModified: page.lastModified,
                    ssoHeader: page.ssoHeader
                )
            )
        }
    }

    private nonisolated static func rawPage(
        _ page: GitHubPage<GitHubPullRequestReviewDTO>,
        requestKey: String
    ) -> GitHubPullRequestReviewRawPage {
        .init(
            requestKey: requestKey,
            ordinal: 1,
            payload: page.payload,
            eTag: page.etag,
            lastModified: page.lastModified,
            ssoHeader: page.ssoHeader
        )
    }

    private nonisolated static func validatePageObjectCount(
        _ page: GitHubPage<GitHubPullRequestReviewDTO>
    ) throws {
        guard page.values.count <= 100 else {
            throw GitHubPullRequestClientError.pageObjectLimitExceeded
        }
    }

    private nonisolated static func terminalFailure(
        for error: Error
    ) -> GitHubPullRequestReviewTerminalFailure {
        if let failure = error as? GitHubFailure { return .github(failure) }
        if error is GitHubPullRequestClientError { return .pagination }
        if error is GitHubRESTClientError { return .malformedResponse }
        return .transport
    }

    private nonisolated static func reviewsRequestKey(
        repository: GitHubRepositoryPath,
        number: Int
    ) -> String {
        "GET \(repository.path)/pulls/\(number)/reviews?per_page=100"
    }

    private nonisolated static func requestedReviewersRequestKey(
        repository: GitHubRepositoryPath,
        number: Int
    ) -> String {
        "GET \(repository.path)/pulls/\(number)/requested_reviewers"
    }

    private nonisolated static func requestKey(for url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              !components.percentEncodedPath.isEmpty,
              let query = components.percentEncodedQuery,
              !query.isEmpty
        else {
            return "GET /invalid-review-page"
        }
        return "GET \(components.percentEncodedPath)?\(query)"
    }

    private nonisolated static func validatePaginationLink(
        _ url: URL?,
        rawLinkHeader: String?,
        repository: GitHubRepositoryPath,
        number: Int,
        currentPage: Int
    ) throws {
        if let rawLinkHeader, !rawLinkHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsed = GitHubLinkHeader(rawLinkHeader),
                  parsed.isWellFormed,
                  parsed.nextPageURL == url
            else { throw GitHubPullRequestClientError.invalidPaginationLink }
        }
        guard let url else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              components.host?.caseInsensitiveCompare("api.github.com") == .orderedSame,
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.percentEncodedPath == "\(repository.path)/pulls/\(number)/reviews"
        else { throw GitHubPullRequestClientError.invalidPaginationLink }
        let items = components.queryItems ?? []
        let pageValues = items.filter { $0.name == "page" }.map(\.value)
        let perPageValues = items.filter { $0.name == "per_page" }.map(\.value)
        guard items.count == 2,
              pageValues.count == 1,
              perPageValues == ["100"],
              let pageValue = pageValues[0],
              let page = Int(pageValue),
              page > 0,
              String(page) == pageValue,
              page == currentPage + 1,
              page <= Self.maximumReviewPages
        else { throw GitHubPullRequestClientError.invalidPaginationLink }
    }
}

private struct GitHubPullRequestReviewUndecodablePageError: Error, Sendable {
    let rawPage: GitHubPullRequestReviewRawPage
}
