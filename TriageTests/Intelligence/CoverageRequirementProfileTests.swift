import Foundation
import GRDB
import XCTest
@testable import Triage

final class CoverageRequirementProfileTests: XCTestCase {
    func testBuildIncludesExactStaticAndAuthoritativeDynamicTopology() async throws {
        let fixture = try await CoverageProfileFixture()
        defer { fixture.remove() }
        try await fixture.installTopology()
        let scope = fixture.scope
        let olderStart = fixture.now.addingTimeInterval(-7_200)
        let olderEnd = fixture.now.addingTimeInterval(-3_600)
        let currentStart = fixture.now.addingTimeInterval(-900)
        let currentEnd = fixture.now
        let coverage = [
            fixture.record(
                feature: .roleDiscovery,
                stream: "role-discovery-profile-org",
                intervalStart: olderStart,
                intervalEnd: olderEnd
            ),
            fixture.record(
                feature: .roleDiscovery,
                stream: "role-discovery-profile-org",
                intervalStart: currentStart,
                intervalEnd: currentEnd
            ),
            fixture.record(
                feature: .discussions,
                repositoryID: fixture.availableRepositoryID,
                stream: "discussions-profile-org-repo-available",
                intervalStart: currentStart,
                intervalEnd: currentEnd
            ),
            fixture.record(
                feature: .discussionComments,
                repositoryID: fixture.availableRepositoryID,
                stream: "discussion-comments-profile-org-repo-available",
                intervalStart: currentStart,
                intervalEnd: currentEnd,
                status: .unavailable
            ),
            fixture.record(
                feature: .discussionReplies,
                repositoryID: fixture.availableRepositoryID,
                stream: "discussion-replies-profile-org-repo-available",
                intervalStart: currentStart,
                intervalEnd: currentEnd,
                status: .unavailable
            ),
            fixture.record(
                feature: .projectItems,
                stream: "projects-v2-items-profile-org-P_profile",
                intervalStart: currentStart,
                intervalEnd: currentEnd
            ),
            fixture.record(
                feature: .issues,
                repositoryID: fixture.availableRepositoryID,
                stream: "hydration-issues-profile-org-repo-available"
            ),
            fixture.record(
                feature: .pullRequests,
                repositoryID: fixture.availableRepositoryID,
                stream: "hydration-pull-requests-profile-org-repo-available"
            )
        ]

        let requirements = try await fixture.vault.read { database in
            try CoverageRequirementProfile.build(
                for: scope,
                coverage: coverage,
                in: database
            )
        }

        XCTAssertEqual(requirements.count, 37)
        XCTAssertTrue(AccountOrganizationCoverageManifest.missingFeatures(in: requirements).isEmpty)
        XCTAssertFalse(requirements.contains { $0.feature == .notifications })
        XCTAssertTrue(requirements.contains {
            $0.streamID.rawValue.contains(fixture.revokedRepositoryID.rawValue)
        })
        XCTAssertEqual(requirements, requirements.sorted(by: requirementPrecedes))

        let roleChildren = requirements.filter {
            $0.feature == .roleDiscovery
                && $0.streamID.rawValue != "role-discovery-profile-org"
        }
        XCTAssertEqual(roleChildren.count, RoleDiscoveryStreamKind.allCases.count)
        XCTAssertTrue(roleChildren.allSatisfy {
            $0.intervalStart == currentStart && $0.intervalEnd == currentEnd
        })
        XCTAssertEqual(
            requirements.first {
                $0.streamID.rawValue == "discussions-profile-org-repo-available"
            }?.intervalStart,
            currentStart
        )
        XCTAssertNotNil(requirements.first {
            $0.streamID.rawValue == "discussion-comments-profile-org-repo-available"
        })
        XCTAssertNotNil(requirements.first {
            $0.streamID.rawValue == "discussion-replies-profile-org-repo-available"
        })
        XCTAssertEqual(
            requirements.first {
                $0.streamID.rawValue == "projects-v2-items-profile-org-P_profile"
            }?.intervalEnd,
            currentEnd
        )
        XCTAssertNotNil(requirements.first {
            $0.streamID.rawValue == "hydration-issues-profile-org-repo-available"
        })
        XCTAssertNotNil(requirements.first {
            $0.streamID.rawValue == "hydration-pull-requests-profile-org-repo-available"
        })
    }

    func testMissingDynamicLeafCannotDisappearFromProfile() async throws {
        let fixture = try await CoverageProfileFixture()
        defer { fixture.remove() }
        try await fixture.installTopology()

        let requirements = try await fixture.vault.read { database in
            try CoverageRequirementProfile.build(
                for: fixture.scope,
                coverage: [],
                in: database
            )
        }
        let missingDiscussion = try XCTUnwrap(requirements.first {
            $0.streamID.rawValue == "discussions-profile-org-repo-available"
        })
        XCTAssertNil(missingDiscussion.intervalStart)
        XCTAssertNil(missingDiscussion.intervalEnd)

        let evaluation = CoverageEvaluator().evaluate(
            requirements: [missingDiscussion],
            records: [],
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision
        )
        XCTAssertEqual(evaluation.missing, [missingDiscussion])
        XCTAssertEqual(evaluation.freshness.status, .partial)
    }

    func testKnownNonAvailableRepositoryCannotDisappearFromProfile() async throws {
        let fixture = try await CoverageProfileFixture()
        defer { fixture.remove() }
        try await fixture.installTopology()

        let requirements = try await fixture.vault.read { database in
            try CoverageRequirementProfile.build(
                for: fixture.scope,
                coverage: [],
                in: database
            )
        }
        let retainedRequirements = requirements.filter {
            $0.repositoryID == fixture.revokedRepositoryID
        }
        XCTAssertEqual(retainedRequirements.count, 5)

        let evaluation = CoverageEvaluator().evaluate(
            requirements: retainedRequirements,
            records: [],
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision
        )
        XCTAssertEqual(evaluation.missing, retainedRequirements)
        XCTAssertEqual(evaluation.freshness.status, .partial)

        let rootRequirement = try XCTUnwrap(requirements.first {
            $0.feature == .repositories
                && $0.repositoryID == nil
                && $0.streamID.rawValue == "inventory-repositories-profile-org"
        })
        let retainedAccessRequirement = try XCTUnwrap(requirements.first {
            $0.feature == .repositories
                && $0.repositoryID == fixture.revokedRepositoryID
                && $0.streamID == rootRequirement.streamID
        })
        let rootCoverage = fixture.record(
            feature: .repositories,
            stream: rootRequirement.streamID.rawValue
        )
        let unknownRetainedCoverage = fixture.record(
            feature: .repositories,
            repositoryID: fixture.revokedRepositoryID,
            stream: retainedAccessRequirement.streamID.rawValue,
            status: .unknown
        )
        let rootAndUnknownLeaf = CoverageEvaluator().evaluate(
            requirements: [rootRequirement, retainedAccessRequirement],
            records: [rootCoverage, unknownRetainedCoverage],
            accountID: fixture.accountID,
            organizationID: fixture.organizationID,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision
        )
        XCTAssertFalse(rootAndUnknownLeaf.isComplete)
        XCTAssertEqual(rootAndUnknownLeaf.missing, [retainedAccessRequirement])
        XCTAssertEqual(rootAndUnknownLeaf.freshness.status, .partial)

        let completedVisibleTopology = requirements
            .filter { $0.repositoryID != fixture.revokedRepositoryID }
            .map { requirement in
                fixture.record(
                    feature: requirement.feature,
                    repositoryID: requirement.repositoryID,
                    stream: requirement.streamID.rawValue,
                    intervalStart: requirement.intervalStart,
                    intervalEnd: requirement.intervalEnd
                )
            }
        let state = AccountOrganizationCachedState(
            coverage: completedVisibleTopology,
            coverageRequirements: requirements,
            lastSuccessfulSyncAt: fixture.now
        )
        XCTAssertEqual(state.freshness.status, .partial)
    }

    func testDuplicateHydrationLeafFailsClosed() async throws {
        let fixture = try await CoverageProfileFixture()
        defer { fixture.remove() }
        let duplicate = fixture.record(
            feature: .issues,
            repositoryID: fixture.availableRepositoryID,
            stream: "hydration-issues-profile-org-repo-available"
        )

        do {
            _ = try await fixture.vault.read { database in
                try CoverageRequirementProfile.build(
                    for: fixture.scope,
                    coverage: [duplicate, duplicate],
                    in: database
                )
            }
            XCTFail("Duplicate dynamic topology must fail closed.")
        } catch {
            XCTAssertEqual(
                error as? CoverageRequirementProfileError,
                .duplicateRequirement
            )
        }
    }

    func testForeignAuthorityCoverageFailsClosed() async throws {
        let fixture = try await CoverageProfileFixture()
        defer { fixture.remove() }
        let foreign = CoverageRecord(
            accountID: AccountID.make(),
            organizationID: fixture.organizationID,
            repositoryID: nil,
            feature: .repositories,
            streamID: SyncStreamID(rawValue: "inventory-repositories-profile-org")!,
            intervalStart: nil,
            intervalEnd: nil,
            credentialRevision: fixture.credentialRevision,
            capabilityRevision: fixture.capabilityRevision,
            status: .complete,
            lastSuccessfulAt: fixture.now,
            failureDetail: nil
        )

        do {
            _ = try await fixture.vault.read { database in
                try CoverageRequirementProfile.build(
                    for: fixture.scope,
                    coverage: [foreign],
                    in: database
                )
            }
            XCTFail("Foreign authority coverage must fail closed.")
        } catch {
            XCTAssertEqual(
                error as? CoverageRequirementProfileError,
                .invalidPersistedTopology
            )
        }
    }

    func testUnavailableCommentAndReplyRequirementsCannotProduceFreshness() async throws {
        let fixture = try await CoverageProfileFixture()
        defer { fixture.remove() }
        let requirements = try await fixture.vault.read { database in
            try CoverageRequirementProfile.build(
                for: fixture.scope,
                coverage: [],
                in: database
            )
        }
        let records = requirements.map { requirement in
            fixture.record(
                feature: requirement.feature,
                repositoryID: requirement.repositoryID,
                stream: requirement.streamID.rawValue,
                intervalStart: requirement.intervalStart,
                intervalEnd: requirement.intervalEnd,
                status: requirement.feature == .discussionComments
                    || requirement.feature == .discussionReplies ? .unavailable : .complete
            )
        }
        let state = AccountOrganizationCachedState(
            coverage: records,
            coverageRequirements: requirements,
            lastSuccessfulSyncAt: fixture.now
        )

        XCTAssertEqual(state.freshness.status, .partial)
    }

    func testRepositoryTopologyFailsClosedBeforeExceedingRequirementLimit() async throws {
        let fixture = try await CoverageProfileFixture()
        defer { fixture.remove() }
        try await fixture.installTopology(includeProject: false)

        do {
            _ = try await fixture.vault.read { database in
                try CoverageRequirementProfile.build(
                    for: fixture.scope,
                    coverage: [],
                    in: database,
                    maximumRequirementCount: 27
                )
            }
            XCTFail("A four-leaf repository must not overflow the bounded profile.")
        } catch {
            XCTAssertEqual(error as? CoverageRequirementProfileError, .tooManyRequirements)
        }
    }

    func testProjectTopologyFailsClosedBeforeExceedingRequirementLimit() async throws {
        let fixture = try await CoverageProfileFixture()
        defer { fixture.remove() }
        try await fixture.installTopology(includeRepositories: false)

        do {
            _ = try await fixture.vault.read { database in
                try CoverageRequirementProfile.build(
                    for: fixture.scope,
                    coverage: [],
                    in: database,
                    maximumRequirementCount: 24
                )
            }
            XCTFail("A project leaf must not overflow the bounded profile.")
        } catch {
            XCTAssertEqual(error as? CoverageRequirementProfileError, .tooManyRequirements)
        }
    }

    func testHydrationTopologyFailsClosedBeforeExceedingRequirementLimit() async throws {
        let fixture = try await CoverageProfileFixture()
        defer { fixture.remove() }
        let hydration = fixture.record(
            feature: .issues,
            repositoryID: fixture.availableRepositoryID,
            stream: "hydration-issues-profile-org-repo-available"
        )

        do {
            _ = try await fixture.vault.read { database in
                try CoverageRequirementProfile.build(
                    for: fixture.scope,
                    coverage: [hydration],
                    in: database,
                    maximumRequirementCount: 24
                )
            }
            XCTFail("A hydration leaf must not overflow the bounded profile.")
        } catch {
            XCTAssertEqual(error as? CoverageRequirementProfileError, .tooManyRequirements)
        }
    }

    private func requirementPrecedes(
        _ lhs: CoverageRequirement,
        _ rhs: CoverageRequirement
    ) -> Bool {
        requirementIdentity(lhs) < requirementIdentity(rhs)
    }

    private func requirementIdentity(_ requirement: CoverageRequirement) -> String {
        let fields = [
            requirement.feature.rawValue,
            requirement.repositoryID?.rawValue ?? "",
            requirement.streamID.rawValue,
            requirement.intervalStart.map(milliseconds).map(String.init) ?? "",
            requirement.intervalEnd.map(milliseconds).map(String.init) ?? ""
        ]
        return fields.map { field in
            String(field.utf8.count) + ":" + field
        }.joined(separator: "|")
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

private final class CoverageProfileFixture: @unchecked Sendable {
    let directory: URL
    let accountID = AccountID.make()
    let organizationID = OrganizationID(rawValue: "profile-org")!
    let availableRepositoryID = RepositoryID(rawValue: "repo-available")!
    let revokedRepositoryID = RepositoryID(rawValue: "repo-revoked")!
    let credentialRevision = CredentialRevision(rawValue: "credential-profile")!
    let capabilityRevision = CapabilityRevision(rawValue: "capability-profile")!
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let registry: VaultRegistry
    let vault: AccountVault

    var scope: SynchronizationScope {
        SynchronizationScope(
            accountID: accountID,
            organizationID: organizationID,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision
        )
    }

    init() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-coverage-profile-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        registry = try VaultRegistry(rootDirectory: directory)
        vault = try await registry.open(
            accountID: accountID,
            vaultKey: try VaultKey.generate()
        )
        let accounts = AccountRepository(vault: vault)
        try await accounts.save(
            GitHubAccount(
                id: accountID,
                githubUserID: 71,
                nodeID: GitHubNodeID(rawValue: "U_profile")!,
                login: "profile-user",
                authenticationKind: .oauth,
                credentialID: CredentialID.make(),
                credentialStatus: .active,
                createdAt: now,
                lastValidatedAt: now
            ),
            credentialRevision: credentialRevision
        )
        try await accounts.save(
            GitHubOrganization(
                id: organizationID,
                githubOrganizationID: 72,
                nodeID: GitHubNodeID(rawValue: "O_profile")!,
                login: "profile-org"
            ),
            access: OrganizationAccess(
                accountID: accountID,
                organizationID: organizationID,
                state: .available,
                capabilityRevision: capabilityRevision,
                capabilities: [],
                checkedAt: now
            ),
            selectedAt: now
        )
    }

    func installTopology(
        includeRepositories: Bool = true,
        includeProject: Bool = true
    ) async throws {
        let milliseconds = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        try await vault.write { database in
            if includeRepositories {
                for (repositoryID, githubID, nodeID, access) in [
                    (availableRepositoryID, "701", "R_available", "available"),
                    (revokedRepositoryID, "702", "R_revoked", "revoked")
                ] {
                    try database.execute(
                        sql: """
                            INSERT INTO repositories (
                                id, organization_id, github_repository_id, github_node_id,
                                owner_login, name, is_private, is_archived, has_discussions,
                                html_url, updated_at_ms, archived_at_ms, has_discussions_known
                            ) VALUES (?, ?, ?, ?, 'profile-org', ?, 1, 0, 1, ?, ?, NULL, 1)
                            """,
                        arguments: [
                            repositoryID.rawValue,
                            organizationID.rawValue,
                            githubID,
                            nodeID,
                            repositoryID.rawValue,
                            "https://github.com/profile-org/\(repositoryID.rawValue)",
                            milliseconds
                        ]
                    )
                    try database.execute(
                        sql: """
                            INSERT INTO account_repository_access (
                                account_id, repository_id, access_state, observed_at_ms
                            ) VALUES (?, ?, ?, ?)
                            """,
                        arguments: [accountID.rawValue, repositoryID.rawValue, access, milliseconds]
                    )
                }
            }
            guard includeProject else { return }
            let projectID = GitHubNodeID(rawValue: "P_profile")!
            try GitHubNodeRepository.save(
                NormalizedGitHubNode(
                    nodeID: projectID,
                    accountID: accountID,
                    organizationID: organizationID,
                    repositoryID: nil,
                    kind: .project,
                    numericID: nil,
                    number: 1,
                    title: "Profile Project",
                    state: .open,
                    url: URL(string: "https://github.com/orgs/profile-org/projects/1")!,
                    bodyMarkdown: nil,
                    authorID: nil,
                    createdAt: now,
                    updatedAt: now,
                    closedAt: nil,
                    mergedAt: nil,
                    sourceRevision: "profile-project",
                    observedAt: now,
                    accessibility: .accessible
                ),
                in: database
            )
            try database.execute(
                sql: """
                    INSERT INTO projects (
                        github_node_id, organization_id, number, title, state, updated_at_ms
                    ) VALUES (?, ?, 1, 'Profile Project', 'open', ?)
                    """,
                arguments: [projectID.rawValue, organizationID.rawValue, milliseconds]
            )
        }
    }

    func record(
        feature: CoverageFeature,
        repositoryID: RepositoryID? = nil,
        stream: String,
        intervalStart: Date? = nil,
        intervalEnd: Date? = nil,
        status: CoverageStatus = .complete
    ) -> CoverageRecord {
        CoverageRecord(
            accountID: accountID,
            organizationID: organizationID,
            repositoryID: repositoryID,
            feature: feature,
            streamID: SyncStreamID(rawValue: stream)!,
            intervalStart: intervalStart,
            intervalEnd: intervalEnd,
            credentialRevision: credentialRevision,
            capabilityRevision: capabilityRevision,
            status: status,
            lastSuccessfulAt: status == .complete ? now : nil,
            failureDetail: nil
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
