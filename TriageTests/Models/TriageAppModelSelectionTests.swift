import Foundation
import XCTest
@testable import Triage

@MainActor
final class TriageAppModelSelectionTests: XCTestCase {
    func testRapidAToBToAOnlyPublishesFinalActivation() async {
        let controller = WorkspaceActivationTaskController()
        let barrier = ActivationBarrier()
        let recorder = PublicationRecorder()

        controller.replace { generation in
            await barrier.wait()
            guard controller.isCurrent(generation) else { return }
            recorder.append("first-A")
        }
        await barrier.waitForArrival()

        controller.replace { generation in
            guard controller.isCurrent(generation) else { return }
            recorder.append("B")
        }
        controller.replace { generation in
            guard controller.isCurrent(generation) else { return }
            recorder.append("final-A")
        }

        await barrier.release()
        await controller.waitForCurrentTask()

        XCTAssertEqual(recorder.values, ["final-A"])
        await controller.cancelAndWait()
    }

    func testWorkspaceCacheEvictsLeastRecentlyUsedWorkspace() {
        let account = AccountID.make()
        let first = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let second = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        let third = OrganizationID(rawValue: UUID().uuidString.lowercased())!
        var cache = WorkspacePresentationCache<Int>(capacity: 2)
        let firstScope = scope(account: account, organization: first)
        let secondScope = scope(account: account, organization: second)
        let thirdScope = scope(account: account, organization: third)

        cache[firstScope] = 1
        cache[secondScope] = 2
        XCTAssertEqual(cache[firstScope], 1) // refresh first's recency
        cache[thirdScope] = 3

        XCTAssertEqual(cache[firstScope], 1)
        XCTAssertNil(cache[secondScope])
        XCTAssertEqual(cache[thirdScope], 3)
    }

    private func scope(account: AccountID, organization: OrganizationID) -> SynchronizationScope {
        SynchronizationScope(
            accountID: account,
            organizationID: organization,
            credentialRevision: CredentialRevision(rawValue: "credential")!,
            capabilityRevision: CapabilityRevision(rawValue: "capability")!
        )
    }
}

private actor ActivationBarrier {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var arrivalContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        arrivalContinuation?.resume()
        arrivalContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitForArrival() async {
        if releaseContinuation != nil { return }
        await withCheckedContinuation { continuation in
            arrivalContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
private final class PublicationRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
