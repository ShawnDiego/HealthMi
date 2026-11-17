import XCTest
@testable import HealthMi

final class SyncEngineTests: XCTestCase {
    private let engine = SyncEngine()

    func testFirstSyncWindow() async {
        // 首次同步：无游标，按 backfillDays 回填
        let now = Date()
        let result = await engine.syncWindow(highWater: nil, backfillDays: 30, forceBackfill: false)
        // start 应该大约 30 天前
        let daysDiff = Calendar.current.dateComponents([.day], from: result.start, to: now).day ?? 0
        XCTAssertEqual(daysDiff, 30, accuracy: 1)
        XCTAssertEqual(result.end.timeIntervalSince(now), 0, accuracy: 60)
    }

    func testIncrementalSyncWindow() async {
        // 增量同步：有游标，从游标往前 1 天（重叠）
        let highWater = Date(timeIntervalSinceNow: -86400) // 1 天前
        let result = await engine.syncWindow(highWater: highWater, backfillDays: 30, forceBackfill: false)
        // start 应该在 highWater 前 1 天（重叠）
        let expected = Calendar.current.date(byAdding: .day, value: -1, to: highWater)!
        XCTAssertEqual(result.start.timeIntervalSince(expected), 0, accuracy: 60)
    }

    func testForceBackfillWindow() async {
        // 强制回填：忽略游标，按 backfillDays 重拉
        let highWater = Date(timeIntervalSinceNow: -86400 * 7)
        let now = Date()
        let result = await engine.syncWindow(highWater: highWater, backfillDays: 7, forceBackfill: true)
        let daysDiff = Calendar.current.dateComponents([.day], from: result.start, to: now).day ?? 0
        XCTAssertEqual(daysDiff, 7, accuracy: 1)
    }

    func testStartTimeBeforeEndTime() async {
        let result = await engine.syncWindow(highWater: nil, backfillDays: 30, forceBackfill: false)
        XCTAssertLessThan(result.start, result.end)
        XCTAssertLessThan(result.startTime, result.endTime)
    }

    func testPaginationLimitErrorDescription() {
        let withDate = MiAPIError.paginationLimit(
            key: "heart_rate", page: 201, latestDate: "2026-09-20 12:30:00"
        )
        XCTAssertEqual(
            withDate.errorDescription,
            "[heart_rate] 分页超安全上限(201页)，当前卡在: 2026-09-20 12:30:00"
        )

        let withoutDate = MiAPIError.paginationLimit(
            key: "steps", page: 201, latestDate: nil
        )
        XCTAssertEqual(
            withoutDate.errorDescription,
            "[steps] 分页超安全上限(201页)，当前卡在: 未知时间"
        )
    }

    func testLogDateFormatterUsesPosixLocaleAndRegionTimeZone() {
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        let utc = TimeZone(secondsFromGMT: 0)!
        let formatter = MiAPIClient.makeLogDateFormatter(timeZone: shanghai)
        XCTAssertEqual(formatter.locale.identifier, "en_US_POSIX")
        XCTAssertEqual(formatter.timeZone, shanghai)

        // 1970-01-01 00:00:00 UTC == 1970-01-01 08:00:00 +08:00
        XCTAssertEqual(MiAPIClient.formatTimestamp(0, timeZone: utc), "1970-01-01 00:00:00")
        XCTAssertEqual(MiAPIClient.formatTimestamp(0, timeZone: shanghai), "1970-01-01 08:00:00")
    }

    func testTimeChunksSplittingAndContinuity() {
        let start = 1_700_000_000
        let totalDays = 65
        let end = start + totalDays * 86_400 - 1
        let chunks = MiAPIClient.timeChunks(startTime: start, endTime: end, chunkDays: 30)

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].startTime, start)
        XCTAssertEqual(chunks[0].endTime, start + 30 * 86_400 - 1)
        XCTAssertEqual(chunks[1].startTime, chunks[0].endTime + 1)
        XCTAssertEqual(chunks[1].endTime, start + 60 * 86_400 - 1)
        XCTAssertEqual(chunks[2].startTime, chunks[1].endTime + 1)
        XCTAssertEqual(chunks[2].endTime, end)

        // 反向非法区间应返回空数组
        XCTAssertTrue(MiAPIClient.timeChunks(startTime: 100, endTime: 50, chunkDays: 30).isEmpty)
    }

    func testSyncWindowsMultiYearSlicesCoverFullRange() async {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let overall = await engine.syncWindow(
            highWater: nil, backfillDays: 3650, forceBackfill: true, now: now
        )
        let slices = await engine.syncWindows(
            highWater: nil, backfillDays: 3650, forceBackfill: true, chunkDays: 30, now: now
        )

        // 3650 天（含首尾日历日）按 30 天切片应拆分为 122 段
        XCTAssertEqual(slices.count, 122)
        XCTAssertEqual(slices.first?.start, overall.start)
        XCTAssertEqual(slices.first?.startTime, overall.startTime)
        XCTAssertEqual(slices.last?.end, overall.end)
        XCTAssertEqual(slices.last?.endTime, overall.endTime)

        for idx in 1..<slices.count {
            XCTAssertEqual(slices[idx].startTime, slices[idx - 1].endTime + 1)
            XCTAssertLessThanOrEqual(
                slices[idx].endTime - slices[idx].startTime + 1,
                30 * 86_400
            )
        }
    }
}
