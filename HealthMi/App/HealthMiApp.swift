import SwiftData
import SwiftUI

/// 应用共享的 SwiftData 容器：前台 UI、后台刷新和快捷指令 Intent 共用同一实例。
enum AppDatabase {
    static let container: ModelContainer = {
        let schema = Schema([SyncState.self, StressRecord.self, SyncLogEntry.self])
        let configuration = ModelConfiguration(schema: schema)
        do {
            return try ModelContainer(
                for: schema, migrationPlan: MigrationPlan.self,
                configurations: [configuration]
            )
        } catch {
            fatalError("无法初始化 SwiftData 容器：\(error)")
        }
    }()
}

@main
struct HealthMiApp: App {
    let modelContainer: ModelContainer

    @State private var model = AppModel()

    init() {
        modelContainer = AppDatabase.container
        // BGTask 处理器必须在进程启动时就注册：后台拉起时 SwiftUI 场景可能不出现，
        // 放在 .task 里会漏注册，导致进程被杀后后台同步失效
        BackgroundSync.register { [model, modelContainer] in
            let context = modelContainer.mainContext
            await model.syncAll(modelContext: context, isBackground: true)
        }
        BackgroundSync.schedule()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .modelContainer(modelContainer)
                .task {
                    model.bootstrap()
                    await NotificationManager.requestAuthorization()
                    // 回到前台时刷新调度，把最早触发时间尽量拉近
                    BackgroundSync.schedule()
                }
        }
    }
}
