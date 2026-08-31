import XCTest
@testable import Triage

final class AuthBrokerClientTests: XCTestCase {
    func testClientSendsExactProtocolWithNoStorePolicy() async throws {
        let session = BrokerStubSession(
            responseBody: Data(#"{"version":1,"accessToken":"token","tokenType":"bearer"}"#.utf8)
        )
        let client = try AuthBrokerClient(
            baseURL: URL(string: "https://oauth.triage.example")!,
            applicationVersion: "0.1.0",
            session: session
        )
        let response = try await client.exchange(
            AuthBrokerExchangeRequest(
                authorizationCode: OAuthAuthorizationCode("code"),
                codeVerifier: OAuthCodeVerifier(rawValue: String(repeating: "a", count: 43))!,
                redirectURI: URL(string: "triage://oauth-callback")!
            )
        )

        XCTAssertEqual(response.accessToken.value.rawValue, "token")
        let request = try await session.request()
        XCTAssertEqual(request.url?.absoluteString, "https://oauth.triage.example/oauth/exchange")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Triage-Application-Version"), "0.1.0")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, AuthBrokerProtocol.version)
        XCTAssertEqual(json["authorizationCode"] as? String, "code")
        XCTAssertEqual(json["codeVerifier"] as? String, String(repeating: "a", count: 43))
        XCTAssertEqual(json["redirectURI"] as? String, "triage://oauth-callback")
        let nonce = try XCTUnwrap(json["nonce"] as? String)
        XCTAssertEqual(nonce.count, 43)
        XCTAssertTrue(nonce.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        let issuedAt = try XCTUnwrap(json["issuedAt"] as? NSNumber).int64Value
        let expiresAt = try XCTUnwrap(json["expiresAt"] as? NSNumber).int64Value
        XCTAssertEqual(expiresAt - issuedAt, AuthBrokerProtocol.requestLifetimeMilliseconds)
    }

    func testClientRejectsInsecureOrCredentialBearingBrokerURLs() {
        XCTAssertThrowsError(
            try AuthBrokerClient(baseURL: URL(string: "http://oauth.triage.example")!, applicationVersion: "0.1.0")
        )
        XCTAssertThrowsError(
            try AuthBrokerClient(baseURL: URL(string: "https://user:password@oauth.triage.example")!, applicationVersion: "0.1.0")
        )
    }

    func testClientRejectsAnInvalidApplicationVersion() {
        XCTAssertThrowsError(
            try AuthBrokerClient(
                baseURL: URL(string: "https://oauth.triage.example")!,
                applicationVersion: "0.1"
            )
        ) { error in
            XCTAssertEqual(error as? AuthBrokerClientError, .invalidApplicationVersion)
        }
    }

    func testApplicationVersionComponentsMatchTheWorkerNumberContract() {
        XCTAssertTrue(
            AuthBrokerProtocol.isValidApplicationVersion("9007199254740991.0.0")
        )
        XCTAssertFalse(
            AuthBrokerProtocol.isValidApplicationVersion("9007199254740992.0.0")
        )
    }

    func testRuntimeConfigurationRejectsBrokerURLPartsTheClientWillNotUse() {
        for brokerURL in [
            "https://user:password@oauth.triage.example",
            "https://oauth.triage.example?redirect=unexpected",
            "https://oauth.triage.example#unexpected",
        ] {
            XCTAssertThrowsError(
                try RuntimeOAuthConfiguration(
                    clientID: "client-id",
                    brokerURLString: brokerURL,
                    applicationVersion: "0.1.0"
                )
            ) { error in
                XCTAssertEqual(error as? RuntimeOAuthConfigurationError, .invalidBrokerURL)
            }
        }
    }

    func testClientDecodesOnlyTypedBrokerFailures() async throws {
        let client = try AuthBrokerClient(
            baseURL: URL(string: "https://oauth.triage.example")!,
            applicationVersion: "0.1.0",
            session: BrokerStubSession(
                statusCode: 400,
                responseBody: Data(#"{"version":1,"code":"invalidGrant","recoveryDescription":"Expired"}"#.utf8)
            )
        )

        do {
            _ = try await client.refresh(AuthBrokerRefreshRequest(refreshToken: OAuthRefreshToken("refresh")))
            XCTFail("Expected broker failure.")
        } catch let error as AuthBrokerClientError {
            XCTAssertEqual(error, .broker(AuthBrokerFailure(code: .invalidGrant, recoveryDescription: "Expired")))
        }
    }

    func testClientRejectsOversizedBrokerResponsesBeforeDecoding() async throws {
        let client = try AuthBrokerClient(
            baseURL: URL(string: "https://oauth.triage.example")!,
            applicationVersion: "0.1.0",
            session: BrokerStubSession(
                responseBody: Data(
                    repeating: 0,
                    count: AuthBrokerProtocol.maximumResponseBodyBytes + 1
                )
            )
        )

        do {
            _ = try await client.refresh(AuthBrokerRefreshRequest(refreshToken: OAuthRefreshToken("refresh")))
            XCTFail("Expected oversized response rejection.")
        } catch let error as AuthBrokerClientError {
            XCTAssertEqual(error, .responseTooLarge)
        }
    }

    func testClientPropagatesCancellation() async throws {
        let client = try AuthBrokerClient(
            baseURL: URL(string: "https://oauth.triage.example")!,
            applicationVersion: "0.1.0",
            session: CancelledBrokerSession()
        )

        do {
            _ = try await client.refresh(AuthBrokerRefreshRequest(refreshToken: OAuthRefreshToken("refresh")))
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            return
        } catch {
            XCTFail("Expected cancellation, got \(error).")
        }
    }

    func testClientUsesBoundedSessionReadsWhenSupported() async throws {
        let session = BoundedBrokerSession(
            responseBody: Data(#"{"version":1,"accessToken":"token","tokenType":"bearer"}"#.utf8)
        )
        let client = try AuthBrokerClient(
            baseURL: URL(string: "https://oauth.triage.example")!,
            applicationVersion: "0.1.0",
            session: session
        )

        _ = try await client.refresh(AuthBrokerRefreshRequest(refreshToken: OAuthRefreshToken("refresh")))

        let maximumResponseBodyBytes = await session.maximumResponseBodyBytes()
        XCTAssertEqual(maximumResponseBodyBytes, AuthBrokerProtocol.maximumResponseBodyBytes)
    }
}

private actor BrokerStubSession: HTTPSession {
    private let statusCode: Int
    private let responseBody: Data
    private var capturedRequest: URLRequest?

    init(statusCode: Int = 200, responseBody: Data) {
        self.statusCode = statusCode
        self.responseBody = responseBody
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        capturedRequest = request
        return (
            responseBody,
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }

    func request() throws -> URLRequest {
        guard let capturedRequest else {
            throw AuthBrokerClientError.invalidResponse
        }
        return capturedRequest
    }
}

private actor CancelledBrokerSession: HTTPSession {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw CancellationError()
    }
}

private actor BoundedBrokerSession: BoundedHTTPSession {
    private let responseBody: Data
    private var receivedMaximumResponseBodyBytes: Int?

    init(responseBody: Data) {
        self.responseBody = responseBody
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        XCTFail("Expected AuthBrokerClient to use bounded reads.")
        throw URLError(.badServerResponse)
    }

    func data(
        for request: URLRequest,
        maximumResponseBodyBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        receivedMaximumResponseBodyBytes = maximumResponseBodyBytes
        return (
            responseBody,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }

    func maximumResponseBodyBytes() -> Int? {
        receivedMaximumResponseBodyBytes
    }
}
