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


    /// 同一晚若被云端重新定稿两次（两条都是 `is_uncomplete == false`），
    /// 必须取 wake_up_time 最晚者，且结果不能随云端返回顺序变化。
    func testSleepPrefersLatestFinalVersionRegardlessOfOrder() {
        let bedtime = 1_790_610_000
        func final(wakeHours: Int) -> MiItem {
            item(
                time: bedtime + wakeHours * 3600,
                value: [
                    "bedtime": bedtime,
                    "wake_up_time": bedtime + wakeHours * 3600,
                    "is_uncomplete": false,
                    "items": [],
                ],
                sid: "s1"
            )
        }
        let ascending = MiParser.sleepSessions([final(wakeHours: 6), final(wakeHours: 9)])
        let descending = MiParser.sleepSessions([final(wakeHours: 9), final(wakeHours: 6)])
        XCTAssertEqual(ascending.count, 1)
        XCTAssertEqual(descending.count, 1)
        let expected = Date(timeIntervalSince1970: Double(bedtime + 9 * 3600))
        XCTAssertEqual(ascending[0].endAt, expected, "应取 wake_up_time 最晚的最终版本")
        XCTAssertEqual(descending[0].endAt, expected, "结果不能依赖输入顺序")
        XCTAssertEqual(ascending[0].sleepId, descending[0].sleepId, "sleepId 必须稳定")
    }

    /// bedtime 链式漂移（A≈B、B≈C，但 A 与 C 差 240s）时，同一晚仍必须归并为 1 组，
    /// 否则会退化成「一晚两条 inBed」。
    func testSleepGroupsTransitiveBedtimeDrift() {
        let bedtime = 1_790_610_000
        func record(driftSeconds: Int, uncomplete: Bool) -> MiItem {
            let bed = bedtime + driftSeconds
            return item(
                time: bed + 5 * 3600,
                value: [
                    "bedtime": bed,
                    "wake_up_time": bed + 5 * 3600,
                    "is_uncomplete": uncomplete,
                    "items": [],
                ],
                sid: "s1"
            )
        }
        let sessions = MiParser.sleepSessions([
            record(driftSeconds: 0, uncomplete: false),
            record(driftSeconds: 119, uncomplete: true),
            record(driftSeconds: 238, uncomplete: true),
        ])
        XCTAssertEqual(sessions.count, 1, "链式漂移的同一晚不应被拆成多条")
        XCTAssertEqual(sessions[0].sleepId, "s1_\(bedtime)", "sleepId 锚定组内最早 bedtime，保持稳定")
    }

    /// 云端不返回 `duration` 时，睡眠时长必须扣掉清醒时长，而不是把整段卧床时间当作睡眠。
    func testSleepDurationFallbackExcludesAwake() {
        let bedtime = 1_790_610_000
        let session = MiParser.sleepSessions([
            item(
                time: bedtime + 8 * 3600,
                value: [
                    "bedtime": bedtime,
                    "wake_up_time": bedtime + 8 * 3600,
                    "is_uncomplete": false,
                    "awake_duration": 60,
                    "items": [],
                ],
                sid: "s1"
            )
        ])[0]
        XCTAssertEqual(session.timeAwakeMinutes, 60)
        XCTAssertEqual(session.durationMinutes, 7 * 60, "8h 卧床 - 1h 清醒 = 7h 睡眠")
        XCTAssertEqual(session.timeAsleepMinutes, 7 * 60)
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
