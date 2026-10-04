import HealthKit
import Foundation

/// 幂等写入器，复刻 `healthloom.app` 的 `HealthKitWriter` 模式：
/// - 每个样本带 `HKMetadataKeyExternalUUID`；
/// - 写入前按「类型 + 时间段」一次查询已有的 externalID，内存里 diff 后只保存新增批次；
/// - 更新 = 按 externalID 删除 + 重插（HK 样本不可变）。
actor HealthWriter {
    private let store: HKHealthStore

    init(store: HKHealthStore = HealthKitManager.healthStore) {
        self.store = store
    }

    /// 该类型在 `[start, end]` 内已写入的 externalID 集合。
    /// 使用软边界（不限制 strictStart/strictEnd），确保跨越窗口起点的睡眠会话不会被漏掉。
    func existingExternalIDs(ofType type: HKSampleType, start: Date, end: Date) async throws -> Set<String> {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID),
        ])
        var ids = Set<String>()
        var anchor: Date? = nil
        while true {
            let samples = try await queryPage(type: type, predicate: predicate, anchor: anchor)
            guard !samples.isEmpty else { break }
            for sample in samples {
                if let uuid = sample.metadata?[HKMetadataKeyExternalUUID] as? String {
                    ids.insert(uuid)
                }
                if let last = samples.last, last.startDate > (anchor ?? .distantPast) {
                    anchor = last.startDate
                }
            }
            if samples.count < Self.pageSize { break }
        }
        return ids
    }

    /// 一次性批量保存（空批次直接跳过）。
    func save(_ batch: [HKObject]) async throws {
        guard !batch.isEmpty else { return }
        try await store.save(batch)
    }

    // MARK: - 临时诊断（可整段删除）

    /// 读取窗口内该类型的**全部**样本（不要求带 externalUUID），
    /// 用于看清 HealthKit 里到底有什么（含旧版无 metadata 的样本和其它 App 的样本）。
    func audit(ofType type: HKSampleType, start: Date, end: Date, limit: Int = 5000) async throws -> [DiagSample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: predicate, limit: limit, sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let mapped: [DiagSample] = (samples ?? []).map { sample in
                    var value: String?
                    if let category = sample as? HKCategorySample {
                        value = "category:\(category.value)"
                    } else if let quantity = sample as? HKQuantitySample {
                        value = "\(quantity.quantity)"
                    }
                    return DiagSample(
                        start: sample.startDate,
                        end: sample.endDate,
                        value: value,
                        externalUUID: sample.metadata?[HKMetadataKeyExternalUUID] as? String,
                        source: sample.sourceRevision.source.bundleIdentifier
                    )
                }
                continuation.resume(returning: mapped)
            }
            store.execute(query)
        }
    }

    /// 用 `HKWorkoutBuilder` 构建并保存一条运动记录。
    /// 保留 externalUUID metadata（builder 支持 addMetadata），继续用于去重。
    /// 若草稿包含心率数据，创建关联心率样本并挂载到运动记录上。
    func saveWorkout(_ draft: TypeMapper.WorkoutDraft) async throws -> HKWorkout {
        let config = HKWorkoutConfiguration()
        config.activityType = draft.activityType
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: nil)
        do {
            try await builder.beginCollection(at: draft.start)
            try await builder.addMetadata([HKMetadataKeyExternalUUID: draft.externalUUID])
            try await builder.endCollection(at: draft.end)
            guard let workout = try await builder.finishWorkout() else {
                throw HealthWriterError.workoutBuildFailed
            }

            // 关联心率样本（平均/最大），用 externalUUID 前缀确保去重
            var hrSamples: [HKQuantitySample] = []
            let hrType = HKQuantityType(.heartRate)
            let hrUnit = HKUnit.count().unitDivided(by: .minute())
            if let avg = draft.avgHeartRateBpm, avg > 0 {
                hrSamples.append(HKQuantitySample(
                    type: hrType,
                    quantity: HKQuantity(unit: hrUnit, doubleValue: Double(avg)),
                    start: draft.start, end: draft.end,
                    metadata: [HKMetadataKeyExternalUUID: "\(draft.externalUUID)_avg_hr"]
                ))
            }
            if let max = draft.maxHeartRateBpm, max > 0 {
                hrSamples.append(HKQuantitySample(
                    type: hrType,
                    quantity: HKQuantity(unit: hrUnit, doubleValue: Double(max)),
                    start: draft.start, end: draft.end,
                    metadata: [HKMetadataKeyExternalUUID: "\(draft.externalUUID)_max_hr"]
                ))
            }
            if !hrSamples.isEmpty {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    store.add(hrSamples, to: workout) { success, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if !success {
                            continuation.resume(throwing: HealthWriterError.workoutBuildFailed)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            }

            return workout
        } catch {
            builder.discardWorkout()
            throw error
        }
    }

    enum HealthWriterError: LocalizedError {
        case workoutBuildFailed
        var errorDescription: String? { "运动记录构建失败" }
    }

    /// 按 externalID 删除指定类型的对象，返回删除数量。
    @discardableResult
    func delete(ofType type: HKObjectType, externalIDs: Set<String>) async throws -> Int {
        guard !externalIDs.isEmpty else { return 0 }
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeyExternalUUID,
            allowedValues: Array(externalIDs)
        )
        return try await withCheckedThrowingContinuation { continuation in
            store.deleteObjects(of: type, predicate: predicate) { _, count, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: count)
                }
            }
        }
    }

    /// 删除**本 App** 在 `[start, end]` 内写入的该类型样本，返回删除数量。
    ///
    /// 谓词同时限定「来源 == 本 App」与时间范围（软边界，跨越窗口起点的样本也会命中）。
    /// 因此既能清掉旧版 UUID 方案写下的样本、以及被丢弃的中间版本样本，
    /// 又**绝不会**碰到 Apple Watch 或其它 App 写入的健康数据。
    @discardableResult
    func deleteOwn(ofType type: HKSampleType, start: Date, end: Date) async throws -> Int {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForSamples(withStart: start, end: end),
        ])
        return try await withCheckedThrowingContinuation { continuation in
            store.deleteObjects(of: type, predicate: predicate) { _, count, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: count)
                }
            }
        }
    }

    // MARK: - 分页查询

    private static let pageSize = 1000

    private func queryPage(
        type: HKSampleType, predicate: NSPredicate, anchor: Date?
    ) async throws -> [HKSample] {
        var combined = predicate
        if let anchor {
            combined = NSCompoundPredicate(andPredicateWithSubpredicates: [
                predicate,
                HKQuery.predicateForSamples(withStart: anchor, end: nil),
            ])
        }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: combined,
                limit: Self.pageSize, sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
    }
}
