import AppIntents
import Foundation

/// "同步健康数据" App Intent：不打开 App，在后台直接从小米云端拉取数据写入 Apple 健康。
/// 可被快捷指令自动化（如每天定时）静默触发；失败时发送本地通知。
struct SyncHealthDataIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "同步健康数据"
    nonisolated static let description = IntentDescription("从小米云端拉取最新健康数据，写入 Apple 健康")
    nonisolated static let openAppWhenRun = false

    /// 后台执行的预算有限，超时前主动取消，避免被系统硬性挂起。
    private static let syncTimeout: Duration = .seconds(55)

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = AppModel()
        // 补上用户自定义的同步类别开关等持久化状态
        model.bootstrap()
        let syncTask = Task { @MainActor in
            await model.syncAll(
                modelContext: AppDatabase.container.mainContext,
                isBackground: true
            )
        }
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: Self.syncTimeout)
            // 各类型之间是安全断点：取消只会中断在类型边界，已写入的数据不会重复
            syncTask.cancel()
        }
        await syncTask.value
        watchdog.cancel()
        let message = model.statusMessage.isEmpty ? "同步完成" : model.statusMessage
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

/// 快捷指令注册：Siri / 快捷指令 App 中可搜索到「同步健康数据」。
struct HealthMiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncHealthDataIntent(),
            phrases: [
                "同步\(.applicationName)健康数据",
                "同步\(.applicationName)",
                "\(.applicationName)健康同步"
            ],
            shortTitle: "同步健康数据",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
