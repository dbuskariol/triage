import XCTest
@testable import Triage

final class PerformanceFixtureContractTests: XCTestCase {
    func testFixtureMatchesEveryDocumentedCapacity() {
        let counts = PerformanceFixtureGenerator().countByKind()

        XCTAssertEqual(counts[.workItem], 10_000)
        XCTAssertEqual(counts[.timelineEvent], 100_000)
        XCTAssertEqual(counts[.repository], 250)
        XCTAssertEqual(counts[.project], 50)
        XCTAssertEqual(counts[.projectItem], 10_000)
        XCTAssertEqual(counts[.discussion], 5_000)
        XCTAssertEqual(counts[.discussionReply], 5_000)
        XCTAssertEqual(counts[.searchableComment], 25_000)
        XCTAssertEqual(counts[.actionableItem], 500)
    }

    func testFixtureStreamsInBoundedDeterministicBatches() {
        let generator = PerformanceFixtureGenerator()
        var batchCount = 0
        var largestBatchSize = 0
        var firstRecord: PerformanceFixtureRecord?
        var lastRecord: PerformanceFixtureRecord?
        var encounteredEmptyBatch = false

        for batch in generator.batches(maximumBatchSize: 127) {
            batchCount += 1
            largestBatchSize = max(largestBatchSize, batch.count)
            firstRecord = firstRecord ?? batch.first
            lastRecord = batch.last
            encounteredEmptyBatch = encounteredEmptyBatch || batch.isEmpty
        }

        XCTAssertGreaterThan(batchCount, 0)
        XCTAssertFalse(encounteredEmptyBatch)
        XCTAssertLessThanOrEqual(largestBatchSize, 127)
        XCTAssertEqual(firstRecord, PerformanceFixtureRecord(kind: .repository, ordinal: 0))
        XCTAssertEqual(
            lastRecord,
            PerformanceFixtureRecord(kind: .actionableItem, ordinal: PerformanceFixtureScale.actionableItems - 1)
        )
        XCTAssertEqual(generator.shapeChecksum(), 15_126_008_736_658_146_485)
    }

    func testReportFixtureMetadataContainsOnlyDeterministicShapeAndBatchValues() {
        let metadata = PerformanceFixtureReportMetadata.expected()

        XCTAssertEqual(metadata.shapeChecksum, PerformanceFixtureGenerator().shapeChecksum())
        XCTAssertEqual(metadata.capacities["workItems"], PerformanceFixtureScale.workItems)
        XCTAssertEqual(metadata.capacities["timelineEvents"], PerformanceFixtureScale.timelineEvents)
        XCTAssertEqual(metadata.capacities["actionableItems"], PerformanceFixtureScale.actionableItems)
        XCTAssertEqual(metadata.batchSize, PerformanceFixtureScale.batchSize)
        XCTAssertNil(metadata.streamedRecordCount)
        XCTAssertNil(metadata.seedBatchCount)
        XCTAssertNil(metadata.largestSeedBatchSize)

        let seeded = PerformanceFixtureReportMetadata.expected(
            seedMetrics: .init(batchCount: 4, largestBatchSize: 256, streamedRecordCount: 1_024)
        )
        XCTAssertEqual(seeded.streamedRecordCount, 1_024)
        XCTAssertEqual(seeded.seedBatchCount, 4)
        XCTAssertEqual(seeded.largestSeedBatchSize, 256)
    }

    func testRealSeederUsesBoundedGeneratorBatches() async throws {
        // This intentionally uses the production encrypted vault and seeding
        // path, but a deterministic miniature shape so normal tests never
        // build the opt-in 10k benchmark database.
        let generator = PerformanceFixtureGenerator(
            counts: [
                .repository: 3,
                .workItem: 3,
                .timelineEvent: 3,
                .project: 3,
                .projectItem: 3,
                .discussion: 3,
                .discussionReply: 3,
                .searchableComment: 3,
                .actionableItem: 2
            ]
        )
        let fixture = try await PerformanceFixtureStore(generator: generator)
        let metrics: PerformanceFixtureSeedMetrics
        let counts: [String: Int]
        do {
            metrics = try await fixture.seed(maximumBatchSize: 2)
            counts = try await fixture.recordCounts()
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }

        XCTAssertGreaterThan(metrics.batchCount, 1)
        XCTAssertEqual(metrics.largestBatchSize, 2)
        XCTAssertLessThanOrEqual(metrics.largestBatchSize, 2)
        XCTAssertEqual(metrics.streamedRecordCount, 26)
        XCTAssertEqual(counts["repositories"], 3)
        XCTAssertEqual(counts["work_items"], 3)
        XCTAssertEqual(counts["timeline_events"], 3)
        XCTAssertEqual(counts["projects"], 3)
        XCTAssertEqual(counts["project_items"], 3)
        XCTAssertEqual(counts["discussions"], 3)
        XCTAssertEqual(counts["discussion_replies"], 3)
        XCTAssertEqual(counts["searchable_comments"], 3)
        XCTAssertEqual(counts["actionable_items"], 3)
    }

    func testRepresentativeQueryPagesRemainBounded() {
        XCTAssertEqual(PerformanceFixtureQueryShape.workspacePageLimit, 50)
        XCTAssertEqual(PerformanceFixtureQueryShape.inboxPageLimit, 50)
        XCTAssertEqual(PerformanceFixtureQueryShape.searchPageLimit, 50)
        XCTAssertEqual(PerformanceFixtureQueryShape.timelinePageLimit, 100)
        XCTAssertEqual(PerformanceFixtureQueryShape.commentPageLimit, 32)
    }

    func testBenchmarkSamplingUsesElevenMeasuredSamplesAndNearestRankP95() {
        XCTAssertEqual(PerformanceBenchmarkSampling.warmupSampleCount, 3)
        XCTAssertEqual(PerformanceBenchmarkSampling.measuredSampleCount, 11)

        let sorted = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11].map(Double.init)
        XCTAssertEqual(PerformanceBenchmarkSampling.percentile(sorted, fraction: 0.5), 6)
        XCTAssertEqual(PerformanceBenchmarkSampling.percentile(sorted, fraction: 0.95), 11)
    }

    func testNormalTestsDoNotEnableFullScaleDatabaseSeeding() {
        XCTAssertFalse(PerformanceBenchmarkConfiguration.from(environment: [:]).isEnabled)
        XCTAssertFalse(
            PerformanceBenchmarkConfiguration.from(
                environment: ["TRIAGE_PERFORMANCE_BENCHMARK": "true"]
            ).isEnabled
        )
    }

}
