import Foundation
import HealthKit

/// 单次同步的结果摘要。
struct SyncOutcome: Sendable {
    let type: SyncDataType
    let fetched: Int
    let added: Int
    let highWater: Date
}

/// 分段同步的时间切片。
/// `start` / `end` 与取数时间戳 `startTime` / `endTime` 严格对齐（含首段 00:00:00 与末段 23:59:59），
/// 确保 HealthKit 去重查询窗口完整覆盖取数窗口，避免缝隙内样本被重复写入；
/// `highWater` 在中间切片取 `end`，在末段取同步发起时刻 `now`，避免游标超前推进。
struct SyncWindowSlice: Sendable, Equatable {
    let start: Date
    let end: Date
    let startTime: Int
    let endTime: Int
    let highWater: Date
}

/// 同步引擎：取数 → 解析 → 映射 → 幂等写入。
///
/// 写法与已验证的 Python 工具保持一致：每次按类型从云端拉取时间区间数据，
/// 用 `HealthWriter` 按 externalID 去重后批量写入 HealthKit。
actor SyncEngine {
    private let client: MiAPIClient
    private let writer: HealthWriter
    private var userId: String?

    /// 增量同步时与上次游标的重叠天数（弥补迟到数据）。
    private let overlapDays = 1

    /// sleep 数据缓存：sleep、respiratoryRate、hrv 三个类型共享同一份睡眠原始数据，
    /// 避免同一次同步中把 sleep key 下载三遍。按 `startTime-endTime` 分片键命中缓存。
    private var sleepCache: [String: [MiItem]] = [:]

    /// 本轮同步已写入的 externalUUID 集合，防止跨时间切片边界的样本被重复写入或误删。
    private var writtenExternalIDs: Set<String> = []

    init(client: MiAPIClient = MiAPIClient(), writer: HealthWriter = HealthWriter()) {
        self.client = client
        self.writer = writer
    }

    /// 清除内部缓存，在一次同步会话开始前调用。
    func clearCache() {
        sleepCache.removeAll()
        writtenExternalIDs.removeAll()
    }

    /// 获取睡眠原始数据，带缓存（相同时间切片窗口只下载一次）。
    private func fetchSleepData(startTime: Int, endTime: Int) async throws -> [MiItem] {
        let key = "\(startTime)-\(endTime)"
        if let cached = sleepCache[key] {
            return cached
        }
        let items = try await client.fetchData(key: "sleep", startTime: startTime, endTime: endTime)
        sleepCache[key] = items
        return items
    }

    /// 登录并校验凭据。
    func connect(userId: String, passToken: String) async throws {
        try await client.connect(userId: userId, passToken: passToken)
        self.userId = userId
    }

    /// 同步单个时间切片的数据，供调用方在每段完成后立即持久化游标。
    func syncSlice(
        type: SyncDataType, slice: SyncWindowSlice, forceBackfill: Bool = false
    ) async throws -> SyncOutcome {
        try Task.checkCancellation()

        // 运动记录用 HKWorkoutBuilder 单独写入（不走通用分组保存）
        if type == .workouts {
            return try await syncWorkouts(
                startTime: slice.startTime, endTime: slice.endTime,
                start: slice.start, end: slice.end, highWater: slice.highWater,
                forceBackfill: forceBackfill
            )
        }

        let groups = try await fetchAndMap(
            type: type, startTime: slice.startTime, endTime: slice.endTime
        )

        var added = 0
        var fetched = 0
        for group in groups {
            try Task.checkCancellation()
            let existing = try await writer.existingExternalIDs(
                ofType: group.sampleType, start: slice.start, end: slice.end
            )
            if forceBackfill {
                // 重新回填 = 重写：删除当前切片范围内已写入的旧样本（排除本轮前序切片刚写入的跨日边界样本），再插入最新数据。
                let toDelete = existing.subtracting(writtenExternalIDs)
                if !toDelete.isEmpty {
                    let chunkSize = 500
                    let all = Array(toDelete)
                    for index in stride(from: 0, to: all.count, by: chunkSize) {
                        let end = min(index + chunkSize, all.count)
                        try await writer.delete(
                            ofType: group.sampleType, externalIDs: Set(all[index..<end])
                        )
                    }
                }
                let objectsToSave = group.objects.filter { object in
                    guard let uuid = object.metadata?[HKMetadataKeyExternalUUID] as? String else {
                        return true
                    }
                    return !writtenExternalIDs.contains(uuid)
                }
                try await writer.save(objectsToSave)
                recordWrittenIDs(from: objectsToSave)
                added += objectsToSave.count
            } else {
                let fresh = group.objects.filter { object in
                    guard let uuid = object.metadata?[HKMetadataKeyExternalUUID] as? String else {
                        return true
                    }
                    return !existing.contains(uuid) && !writtenExternalIDs.contains(uuid)
                }
                try await writer.save(fresh)
                recordWrittenIDs(from: fresh)
                added += fresh.count
            }
            fetched += group.objects.count
        }

        return SyncOutcome(type: type, fetched: fetched, added: added, highWater: slice.highWater)
    }

    /// 拉取单个时间切片的压力数据样本。
    /// 压力数据无 HealthKit 对应类型，由 AppModel 按切片写入 SwiftData。
    func fetchStressSlice(slice: SyncWindowSlice) async throws -> [MiStressSample] {
        try Task.checkCancellation()
        let items = try await client.fetchData(
            key: "stress", startTime: slice.startTime, endTime: slice.endTime
        )
        return MiParser.stressSamples(items)
    }

    // MARK: - 窗口计算

    func syncWindow(
        highWater: Date?, backfillDays: Int, forceBackfill: Bool, now: Date = Date()
    ) -> (start: Date, end: Date, startTime: Int, endTime: Int) {
        let start: Date
        if forceBackfill {
            start = Calendar.current.date(byAdding: .day, value: -backfillDays, to: now) ?? now
        } else if let highWater {
            start = Calendar.current.date(byAdding: .day, value: -overlapDays, to: highWater) ?? highWater
        } else {
            start = Calendar.current.date(byAdding: .day, value: -backfillDays, to: now) ?? now
        }
        return (start, now, MiAPIClient.dayStartEpoch(of: start), MiAPIClient.dayEndEpoch(of: now))
    }

    /// 将总同步时间区间按 `chunkDays`（默认 30 天）切分为连续子窗口，供逐段拉取与推进游标。
    func syncWindows(
        highWater: Date?, backfillDays: Int, forceBackfill: Bool,
        chunkDays: Int = MiAPIClient.maxChunkDays, now: Date = Date()
    ) -> [SyncWindowSlice] {
        let (_, overallEnd, startTime, endTime) = syncWindow(
            highWater: highWater, backfillDays: backfillDays, forceBackfill: forceBackfill, now: now
        )
        let chunks = MiAPIClient.timeChunks(
            startTime: startTime, endTime: endTime, chunkDays: chunkDays
        )
        return chunks.enumerated().map { index, chunk in
            let sliceStart = Date(timeIntervalSince1970: TimeInterval(chunk.startTime))
            let sliceEnd = Date(timeIntervalSince1970: TimeInterval(chunk.endTime))
            let highWater = index == chunks.count - 1 ? overallEnd : sliceEnd
            return SyncWindowSlice(
                start: sliceStart,
                end: sliceEnd,
                startTime: chunk.startTime,
                endTime: chunk.endTime,
                highWater: highWater
            )
        }
    }

    // MARK: - 取数与映射

    private struct HKGroup {
        let sampleType: HKSampleType
        let objects: [HKObject]
    }

    private func fetchAndMap(type: SyncDataType, startTime: Int, endTime: Int) async throws -> [HKGroup] {
        switch type {
        case .dailyActivity:
            let steps = try await client.fetchData(key: "steps", startTime: startTime, endTime: endTime)
            let calories = try await client.fetchData(key: "calories", startTime: startTime, endTime: endTime)
            let samples = MiParser.dailyActivity(stepsItems: steps, calorieItems: calories)
                .flatMap(TypeMapper.dailyActivitySamples)
            return groupBySampleType(samples)

        case .heartRate:
            let hr = try await client.fetchData(key: "heart_rate", startTime: startTime, endTime: endTime)
            let resting = try await client.fetchData(key: "resting_heart_rate", startTime: startTime, endTime: endTime)
            let samples = MiParser.heartRateSamples(hr, restingItems: resting)
                .compactMap(TypeMapper.heartRateSample)
            return groupBySampleType(samples)

        case .sleep:
            let items = try await fetchSleepData(startTime: startTime, endTime: endTime)
            let samples = MiParser.sleepSessions(items).flatMap(TypeMapper.sleepSamples)
            return groupBySampleType(samples)

        case .spo2:
            let items = try await client.fetchData(key: "spo2", startTime: startTime, endTime: endTime)
            let samples = MiParser.spo2Samples(items).compactMap(TypeMapper.spo2Sample)
            return groupBySampleType(samples)

        case .respiratoryRate:
            // 呼吸频率数据来自睡眠记录的 avg_breath，按睡眠时段各写一条样本
            let items = try await fetchSleepData(startTime: startTime, endTime: endTime)
            let samples = MiParser.respiratoryRateSamples(items)
                .compactMap(TypeMapper.respiratoryRateSample)
            return groupBySampleType(samples)

        case .hrv:
            // HRV 数据来自睡眠记录的 avg_hrv / hrv_median，按睡眠时段各写一条样本
            let items = try await fetchSleepData(startTime: startTime, endTime: endTime)
            let samples = MiParser.hrvSamples(items).compactMap(TypeMapper.hrvSample)
            return groupBySampleType(samples)

        case .bodyMeasurements:
            let items = try await client.fetchData(key: "weight", startTime: startTime, endTime: endTime)
            let samples = MiParser.bodyMeasurements(items).flatMap(TypeMapper.bodyMeasurementSamples)
            return groupBySampleType(samples)

        case .stress:
            // 压力数据不走 HealthKit，由 fetchStressSlice 方法处理
            return []

        case .workouts:
            // 不会走到这里：syncSlice() 已将运动路由到 syncWorkouts（HKWorkoutBuilder 专用）
            return []
        }
    }

    /// 运动记录：取数 → 生成草稿 → 用 HKWorkoutBuilder 逐条写入（按 externalUUID 去重）。
    private func syncWorkouts(
        startTime: Int, endTime: Int, start: Date, end: Date, highWater: Date, forceBackfill: Bool
    ) async throws -> SyncOutcome {
        let items = try await client.fetchSportRecords(startTime: startTime, endTime: endTime)
        let drafts = MiParser.workouts(items).compactMap(TypeMapper.workoutDraft)
        let workoutType = HKObjectType.workoutType() as HKSampleType
        let existing = try await writer.existingExternalIDs(ofType: workoutType, start: start, end: end)

        var added = 0
        for draft in drafts {
            try Task.checkCancellation()
            guard !writtenExternalIDs.contains(draft.externalUUID) else { continue }
            if forceBackfill {
                if existing.contains(draft.externalUUID) {
                    try await writer.delete(ofType: workoutType, externalIDs: [draft.externalUUID])
                    // 同时删除关联心率样本（avg_hr / max_hr）
                    let hrType = HKQuantityType(.heartRate) as HKObjectType
                    let hrIDs: Set<String> = [
                        "\(draft.externalUUID)_avg_hr",
                        "\(draft.externalUUID)_max_hr",
                    ]
                    try await writer.delete(ofType: hrType, externalIDs: hrIDs)
                }
                _ = try await writer.saveWorkout(draft)
                writtenExternalIDs.insert(draft.externalUUID)
                added += 1
            } else if !existing.contains(draft.externalUUID) {
                _ = try await writer.saveWorkout(draft)
                writtenExternalIDs.insert(draft.externalUUID)
                added += 1
            }
        }
        return SyncOutcome(type: .workouts, fetched: drafts.count, added: added, highWater: highWater)
    }

    private func recordWrittenIDs(from objects: [HKObject]) {
        for object in objects {
            if let uuid = object.metadata?[HKMetadataKeyExternalUUID] as? String {
                writtenExternalIDs.insert(uuid)
            }
        }
    }

    /// 按 HealthKit 样本类型分组（同一个同步批次内的不同 HK 类型需要分别去重）。
    private func groupBySampleType(_ samples: [HKSample]) -> [HKGroup] {
        Dictionary(grouping: samples, by: { $0.sampleType })
            .map { HKGroup(sampleType: $0.key, objects: $0.value) }
    }
}
