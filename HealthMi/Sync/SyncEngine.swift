import Foundation
import HealthKit

/// 单次同步的结果摘要。
struct SyncOutcome: Sendable {
    let type: SyncDataType
    let fetched: Int
    let added: Int
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
    /// 避免同一次同步中把 sleep key 下载三遍。按 (startTime, endTime) 命中缓存。
    private var sleepCache: (startTime: Int, endTime: Int, items: [MiItem])?

    // MARK: - 临时诊断（排查重复写入用，可整段删除）

    private var diagnostics: [DiagTypeRun] = []
    private var lastSleepItems: [MiItem] = []

    /// 取出并清空本次同步记录下来的诊断数据。
    func takeDiagnostics() -> [DiagTypeRun] {
        let result = diagnostics
        diagnostics = []
        return result
    }

    private func diagRawItems(_ items: [MiItem]) -> [DiagRawItem] {
        items.map { item in
            DiagRawItem(
                time: item.time,
                sid: item.sid,
                zoneOffset: item.zoneOffset,
                zoneName: item.zoneName,
                key: item.key,
                category: item.category,
                payload: item.valueData.flatMap { String(data: $0, encoding: .utf8) }
            )
        }
    }

    init(client: MiAPIClient = MiAPIClient(), writer: HealthWriter = HealthWriter()) {
        self.client = client
        self.writer = writer
    }

    /// 清除内部缓存，在一次同步会话开始前调用。
    func clearCache() {
        sleepCache = nil
    }

    /// 获取睡眠原始数据，带缓存（相同时间窗口只下载一次）。
    private func fetchSleepData(startTime: Int, endTime: Int) async throws -> [MiItem] {
        if let cache = sleepCache, cache.startTime == startTime, cache.endTime == endTime {
            return cache.items
        }
        let items = try await client.fetchData(key: "sleep", startTime: startTime, endTime: endTime)
        sleepCache = (startTime, endTime, items)
        return items
    }

    /// 登录并校验凭据。
    func connect(userId: String, passToken: String) async throws {
        try await client.connect(userId: userId, passToken: passToken)
        self.userId = userId
    }

    /// 同步一类数据。
    /// - Parameters:
    ///   - highWater: 上次游标；`nil` 表示首次同步
    ///   - backfillDays: 回填天数（仅在无游标或 `forceBackfill` 时生效）
    ///   - forceBackfill: 为 true 时忽略游标，按 `backfillDays` 重新拉取历史
    func sync(
        type: SyncDataType, highWater: Date?, backfillDays: Int,
        forceBackfill: Bool = false
    ) async throws -> SyncOutcome {
        let (start, now, startTime, endTime) = syncWindow(
            highWater: highWater, backfillDays: backfillDays,
            forceBackfill: forceBackfill
        )

        // 运动记录用 HKWorkoutBuilder 单独写入（不走通用分组保存）
        if type == .workouts {
            return try await syncWorkouts(
                startTime: startTime, endTime: endTime, start: start, end: now,
                forceBackfill: forceBackfill
            )
        }

        lastSleepItems = []
        let groups = try await fetchAndMap(type: type, startTime: startTime, endTime: endTime)

        // 取数窗口的起点：云端查询用的是「归零到当地 00:00」的时刻。
        // 去重/删除必须使用**同一个下界**，否则 [dayStart(start), start) 区间内的样本
        // 每次都会被重新拉取、又查不到「已存在」，从而被重复写入（实测每小时缝隙会重复
        // 睡眠/心率/血氧样本，缝隙宽度 = 上次同步的钟点）。
        let windowStart = Date(timeIntervalSince1970: TimeInterval(startTime))
        // 上界同理：取数用的是「今天 23:59:59」，去重也必须用同一个上界。
        // 云端会为当天预生成记录（如今天 08:00 的静息心率），它落在 [now, dayEnd] 之间：
        // 每次同步都拉得到、却永远查不到「已存在」，于是每次都被重复写入。
        let windowEnd = Date(timeIntervalSince1970: TimeInterval(endTime))

        // 睡眠类（sleep / HRV / 呼吸频率）改为「按会话删除 + 重写」：
        // 一晚的多条云端记录（is_uncomplete 中间版本）已由 MiParser 归并为最终版本，
        // 这里按每个会话的覆盖区间删除**本 App 自己**写过的样本（含旧 UUID 方案、
        // 含被丢弃的中间版本），再整批写入，因此增量和回填都能自动收敛历史脏数据。
        let isSessionType = (type == .sleep || type == .respiratoryRate || type == .hrv)
        let coverages = isSessionType ? MiParser.sleepSessionCoverages(lastSleepItems) : []

        var added = 0
        var fetched = 0
        var diagGroups: [DiagGroup] = []
        for group in groups {
            var inserted = 0
            var deletedCount = 0
            // 诊断：删除前先看清窗口内 HealthKit 实际持有什么
            let audited = (try? await writer.audit(
                ofType: group.sampleType, start: windowStart, end: windowEnd
            )) ?? []
            var existingCount = audited.count

            if isSessionType {
                let preUUIDs = Set(audited.compactMap(\.externalUUID))
                for coverage in coverages {
                    deletedCount += (try? await writer.deleteOwn(
                        ofType: group.sampleType,
                        start: Date(timeIntervalSince1970: TimeInterval(coverage.start)),
                        end: Date(timeIntervalSince1970: TimeInterval(coverage.end))
                    )) ?? 0
                }
                try await writer.save(group.objects)
                // "新增"按去重后仍然不存在的 UUID 统计：纯重写（数据被修正）时显示 +0，
                // 只有真正新写入的会话才计入新增。
                inserted = group.objects.filter { object in
                    guard let uuid = object.metadata?[HKMetadataKeyExternalUUID] as? String else {
                        return true
                    }
                    return !preUUIDs.contains(uuid)
                }.count
                added += inserted
            } else {
                let existing = try await writer.existingExternalIDs(
                    ofType: group.sampleType, start: windowStart, end: windowEnd
                )
                existingCount = existing.count
                if forceBackfill {
                    // 重新回填 = 重写：删除范围内**我们已写入的所有样本**（外部 ID 匹配），再插入最新数据。
                    // 删除全部而非仅交集，是为了清理旧版写入的已废弃样本（如旧的整晚 asleep 聚合样本）。
                    // 分块删除，避免单个谓词过长（大量样本时）。
                    if !existing.isEmpty {
                        let chunkSize = 500
                        let all = Array(existing)
                        for index in stride(from: 0, to: all.count, by: chunkSize) {
                            let end = min(index + chunkSize, all.count)
                            deletedCount += try await writer.delete(
                                ofType: group.sampleType, externalIDs: Set(all[index..<end])
                            )
                        }
                    }
                    try await writer.save(group.objects)
                    // 与增量路径一致："新增"只统计去重后确实不存在的 UUID，
                    // 纯重写（回填修正）时显示 +0，拉取数仍然反映改写量。
                    inserted = group.objects.filter { object in
                        guard let uuid = object.metadata?[HKMetadataKeyExternalUUID] as? String else {
                            return true
                        }
                        return !existing.contains(uuid)
                    }.count
                    added += inserted
                } else {
                    let fresh = group.objects.filter { object in
                        guard let uuid = object.metadata?[HKMetadataKeyExternalUUID] as? String else {
                            return true
                        }
                        return !existing.contains(uuid)
                    }
                    try await writer.save(fresh)
                    added += fresh.count
                    inserted = fresh.count
                }
            }
            fetched += group.objects.count

            // 临时诊断：记录去重窗口内 HealthKit 实际持有的样本（删除前的快照）
            diagGroups.append(DiagGroup(
                sampleTypeIdentifier: group.sampleType.identifier,
                fetched: group.objects.count,
                existingFound: existingCount,
                inserted: inserted,
                deleted: deletedCount,
                dedupWindowStart: windowStart,
                dedupWindowEnd: windowEnd,
                existingSamplesInDedupWindow: audited
            ))
        }

        diagnostics.append(DiagTypeRun(
            type: type.rawValue,
            highWater: highWater,
            start: start,
            fetchWindowStart: Date(timeIntervalSince1970: TimeInterval(startTime)),
            fetchWindowEnd: Date(timeIntervalSince1970: TimeInterval(endTime)),
            now: now,
            rawSleepItems: [.sleep, .respiratoryRate, .hrv].contains(type)
                ? diagRawItems(lastSleepItems) : nil,
            groups: diagGroups,
            note: nil
        ))

        return SyncOutcome(type: type, fetched: fetched, added: added, highWater: now)
    }

    /// 压力数据同步：从云端拉取 stress key，返回解析后的压力样本。
    /// 压力数据无 HealthKit 对应类型，由 AppModel 写入 SwiftData。
    /// - Returns: (压力样本列表, 同步结果摘要)
    func syncStress(
        highWater: Date?, backfillDays: Int, forceBackfill: Bool = false
    ) async throws -> (samples: [MiStressSample], outcome: SyncOutcome) {
        let (start, now, startTime, endTime) = syncWindow(
            highWater: highWater, backfillDays: backfillDays, forceBackfill: forceBackfill
        )
        let items = try await client.fetchData(key: "stress", startTime: startTime, endTime: endTime)
        let samples = MiParser.stressSamples(items)
        return (samples, SyncOutcome(type: .stress, fetched: samples.count, added: 0, highWater: now))
    }

    // MARK: - 窗口计算

    func syncWindow(
        highWater: Date?, backfillDays: Int, forceBackfill: Bool
    ) -> (start: Date, end: Date, startTime: Int, endTime: Int) {
        let now = Date()
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
            lastSleepItems = items
            let samples = MiParser.sleepSessions(items).flatMap(TypeMapper.sleepSamples)
            return groupBySampleType(samples)

        case .spo2:
            let items = try await client.fetchData(key: "spo2", startTime: startTime, endTime: endTime)
            let samples = MiParser.spo2Samples(items).compactMap(TypeMapper.spo2Sample)
            return groupBySampleType(samples)

        case .respiratoryRate:
            // 呼吸频率数据来自睡眠记录的 avg_breath，按睡眠时段各写一条样本
            let items = try await fetchSleepData(startTime: startTime, endTime: endTime)
            lastSleepItems = items
            let samples = MiParser.respiratoryRateSamples(items)
                .compactMap(TypeMapper.respiratoryRateSample)
            return groupBySampleType(samples)

        case .hrv:
            // HRV 数据来自睡眠记录的 avg_hrv / hrv_median，按睡眠时段各写一条样本
            let items = try await fetchSleepData(startTime: startTime, endTime: endTime)
            lastSleepItems = items
            let samples = MiParser.hrvSamples(items).compactMap(TypeMapper.hrvSample)
            return groupBySampleType(samples)

        case .bodyMeasurements:
            let items = try await client.fetchData(key: "weight", startTime: startTime, endTime: endTime)
            let samples = MiParser.bodyMeasurements(items).flatMap(TypeMapper.bodyMeasurementSamples)
            return groupBySampleType(samples)

        case .stress:
            // 压力数据不走 HealthKit，由 syncStress 方法处理
            return []

        case .workouts:
            // 不会走到这里：sync() 已将运动路由到 syncWorkouts（HKWorkoutBuilder 专用）
            return []
        }
    }

    /// 运动记录：取数 → 生成草稿 → 用 HKWorkoutBuilder 逐条写入（按 externalUUID 去重）。
    private func syncWorkouts(
        startTime: Int, endTime: Int, start: Date, end: Date, forceBackfill: Bool
    ) async throws -> SyncOutcome {
        let items = try await client.fetchSportRecords(startTime: startTime, endTime: endTime)
        let drafts = MiParser.workouts(items).compactMap(TypeMapper.workoutDraft)
        let workoutType = HKObjectType.workoutType() as HKSampleType
        let existing = try await writer.existingExternalIDs(ofType: workoutType, start: start, end: end)

        var added = 0
        for draft in drafts {
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
                added += 1
            } else if !existing.contains(draft.externalUUID) {
                _ = try await writer.saveWorkout(draft)
                added += 1
            }
        }
        return SyncOutcome(type: .workouts, fetched: drafts.count, added: added, highWater: Date())
    }

    /// 按 HealthKit 样本类型分组（同一个同步批次内的不同 HK 类型需要分别去重）。
    private func groupBySampleType(_ samples: [HKSample]) -> [HKGroup] {
        Dictionary(grouping: samples, by: { $0.sampleType })
            .map { HKGroup(sampleType: $0.key, objects: $0.value) }
    }
}
