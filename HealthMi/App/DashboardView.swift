import SwiftData
import SwiftUI

/// 主界面：账号/权限状态、同步控制、各类数据游标。
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \SyncState.typeRawValue) private var syncStates: [SyncState]
    @Query(sort: \StressRecord.timestamp, order: .reverse) private var recentStress: [StressRecord]
    @AppStorage("mi_region") private var regionRaw = MiRegion.cn.rawValue
    @State private var showRebackfillConfirm = false
    @State private var showWebLogin = false
    @State private var exportFileURL: URL?

    private var region: MiRegion { .init(rawValue: regionRaw) ?? .cn }

    /// 最近 7 天平均压力值。
    private var avgStress7d: Double? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let recent = recentStress.filter { $0.timestamp >= cutoff }
        guard !recent.isEmpty else { return nil }
        return Double(recent.map(\.stressScore).reduce(0, +)) / Double(recent.count)
    }

    /// “全部”显示为中文，其余显示“N 天”。
    private var backfillDaysLabel: String {
        model.backfillDays == 3650 ? "全部" : "\(model.backfillDays) 天"
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section("账号") {
                    LabeledContent("小米账号", value: model.accountID)
                    LabeledContent("连接状态", value: model.connected ? "已连接" : "未连接")
                    Picker("区域", selection: $regionRaw) {
                        ForEach(MiRegion.allCases) { region in
                            Text(region.displayName).tag(region.rawValue)
                        }
                    }
                    LabeledContent("Apple 健康", value: model.healthKitAuthorized ? "已授权" : "未授权")
                    if !model.healthKitAuthorized {
                        Button("请求健康权限") {
                            Task { try? await model.requestHealthKit() }
                        }
                    }
                    if model.authNeedsRefresh {
                        Label("小米凭据已过期，请更新后重试", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    Button("更新小米凭据") {
                        showWebLogin = true
                    }
                    .sheet(isPresented: $showWebLogin) {
                        MiWebLoginView()
                    }
                }

                // ---------- 增量同步（日常） ----------
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("增量同步", systemImage: "arrow.triangle.2.circlepath")
                            .font(.headline)
                        Text("只同步上次之后的新数据，快、省流量。\n日常每天点一次这里即可。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            Task { await model.syncAll(modelContext: modelContext) }
                        } label: {
                            HStack(spacing: 8) {
                                if model.isSyncing {
                                    ProgressView()
                                    if let progress = model.syncProgressText {
                                        Text(progress).font(.caption)
                                    }
                                }
                                Text(model.isSyncing ? "同步中…" : "立即增量同步")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isSyncing)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("同步")
                } footer: {
                    if !model.statusMessage.isEmpty {
                        Text(model.statusMessage)
                    }
                    if let lastError = model.lastError {
                        Text(lastError)
                            .foregroundStyle(.red)
                    }
                }

                // ---------- 重新回填历史 ----------
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("重新回填历史", systemImage: "clock.arrow.circlepath")
                            .font(.headline)
                        Text("忽略增量游标，按所选范围全量重拉并重写。\n用于补历史或修正数据，不会产生重复。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Picker("回填范围", selection: $model.backfillDays) {
                            Text("7 天").tag(7)
                            Text("30 天").tag(30)
                            Text("90 天").tag(90)
                            Text("全部（3650 天）").tag(3650)
                        }
                        .pickerStyle(.menu)

                        Button("重新回填 \(backfillDaysLabel)") {
                            showRebackfillConfirm = true
                        }
                        .disabled(model.isSyncing)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("重新回填")
                }
                .confirmationDialog(
                    "重新回填 \(backfillDaysLabel)？",
                    isPresented: $showRebackfillConfirm,
                    titleVisibility: .visible
                ) {
                    Button("回填 \(backfillDaysLabel)", role: .destructive) {
                        Task { await model.syncAll(modelContext: modelContext, forceBackfill: true) }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("将从最早 \(backfillDaysLabel) 重新拉取并重写。由于按 externalID 去重，已存在的数据不会重复。")
                }

                // ---------- 数据概览 ----------
                Section {
                    summaryRow("步数", value: model.summary?.stepCount.map { "\(Int($0)) 步" })
                    summaryRow("睡眠", value: model.summary?.sleepMinutes.map { String(format: "%.1f 小时", $0 / 60) })
                    summaryRow("平均心率", value: model.summary?.avgHeartRate.map { String(format: "%.0f 次/分", $0) })
                    summaryRow("平均呼吸频率", value: model.summary?.avgRespiratoryRate.map { String(format: "%.0f 次/分", $0) })
                    summaryRow("平均 HRV", value: model.summary?.avgHRV.map { String(format: "%.0f ms", $0) })
                    summaryRow("平均压力", value: avgStress7d.map { String(format: "%.0f", $0) })
                } header: {
                    Text("数据概览（最近 7 天）")
                } footer: {
                    Text("从 Apple 健康读回，需已授权相应数据类型。")
                }

                // ---------- 数据导出 ----------
                Section {
                    Button {
                        let csv = DataExporter.exportCSV(days: 7, trends: model.trends, stressRecords: recentStress)
                        exportFileURL = DataExporter.writeCSV(csv)
                    } label: {
                        Label("导出最近 7 天数据（CSV）", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.trends.isEmpty)
                } header: {
                    Text("数据导出")
                }

                // ---------- 趋势图 ----------
                Section {
                    if model.trends.isEmpty {
                        Text("暂无趋势数据")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        TrendChartsSection()
                        ForEach(model.trends.reversed(), id: \.date) { trend in
                            NavigationLink {
                                DayDetailView(trend: trend, stressRecords: recentStress)
                            } label: {
                                daySummaryRow(trend)
                            }
                        }
                    }
                } header: {
                    Text("趋势（最近 7 天）")
                }

                // ---------- 同步类别 ----------
                Section {
                    ForEach(SyncDataType.allCases) { type in
                        Toggle(type.displayName, isOn: Binding(
                            get: { model.isTypeEnabled(type) },
                            set: { model.setTypeEnabled(type, enabled: $0) }
                        ))
                    }
                } header: {
                    Text("同步类别")
                } footer: {
                    Text("每个类别独立记录同步进度，关闭的类别不会同步，也不会更新进度。")
                }

                // ---------- 各类数据状态 ----------
                Section {
                    ForEach(SyncDataType.allCases) { type in
                        statusRow(type)
                    }
                } header: {
                    Text("各类数据状态")
                } footer: {
                    Text("「上次同步」就是该类的增量进度；下次增量从它往前 1 天开始拉取。")
                }

                Section {
                    Button("退出登录并清除小米凭据", role: .destructive) {
                        model.disconnect(modelContext: modelContext)
                    }
                }
            }
            .navigationTitle("HealthMi")
            .toolbar {
                NavigationLink {
                    SyncHistoryView()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
            }
            .task {
                await model.refreshSummary()
            }
            .refreshable { await model.syncAll(modelContext: modelContext) }
            .sheet(isPresented: Binding(
                get: { exportFileURL != nil },
                set: { if !$0 { exportFileURL = nil } }
            )) {
                if let exportFileURL {
                    ShareSheet(items: [exportFileURL])
                }
            }
        }
    }

    private func summaryRow(_ title: String, value: String?) -> some View {
        LabeledContent(title) {
            if let value {
                Text(value)
                    .foregroundStyle(.primary)
            } else {
                Text("—")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func daySummaryRow(_ trend: DailyTrend) -> some View {
        HStack {
            Text(trend.date.formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(trend.stepCount.map { "\(Int($0)) 步" } ?? "—")
                .font(.caption)
        }
    }

    private func statusRow(_ type: SyncDataType) -> some View {
        let enabled = model.isTypeEnabled(type)
        let state = syncStates.first { $0.typeRawValue == type.rawValue }
        let outcome = model.outcomes[type]
        return LabeledContent(type.displayName) {
            if !enabled {
                Text("已关闭")
                    .foregroundStyle(.tertiary)
            } else if let state, let last = state.lastSyncAt {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("上次 \(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let outcome {
                        Text("新增 \(outcome.added) · 拉取 \(outcome.fetched)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("未同步")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    DashboardView()
        .environment(AppModel())
        .modelContainer(for: [SyncState.self, StressRecord.self])
}

/// UIActivityViewController 的 SwiftUI 包装。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
