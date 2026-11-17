import Foundation
import os

enum MiAPIError: LocalizedError {
    case notConnected
    case api(code: Int, message: String?)
    case paginationLimit(key: String, page: Int, latestDate: String?)
    case cursorLoop
    case invalidResponse(String)
    case network(Error)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "尚未登录小米服务"
        case .api(let code, let message):
            return "小米 API 错误（code=\(code)）：\(message ?? "未知")"
        case .paginationLimit(let key, let page, let date):
            let d = date ?? "未知时间"
            return "[\(key)] 分页超安全上限(\(page)页)，当前卡在: \(d)"
        case .cursorLoop:
            return "分页游标循环，已终止"
        case .invalidResponse(let detail):
            return "响应解析失败：\(detail)"
        case .network(let error):
            return "网络错误：\(error.localizedDescription)"
        case .http(let code):
            return "HTTP 错误：\(code)"
        }
    }

    /// 是否可重试（网络错误、429/5xx 类 HTTP 错误）。
    var isRetriable: Bool {
        switch self {
        case .network: return true
        case .http(let code): return code == 429 || (500...599).contains(code)
        default: return false
        }
    }

    /// 是否认证错误（passToken 过期/无效，code=70016），不可重试。
    var isAuthError: Bool {
        if case .api(let code, _) = self, code == 70016 { return true }
        return false
    }
}

/// 小米健康云数据客户端。Swift 移植自 `mi_fitness_cloud.MiFitnessCloudAdapter`。
///
/// 行为要点（与 Python 完全一致）：
/// - 用 Cookie 登录换取 `ssecurity` 与重定向会话 Cookie；
/// - 每个请求体用 `signed_nonce = SHA256(ssecurity||nonce)` 做 RC4 加密 + SHA1 签名；
/// - 数据接口 `get_fitness_data_by_time` 按 key 分页拉取；
/// - 运动记录走独立的 `get_sport_records_by_time`。
actor MiAPIClient {
    /// 当前区域的时区（用于日边界计算）。
    static var regionTimeZone: TimeZone { MiRegion.current.timeZone }


    /// 单次时间切片最大跨度（天数）。大范围回填按此粒度分段请求，避免单段触发分页上限。
    static let maxChunkDays = 30

    /// 最多重试次数（不含首次请求）。
    private let maxRetries = 3
    /// 分页请求间隔（纳秒），避免高频请求触发小米限流。
    private let pageDelayNs: UInt64 = 200_000_000

    private var baseURL: String { MiRegion.current.baseURL }
    private let dataPath = "/app/v1/data/get_fitness_data_by_time"
    private let sportRecordsPath = "/app/v1/data/get_sport_records_by_time"
    private let maxPages = 200

    private var state: MiSessionState?
    private let session: URLSession
    /// 复用日志时间戳格式化器（固定 en_US_POSIX，格式化时绑定当前区域时区）。
    private let logDateFormatter: DateFormatter

    init() {
        let config = URLSessionConfiguration.ephemeral
        // 与 Python 一致：手动管理 Cookie，不交给 URLSession 的存储。
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
        self.logDateFormatter = Self.makeLogDateFormatter()
    }

    var isConnected: Bool { state != nil }

    /// 登录并建立会话。
    func connect(userId: String, passToken: String) async throws {
        self.state = try await MiSessionClient.login(userId: userId, passToken: passToken)
    }

    // MARK: - 请求签名与发送（对应 Python `_request`）

    /// 按 Python 端字典插入顺序（start_time, end_time, key, limit?, next_key?）生成紧凑 JSON，
    /// 保证与已验证实现逐字节一致（JSONSerialization 的键序不确定，不能使用）。
    static func dataString(
        startTime: Int, endTime: Int, key: String, limit: Int? = nil, nextKey: String? = nil
    ) -> String {
        var s = "{\"start_time\":\(startTime),\"end_time\":\(endTime),\"key\":\"\(key)\""
        if let limit { s += ",\"limit\":\(limit)" }
        if let nextKey { s += ",\"next_key\":\"\(nextKey)\"" }
        s += "}"
        return s
    }

    /// 带重试的签名请求：网络错误和 429/5xx HTTP 错误自动重试，
    /// 认证错误（code=70016）不重试直接抛出。
    private func signedRequest(path: String, dataString: String) async throws -> [String: Any] {
        let retries = maxRetries
        var lastError: Error?
        for attempt in 0...retries {
            try Task.checkCancellation()
            if attempt > 0 {
                // 指数退避：1s → 2s → 4s，加 0–200ms 随机抖动
                let baseDelay = UInt64(pow(2.0, Double(attempt - 1))) * 1_000_000_000
                let jitter = UInt64.random(in: 0...200_000_000)
                AppLog.apiClient.info("重试 \(attempt)/\(retries) path=\(path)")
                try await Task.sleep(nanoseconds: baseDelay + jitter)
            }
            do {
                return try await signedRequestOnce(path: path, dataString: dataString)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as MiAPIError {
                if error.isAuthError || !error.isRetriable {
                    throw error
                }
                lastError = error
            } catch {
                lastError = error
            }
        }
        throw lastError ?? MiAPIError.invalidResponse("重试耗尽")
    }

    private func signedRequestOnce(path: String, dataString: String) async throws -> [String: Any] {
        guard let state else { throw MiAPIError.notConnected }

        var form: [String: String] = ["data": dataString]
        let nonce = MiCrypto.genNonce()
        let signedNonce = MiCrypto.genSignedNonce(ssecurity: state.ssecurity, nonce: nonce)

        // 第一次签名只含 data
        form["rc4_hash__"] = MiCrypto.genSignature(
            method: "POST", path: path, values: form, signedNonce: signedNonce
        )

        // 用 RC4 加密 data 与 rc4_hash__，再对加密值签名
        var encrypted: [String: String] = [:]
        for (key, value) in form {
            let cipher = MiCrypto.rc4Crypt(key: signedNonce, payload: Array(value.utf8))
            encrypted[key] = Data(cipher).base64EncodedString()
        }
        encrypted["signature"] = MiCrypto.genSignature(
            method: "POST", path: path, values: encrypted, signedNonce: signedNonce
        )
        encrypted["_nonce"] = Data(nonce).base64EncodedString()

        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "POST"
        request.setValue(state.cookies, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Python `urlencode`：值做百分号编码（Base64 中的 + / = 必须转义）
        let body = encrypted
            .map { "\($0.key)=\(percentEncode($0.value))" }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MiAPIError.network(error)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            AppLog.apiClient.error("HTTP \(http.statusCode) path=\(path)")
            throw MiAPIError.http(http.statusCode)
        }
        guard let base64 = String(data: data, encoding: .utf8),
              let cipher = Data(base64Encoded: base64)
        else {
            throw MiAPIError.invalidResponse("响应不是合法 Base64")
        }

        let plain = MiCrypto.rc4Crypt(key: signedNonce, payload: Array(cipher))
        guard let obj = MiJSON.object(from: Data(plain)) else {
            throw MiAPIError.invalidResponse("解密后不是合法 JSON")
        }
        let code = MiJSON.int(obj["code"]) ?? -1
        guard code == 0 else {
            throw MiAPIError.api(code: code, message: MiJSON.string(obj["message"]))
        }
        // 与 Python 一致：返回内层 result 字典（data_list / sport_records 都在里面）
        return MiJSON.object(from: Data(plain))?["result"] as? [String: Any] ?? [:]
    }

    private func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    // MARK: - 分页拉取

    /// 按 key 拉取某时间区间的数据（对应 `_fetch_key`）。
    func fetchData(key: String, startTime: Int, endTime: Int) async throws -> [MiItem] {
        try await fetchPaginated(
            key: key,
            logLabel: key,
            path: dataPath,
            listKey: "data_list",
            limit: nil,
            startTime: startTime,
            endTime: endTime
        )
    }

    /// 拉取运动记录（对应 `_fetch_sport_records_by_time`）。
    func fetchSportRecords(startTime: Int, endTime: Int) async throws -> [MiItem] {
        try await fetchPaginated(
            key: "sport",
            logLabel: "运动记录",
            path: sportRecordsPath,
            listKey: "sport_records",
            limit: 50,
            startTime: startTime,
            endTime: endTime
        )
    }

    /// 按时间切片 + 单段分页拉取通用逻辑。
    /// 若请求跨度超过 `maxChunkDays`，自动切分为连续时间段依次拉取，单段内由 `maxPages` 保护，
    /// 每页及切片间均执行 `Task.checkCancellation()`。
    private func fetchPaginated(
        key: String,
        logLabel: String,
        path: String,
        listKey: String,
        limit: Int?,
        startTime: Int,
        endTime: Int
    ) async throws -> [MiItem] {
        let chunks = Self.timeChunks(startTime: startTime, endTime: endTime, chunkDays: Self.maxChunkDays)
        var allItems: [MiItem] = []

        for chunk in chunks {
            try Task.checkCancellation()
            let chunkItems = try await fetchSingleChunk(
                key: key,
                logLabel: logLabel,
                path: path,
                listKey: listKey,
                limit: limit,
                startTime: chunk.startTime,
                endTime: chunk.endTime
            )
            allItems.append(contentsOf: chunkItems)
        }
        return allItems
    }

    private func fetchSingleChunk(
        key: String,
        logLabel: String,
        path: String,
        listKey: String,
        limit: Int?,
        startTime: Int,
        endTime: Int
    ) async throws -> [MiItem] {
        var items: [MiItem] = []
        var nextKey: String?
        var seen = Set<String>()
        var page = 0
        let rangeStart = formatEpoch(startTime)
        let rangeEnd = formatEpoch(endTime)
        AppLog.apiClient.info(
            "开始拉取 [\(logLabel, privacy: .public)] 区间: \(rangeStart, privacy: .public) ~ \(rangeEnd, privacy: .public)"
        )

        while true {
            try Task.checkCancellation()
            page += 1
            if page > maxPages {
                let lastDateStr = items.last?.time.map(formatEpoch)
                AppLog.apiClient.error(
                    "分页超限 [\(logLabel, privacy: .public)] 达到 \(self.maxPages, privacy: .public) 页上限，最后一条数据时间: \(lastDateStr ?? "无", privacy: .public)"
                )
                throw MiAPIError.paginationLimit(key: key, page: page, latestDate: lastDateStr)
            }

            let body = Self.dataString(
                startTime: startTime, endTime: endTime, key: key, limit: limit, nextKey: nextKey
            )
            let result = try await signedRequest(path: path, dataString: body)

            var newCount = 0
            if let list = result[listKey] as? [[String: Any]] {
                let mapped = list.map(Self.makeItem)
                newCount = mapped.count
                items.append(contentsOf: mapped)
            }

            let hasMore = MiJSON.bool(result["has_more"]) ?? false
            let cursor = MiJSON.string(result["next_key"])
            let curDateStr = items.last?.time.map(formatEpoch) ?? "无"
            AppLog.apiClient.debug(
                "[\(logLabel, privacy: .public)] 第 \(page, privacy: .public) 页: +\(newCount, privacy: .public) 条 (累计 \(items.count, privacy: .public) 条), 最新时间: \(curDateStr, privacy: .public)"
            )

            guard hasMore, let cursor else { break }
            if seen.contains(cursor) {
                AppLog.apiClient.error("游标死循环 [\(logLabel, privacy: .public)] 游标重复: \(cursor, privacy: .public)")
                throw MiAPIError.cursorLoop
            }
            seen.insert(cursor)
            nextKey = cursor
            // 分页请求间隔，避免高频请求触发小米限流
            try await Task.sleep(nanoseconds: pageDelayNs)
        }
        AppLog.apiClient.info(
            "拉取完成 [\(logLabel, privacy: .public)] 共 \(page, privacy: .public) 页, \(items.count, privacy: .public) 条数据"
        )
        return items
    }

    // MARK: - 时间换算与切片（绑定区域时区）

    /// 将大时间区间按固定天数（默认 `maxChunkDays = 30`）切分为首尾相接的子区间。
    static func timeChunks(
        startTime: Int, endTime: Int, chunkDays: Int = maxChunkDays
    ) -> [(startTime: Int, endTime: Int)] {
        guard startTime <= endTime, chunkDays > 0 else { return [] }
        let chunkSpan = chunkDays * 86_400
        var chunks: [(startTime: Int, endTime: Int)] = []
        var currentStart = startTime
        while currentStart <= endTime {
            let currentEnd = min(currentStart + chunkSpan - 1, endTime)
            chunks.append((startTime: currentStart, endTime: currentEnd))
            if currentEnd >= endTime { break }
            currentStart = currentEnd + 1
        }
        return chunks
    }

    /// 创建绑定 `en_US_POSIX` 与指定时区（默认区域时区）的日志时间格式化器。
    static func makeLogDateFormatter(timeZone: TimeZone = regionTimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }

    /// 按指定时区（默认当前区域时区）将秒级时间戳格式化为 `yyyy-MM-dd HH:mm:ss`。
    static func formatTimestamp(_ epoch: Int, timeZone: TimeZone = regionTimeZone) -> String {
        makeLogDateFormatter(timeZone: timeZone)
            .string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    private func formatEpoch(_ epoch: Int) -> String {
        logDateFormatter.timeZone = Self.regionTimeZone
        return logDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    /// 某日历日 00:00:00(+08:00) 的时间戳。
    static func dayStartEpoch(of day: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.regionTimeZone
        let start = cal.startOfDay(for: day)
        return Int(start.timeIntervalSince1970)
    }

    /// 某日历日 23:59:59(+08:00) 的时间戳。
    static func dayEndEpoch(of day: Date) -> Int {
        dayStartEpoch(of: day) + 86_399
    }

    // MARK: - 原始条目提取

    private static func makeItem(_ raw: [String: Any]) -> MiItem {
        var valueData: Data?
        if let string = raw["value"] as? String {
            valueData = Data(string.utf8)
        } else if let dict = raw["value"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: dict) {
            valueData = data
        } else if let arr = raw["value"] as? [Any],
                  let data = try? JSONSerialization.data(withJSONObject: arr) {
            valueData = data
        }
        return MiItem(
            time: MiJSON.int(raw["time"]),
            zoneOffset: MiJSON.int(raw["zone_offset"]),
            zoneName: MiJSON.string(raw["zone_name"]),
            sid: MiJSON.string(raw["sid"]),
            key: MiJSON.string(raw["key"]),
            category: MiJSON.string(raw["category"]),
            valueData: valueData
        )
    }
}
