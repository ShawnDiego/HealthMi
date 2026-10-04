import XCTest
@testable import HealthMi

/// 校验从 Python `iter_*` 移植的解析逻辑。
final class MiParserTests: XCTestCase {
    private func item(time: Int, zoneOffset: Int = 0, value: Any, sid: String? = nil, key: String? = nil) -> MiItem {
        let valueData: Data?
        if let dict = value as? [String: Any] {
            valueData = try? JSONSerialization.data(withJSONObject: dict)
        } else if let array = value as? [Any] {
            valueData = try? JSONSerialization.data(withJSONObject: array)
        } else if let string = value as? String {
            valueData = Data(string.utf8)
        } else {
            valueData = nil
        }
        return MiItem(time: time, zoneOffset: zoneOffset, zoneName: "Asia/Shanghai", sid: sid, key: key, category: nil, valueData: valueData)
    }

    func testDailyActivityAggregation() {
        // 同一天两条 steps 记录 + 一条 calories 记录
        let stepsItems = [
            item(time: 1_782_000_000, value: ["steps": 5000, "distance": 3000, "calories": 100]),
            item(time: 1_782_003_600, value: ["steps": 3000, "distance": 2000, "calories": 50]),
        ]
        let calorieItems = [
            item(time: 1_782_000_000, value: ["calories": 210]),
        ]
        let result = MiParser.dailyActivity(stepsItems: stepsItems, calorieItems: calorieItems)
        XCTAssertEqual(result.count, 1)
        let day = result[0]
        XCTAssertEqual(day.steps, 8000)
        XCTAssertEqual(day.distanceM, 5000)
        // calories 以 calories key 总量为准
        XCTAssertEqual(day.activeKcal, 210)
    }

    func testSleepStagesParsing() {
        let start = 1_782_000_000
        let value: [String: Any] = [
            "bedtime": start,
            "wake_up_time": start + 6 * 3600,
            "duration": 360,
            "score": 90,
            "is_nap": false,
            "items": [
                ["start_time": start, "end_time": start + 3600, "state": 2],        // deep（实测映射）
                ["start_time": start + 3600, "end_time": start + 5400, "state": 5], // awake
                ["start_time": start + 5400, "end_time": start + 7200, "state": 4], // rem
            ],
        ]
        let sessions = MiParser.sleepSessions([item(time: start, value: value, sid: "user1")])
        XCTAssertEqual(sessions.count, 1)
        let session = sessions[0]
        XCTAssertEqual(session.durationMinutes, 360)
        XCTAssertEqual(session.sleepScore, 90)
        XCTAssertEqual(session.segments.count, 3)
        XCTAssertEqual(session.segments[0].stage, .deep)
        XCTAssertEqual(session.segments[1].stage, .awake)
        XCTAssertEqual(session.segments[2].stage, .rem)
        XCTAssertEqual(session.stageSummary[.deep], 60)
        XCTAssertEqual(session.stageSummary[.awake], 30)
        XCTAssertEqual(session.stageSummary[.rem], 30)
    }

    /// 云端同一晚会返回多个「中间版本」（`is_uncomplete = true`，wake_up_time 越写越晚）。
    /// 应只保留最终版本，且 sleepId 按夜晚（sid + bedtime）稳定。
    func testSleepMergesIncompleteRecords() {
        let bedtime = 1_790_610_000
        func record(wakeOffsetHours: Int, uncomplete: Bool) -> MiItem {
            let value: [String: Any] = [
                "bedtime": bedtime,
                "wake_up_time": bedtime + wakeOffsetHours * 3600,
                "is_uncomplete": uncomplete,
                "duration": 300,
                "items": [["start_time": bedtime, "end_time": bedtime + 1800, "state": 2]],
            ]
            return item(time: bedtime + wakeOffsetHours * 3600, value: value, sid: "s1")
        }
        // 顺序打乱，最终版本放在中间，确保归并不依赖输入顺序
        let sessions = MiParser.sleepSessions([
            record(wakeOffsetHours: 5, uncomplete: true),
            record(wakeOffsetHours: 8, uncomplete: false),
            record(wakeOffsetHours: 3, uncomplete: true),
        ])
        XCTAssertEqual(sessions.count, 1, "同一会话的中间版本必须被丢弃")
        let session = sessions[0]
        XCTAssertEqual(session.sleepId, "s1_\(bedtime)", "sleepId 必须按夜晚稳定，不随 wake_up_time 变化")
        XCTAssertEqual(session.endAt, Date(timeIntervalSince1970: Double(bedtime + 8 * 3600)))
        XCTAssertEqual(session.segments.count, 1)

        // 覆盖区间要涵盖同组所有版本（用于清理旧样本）
        let coverages = MiParser.sleepSessionCoverages([
            record(wakeOffsetHours: 5, uncomplete: true),
            record(wakeOffsetHours: 8, uncomplete: false),
        ])
        XCTAssertEqual(coverages.count, 1)
        XCTAssertEqual(coverages[0].start, bedtime)
        XCTAssertEqual(coverages[0].end, bedtime + 8 * 3600)

        // 不同 bedtime（例如午睡）不能被并入同一会话
        let nap: [String: Any] = [
            "bedtime": bedtime + 14 * 3600,
            "wake_up_time": bedtime + 15 * 3600,
            "is_uncomplete": false,
            "items": [],
        ]
        let two = MiParser.sleepSessions([
            record(wakeOffsetHours: 8, uncomplete: false),
            item(time: bedtime + 15 * 3600, value: nap, sid: "s1"),
        ])
        XCTAssertEqual(two.count, 2, "不同 bedtime 的会话（午睡）不应被合并")
    }

    func testWorkoutsParsing() {
        let start = 1_782_000_000
        let value = #"{"start_time": 1782000000, "end_time": 1782003600, "duration": 3600, "distance": 10000, "calories": 500, "avg_hrm": 140, "max_hrm": 175}"#
        let workouts = MiParser.workouts([item(time: start, value: value, sid: "user1", key: "running")])
        XCTAssertEqual(workouts.count, 1)
        let workout = workouts[0]
        XCTAssertEqual(workout.activityType, "running")
        XCTAssertEqual(workout.durationMinutes, 60)
        XCTAssertEqual(workout.distanceM, 10000)
        XCTAssertEqual(workout.caloriesKcal, 500)
        XCTAssertEqual(workout.avgHeartRateBpm, 140)
        XCTAssertEqual(workout.maxHeartRateBpm, 175)
    }

    func testHRVParsing() {
        let start = 1_782_000_000
        let value: [String: Any] = [
            "avg_hrv": 37,
            "bedtime": start,
            "wake_up_time": start + 6 * 3600,
        ]
        let samples = MiParser.hrvSamples([item(time: start, value: value, sid: "user1")])
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].sdnnMs, 37)
        XCTAssertEqual(samples[0].id, "mi_fitness_hrv_user1_\(start)")
    }

    func testRespiratoryRateParsing() {
        let start = 1_782_000_000
        let value: [String: Any] = [
            "avg_breath": 16,
            "bedtime": start,
            "wake_up_time": start + 6 * 3600,
        ]
        let samples = MiParser.respiratoryRateSamples([item(time: start, value: value, sid: "user1")])
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].breathsPerMinute, 16)
        XCTAssertEqual(samples[0].id, "mi_fitness_respiratory_user1_\(start)")
    }

    func testHeartRateParsing() {
        let ts = 1_782_000_000
        let passive = item(time: ts, value: ["bpm": 72, "type": 0])
        let active = item(time: ts + 60, value: ["bpm": 130, "type": 1])
        let resting = item(time: ts + 120, value: ["bpm": 55])
        let samples = MiParser.heartRateSamples([passive, active], restingItems: [resting])
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples[0].sampleType, .passive)
        XCTAssertEqual(samples[1].sampleType, .active)
        XCTAssertEqual(samples[2].sampleType, .resting)
        XCTAssertEqual(samples[2].bpm, 55)
    }
}
