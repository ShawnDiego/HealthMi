import BackgroundTasks
import Foundation
import os

/// BGAppRefreshTask 后台同步（模拟器不会触发，需真机运行验证）。
enum BackgroundSync {
    static let taskIdentifier = "com.healthmi.HealthMi.sync"

    /// 当前后台同步 Task 引用，用于 expirationHandler 取消。
    @MainActor private static var syncTask: Task<Void, Never>?

    /// BGTask 处理器只能注册一次，重复注册同一标识符会抛异常。
    @MainActor private static var didRegister = false

    @MainActor
    static func register(syncHandler: @escaping @MainActor () async -> Void) {
        guard !didRegister else { return }
        didRegister = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            schedule()
            refreshTask.expirationHandler = {
                // 系统即将挂起进程，取消正在进行的同步
                Task { @MainActor in
                    syncTask?.cancel()
                }
                refreshTask.setTaskCompleted(success: false)
            }
            syncTask = Task { @MainActor in
                await syncHandler()
                refreshTask.setTaskCompleted(success: true)
            }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLog.backgroundSync.error("后台同步调度失败：\(error.localizedDescription)")
        }
    }
}
