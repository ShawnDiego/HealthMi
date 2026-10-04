# 更新日志

本文件记录 HealthMi 的版本变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

## [Unreleased]

### 修复

- **睡眠"并集"（同一晚多条卧床、同一时段两个类别）**：小米云端对**同一段睡眠**会返回多条记录——手环在用户每次短暂醒来时都会把它重新定稿一次，`sid` 与 `bedtime` 不变、只有 `wake_up_time` 越写越晚，中间版本带 `is_uncomplete = true`。此前 App 把它们当作独立记录全部写入 HealthKit（一晚最多实测 4 条互相嵌套的 `inBed`，并叠加两套分期，导致同一时段既算深睡又算核心睡）。现在按 `sid + bedtime` 归并、**只保留 `is_uncomplete == false` 的最终版本**（兜底取 `wake_up_time` 最晚者），与小米运动健康官方 App 的入睡/醒来/各分期占比逐项一致（已对 2026-09-21/22/29/30 四晚交叉验证）。
- **`sleepId` 改为按夜晚稳定**：由 `sid_<time>`（`time` 即会变的 `wake_up_time`）改为 `sid_<bedtime>`；HRV 与呼吸频率同步改用归并结果，避免中间版本多写样本。
- **增量同步重复写入**：去重/删除窗口此前用精确时刻，而云端取数窗口被归零到当地 00:00，两者之间留下最长 24 小时的"缝隙"。缝隙内的样本每次增量都会被重新拉取、又查不到"已存在"，于是被原样重写（实测一次增量重复写入 25 条心率 + 11 条血氧 + 1 条睡眠分期；缝隙越宽重复越多，缝隙宽度 = 上次同步的钟点）。现在两个窗口统一使用归零后的起点。
- **睡眠类样本改为"按会话删除 + 重写"**：删除谓词限定「来源 == 本 App」+ 时间范围，因此既能清理旧 UUID 方案与被丢弃的中间版本留下的样本（增量同步即可自愈历史脏数据），又**不会影响 Apple Watch 或其它 App 写入的健康数据**。
- **`timeAsleepMinutes` 少算**：云端 `duration` 本身已是"不含清醒"的睡眠时长（实测 `duration + awake = 起床 - 入睡`），不再重复减去清醒时长。

### 说明

- 历史脏数据（如某一晚的 4 条 `inBed`）需要一次覆盖到它的重新回填才能收敛：若该类别的"起始日期"晚于脏数据日期，请先把起始日期提前（或清除）再回填一次。

## [1.1.0] - 2026-08-16

### 新增

- **多区域支持**：支持中国大陆/俄罗斯/欧洲/国际/新加坡/美国六个区域，自动适配 API 域名和时区，Dashboard 区域选择器
- **Swift Charts 趋势图**：7 天步数/心率/睡眠/HRV 趋势可视化（`HKStatisticsCollectionQuery` 按天查询）
- **每日详情页**：点击趋势图中任一天查看当日全部数据 + 压力记录明细
- **同步历史日志**：持久化每次类型同步的结果（成功/失败/拉取数/新增数），`SyncHistoryView` 列表展示，自动裁剪 200 条
- **同步失败通知**：后台同步失败时发送本地通知，`NotificationManager` 管理授权与发送
- **数据导出**：一键导出最近 7 天每日数据为 CSV，通过系统分享面板发送
- **App Intents / 快捷指令**：通过 Siri 或快捷指令触发同步（"同步 HealthMi 健康数据"）
- **压力数据同步**：新增 `SyncDataType.stress`，从云端拉取压力数据存入 SwiftData，Dashboard 展示 7 天平均压力
- **身体指标补全**：新增写入 BMI（`bodyMassIndex`）、肌肉量（`leanBodyMass`）、基础代谢（`basalEnergyBurned`）
- **运动记录心率**：运动记录关联平均/最大心率样本（`HKWorkoutBuilder` + `store.add(_:to:)`）
- **同步进度文字**：显示"正在同步 3/9"
- **HealthKit 授权实时检测**：每次同步前检查权限状态，被撤销时提示用户
- **统一日志**：`AppLog` 枚举集中管理所有 `os.Logger` 实例
- **SwiftData 迁移策略**：`SchemaV1` + `MigrationPlan`，为未来 schema 变更建立基础设施
- **测试覆盖**：新增 `SyncEngineTests`（窗口计算）、`SyncStateStoreTests`（游标+区域配置）

### 修复

- **后台同步失效**：Info.plist 添加 `BGTaskSchedulerPermittedIdentifiers`，统一 BG Task ID 为 `com.healthmi.HealthMi.sync`，`try?` 改为 do/catch + 日志
- **Sleep 数据重复下载**：SyncEngine 内缓存，sleep/呼吸频率/HRV 共享同一份睡眠原始数据（从 3 次降为 1 次）
- **退出登录不重置游标**：`disconnect()` 清除所有 `SyncState` 游标和压力记录
- **API 无重试/限流**：网络错误指数退避重试（最多 3 次），分页间 200ms 间隔，认证错误不重试，新增 HTTP 状态码检查
- **try? 静默吞错**：`SyncStateStore` 和 `BackgroundSync` 的 save/submit 错误改为 do/catch + Logger
- **睡眠去重边界漏洞**：`HealthWriter` 从 `.strictStartDate/.strictEndDate` 改为软边界
- **Keychain service 迁移**：从旧 `com.example.HealthMi` 一次性迁移到新 `com.healthmi.HealthMi`
- **后台同步任务取消**：存储 sync Task 引用，`expirationHandler` 中 `cancel()`，`syncAll` 检查 `Task.isCancelled`

### 优化

- **HealthKitReader 并行查询**：4 个独立统计查询用 `async let` 并行执行
- **标识符统一**：`project.yml` 的 `bundleIdPrefix` 和测试 bundle ID 从 `com.example` 改为 `com.healthmi`
- **MCP 工具 SQLite 性能**：连接复用 + WAL 模式 + `executemany` 批量插入
- **MCP 工具 0 值修正**：`_optional_float`/`_optional_int` 不再把 0 当 None
- **MCP 工具请求限流**：`iter_*` 方法间 200ms 间隔，可配置 `min_request_interval_seconds`
- **MCP 工具清理死配置**：删除未引用的 `auto_sync_on_start`/`stale_after_minutes`/`store_raw_payloads`

## [1.0.0] - 2026-08-14

### 首次开源发布

- Swift 移植 `mi-fitness-mcp-cn` 取数逻辑
- 8 类数据同步：日常活动、心率、睡眠、血氧、体重/体脂、运动记录
- WebView 登录小米账号 + 手动 Cookie 输入
- 增量同步 + 7/30/90/全部 回填
- 幂等写入（`HKMetadataKeyExternalUUID` 去重）
- Keychain 凭据存储
- `BGAppRefreshTask` 后台同步
- 加密向量单测（RC4/SHA256/SHA1 预言机测试）
