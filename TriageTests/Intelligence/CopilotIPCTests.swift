import XCTest
@testable import Triage

final class CopilotIPCTests: XCTestCase {
    func testFrameRoundTripsByteAccurately() throws {
        let payload = Data(#"{"operation":"health"}"#.utf8)
        let frame = try CopilotFrameCodec.encode(payload, maximumBytes: CopilotIPC.maximumRequestBytes)

        XCTAssertEqual(try CopilotFrameCodec.decode(frame, maximumBytes: CopilotIPC.maximumRequestBytes), payload)
        XCTAssertThrowsError(try CopilotFrameCodec.decode(Data(frame.dropLast()), maximumBytes: CopilotIPC.maximumRequestBytes))
    }

    func testHealthResponseDecodesHelperProtocolShape() throws {
        let response = try JSONDecoder().decode(
            CopilotWireResponse.self,
            from: Data(#"{"protocol_version":1,"request_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","organization_id":"MDEyOk9yZ2FuaXphdGlvbjE=","status":"health","health":{"helper_version":"0.1.0","copilot_available":false,"tool_policy":"deny_all"}}"#.utf8)
        )

        XCTAssertEqual(response.protocolVersion, 1)
        XCTAssertEqual(response.status, .health)
        XCTAssertEqual(response.organizationID?.rawValue, "MDEyOk9yZ2FuaXphdGlvbjE=")
        XCTAssertEqual(response.health?.toolPolicy, "deny_all")
    }
}
