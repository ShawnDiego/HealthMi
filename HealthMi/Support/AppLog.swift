import Foundation
import os

/// 统一日志入口，按 category 分类，便于在 Console.app 中过滤。
enum AppLog {
    static let subsystem = "com.healthmi.HealthMi"

    static let backgroundSync = Logger(subsystem: subsystem, category: "BackgroundSync")
    static let apiClient = Logger(subsystem: subsystem, category: "MiAPIClient")
    static let syncStateStore = Logger(subsystem: subsystem, category: "SyncStateStore")
    static let stressStore = Logger(subsystem: subsystem, category: "StressStore")
    static let syncLogStore = Logger(subsystem: subsystem, category: "SyncLogStore")
    /// 临时诊断（排查睡眠重复写入用，可删除）
    static let diagnostic = Logger(subsystem: subsystem, category: "Diagnostic")
}

// MARK: - 诊断记录（排查同步重复写入用，可长期开启）
//
// 目的：把每次同步的**窗口边界**、**云端原始数据**、**App 自己看到的 HealthKit 现有样本**
// 以及**插入/删除决策**一起落盘，便于事后核对（每次同步一个带时间戳的文件）。
//
// 安全/占用约束：
//   - **不写任何凭据**；
//   - 文件写入 Documents 且标记为不参与备份；
//   - 只保留最近 `keepFiles` 个文件，更早的自动删除。
//
// 如需彻底移除：删除本节 + `AppLog.diagnostic` + `HealthWriter.audit`
// + `SyncEngine` 中 diagnostics / lastSleepItems / diagRawItems / takeDiagnostics 及 sync 内的记录代码
// + `AppModel.writeDiagnosticDump` 及 syncAll 末尾的调用。

struct DiagSample: Codable, Sendable {
    var start: Date
    var end: Date
    var value: String?
    var externalUUID: String?
    var source: String?
}

struct DiagRawItem: Codable, Sendable {
    var time: Int?
    var sid: String?
    var zoneOffset: Int?
    var zoneName: String?
    var key: String?
    var category: String?
    var payload: String?
}

struct DiagGroup: Codable, Sendable {
    var sampleTypeIdentifier: String
    var fetched: Int
    var existingFound: Int
    /// 去重后**真正新增**的样本数（纯重写时为 0）
    var inserted: Int
    var deleted: Int
    /// 去重/删除查询窗口（与云端取数窗口一致）
    var dedupWindowStart: Date
    var dedupWindowEnd: Date
    /// 该类型在窗口内的**全部** HealthKit 样本（不限 externalUUID），
    /// 因此能看出「没带 metadata 的旧样本」与「其它 App 写入的样本」。
    var existingSamplesInDedupWindow: [DiagSample]
}

struct DiagTypeRun: Codable, Sendable {
    var type: String
    var highWater: Date?
    /// 去重/删除用的窗口起点（精确时刻）
    var start: Date
    /// 云端取数窗口（把 start 向下取整到当地 00:00）
    var fetchWindowStart: Date
    var fetchWindowEnd: Date
    var now: Date
    /// 睡眠/呼吸/HRV 共享的睡眠原始数据
    var rawSleepItems: [DiagRawItem]?
    var groups: [DiagGroup]
    var note: String?
}

struct DiagRun: Codable, Sendable {
    var appVersion: String
    var startedAt: Date
    var finishedAt: Date
    var forceBackfill: Bool
    var backfillDays: Int
    var types: [DiagTypeRun]
    /// 最近 10 天 HealthKit 里**所有来源**的睡眠样本
    var healthKitSleepAudit: [DiagSample]
    /// 最近 3 天所有来源的步数样本（判断整日样本是否也被重复写入）
    var healthKitStepAudit: [DiagSample]
    var note: String
}

enum DiagnosticDump {
    /// 最多保留的诊断文件数（每个约 200–450 KB）
    static let keepFiles = 20

    private static func directory() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    static func fileURL(at date: Date, forceBackfill: Bool) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let kind = forceBackfill ? "backfill" : "incremental"
        let name = "healthmi_diagnostic_\(formatter.string(from: date))_\(kind).json"
        return directory()?.appendingPathComponent(name)
    }

    /// 写盘（在后台线程调用）：清理旧文件 → 写新文件 → 裁剪到最近 N 个。
    static func write(_ run: DiagRun) {
        guard let url = fileURL(at: run.finishedAt, forceBackfill: run.forceBackfill) else {
            AppLog.diagnostic.error("找不到 Documents 目录")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(run)
            try data.write(to: url, options: [.atomic])
            try? (url as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
            AppLog.diagnostic.info("诊断已写入 \(url.lastPathComponent, privacy: .public)（\(data.count) 字节）")
        } catch {
            AppLog.diagnostic.error("诊断写入失败：\(error.localizedDescription)")
        }
        pruneOldFiles()
    }

    /// 只保留最近的 `keepFiles` 个诊断文件。
    static func pruneOldFiles() {
        let files = allFiles()
        guard files.count > keepFiles else { return }
        for url in files.dropFirst(keepFiles) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 按文件名（含时间戳）从新到旧排序的诊断文件列表。
    private static func allFiles() -> [URL] {
        guard let dir = directory(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        return names
            .filter { $0.hasPrefix("healthmi_diagnostic_") && $0.hasSuffix(".json") }
            .sorted(by: >)
            .map { dir.appendingPathComponent($0) }
    }
}
