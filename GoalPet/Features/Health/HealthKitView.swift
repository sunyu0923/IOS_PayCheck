// Standalone NavigationStack destination. No AppViewModel, repository, or Watch dependency.
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class HealthKitController {
    private(set) var selected: Set<HealthMetric> = []
    private(set) var snapshot: HealthSnapshot?
    private(set) var message: String?
    private(set) var isBusy = false

    @ObservationIgnored private let service: any HealthDataService
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    var isAvailable: Bool { service.isAvailable }

    init(service: any HealthDataService) {
        self.service = service
        // No authorization request or read on construction/appearance.
    }

    func setSelected(_ metric: HealthMetric, enabled: Bool) {
        guard selected.contains(metric) != enabled else { return }
        cancelAndClear()
        if enabled { selected.insert(metric) }
        else { selected.remove(metric) }
    }

    @discardableResult
    func requestPermissions() -> Task<Void, Never>? {
        begin(requestPermissions: true)
        return operation
    }

    @discardableResult
    func refresh() -> Task<Void, Never>? {
        begin(requestPermissions: false)
        return operation
    }

    func reset() {
        cancelAndClear()
        selected = []
        message = "已清空本页内存数据和选择。此操作不会撤销系统权限；请在系统健康设置中管理权限。"
    }

    func cancelAndClear() {
        generation += 1
        operation?.cancel()
        operation = nil
        snapshot = nil
        message = nil
        isBusy = false
    }

    private func begin(requestPermissions: Bool) {
        cancelAndClear()
        guard !selected.isEmpty else {
            message = "请先选择要读取的数据类型。"
            return
        }
        guard isAvailable else {
            message = HealthDataError.unavailable.message
            return
        }
        let token = generation
        let metrics = selected
        let service = self.service
        isBusy = true
        operation = Task { [weak self] in
            do {
                if requestPermissions {
                    try await service.requestReadAuthorization(for: metrics)
                    guard let self, !Task.isCancelled, self.generation == token else { return }
                    self.message = "权限请求流程已结束，但不代表已获准读取。请单独点击“刷新所选数据”查看可读取的记录。"
                } else {
                    let result = try await service.read(metrics, now: Date())
                    guard let self, !Task.isCancelled, self.generation == token else { return }
                    // Do not expose unsolicited metrics returned by a fake/alternate service.
                    self.snapshot = HealthSnapshot(capturedAt: result.capturedAt,
                                                   readings: result.readings.filter { metrics.contains($0.key) })
                }
            } catch is CancellationError {
                // Cancellation is neither a read-denial indication nor a user error.
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.message = HealthDataError.sanitized(error).message
            }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.isBusy = false
            self.operation = nil
        }
    }

}

@MainActor
struct HealthKitView: View {
    @State private var controller: HealthKitController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _controller = State(initialValue: HealthKitController(service: HealthKitService()))
    }

    init(service: any HealthDataService) {
        _controller = State(initialValue: HealthKitController(service: service))
    }

    var body: some View {
        List {
            Section {
                Label("只读 · 仅按需访问", systemImage: "heart.text.clipboard")
                    .font(.headline)
                Text("选择数据类型后，主动点击请求权限。打开本页不会请求权限，也不会自动读取。刷新与请求权限是两个独立操作。")
                if !controller.isAvailable {
                    Text(HealthDataError.unavailable.message)
                        .foregroundStyle(.secondary)
                }
            }

            Section("选择数据类型") {
                ForEach(HealthMetric.allCases) { metric in
                    Toggle(metric.title, isOn: Binding(
                        get: { controller.selected.contains(metric) },
                        set: { controller.setSelected(metric, enabled: $0) }
                    ))
                }
            }

            Section {
                Button("请求所选类型的读取权限") { controller.requestPermissions() }
                    .disabled(controller.selected.isEmpty || controller.isBusy || !controller.isAvailable)
                Button("刷新所选数据") { controller.refresh() }
                    .disabled(controller.selected.isEmpty || controller.isBusy || !controller.isAvailable)
                Button("重置选择并清空本页", role: .destructive) { controller.reset() }
                if controller.isBusy {
                    ProgressView("正在处理…")
                }
                if let message = controller.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("请求完成不代表允许读取。无可读取记录可能表示不可用、未允许读取或暂无数据，不能据此判断拒绝授权，也不会显示为 0。关闭选择或重置不会撤销系统权限。")
            }

            if let snapshot = controller.snapshot {
                Section {
                    ForEach(HealthMetric.allCases.filter { controller.selected.contains($0) }) { metric in
                        readingRow(metric, reading: snapshot.readings[metric] ?? .unavailableOrNoData)
                    }
                } header: {
                    Text("本次读取")
                } footer: {
                    Text("读取时间：" + snapshot.capturedAt.formatted(date: .abbreviated, time: .standard))
                }
            }

            Section("隐私与用途") {
                Text("本功能仅在本机内存中读取和显示健康数据，不保存到应用仓库，不发送给食物识别代理、第三方网络、家庭功能或 Watch 功能。离开本页将清空本次结果。系统健康自身的同步设置由系统管理。")
                Text("体重不会自动导入应用体重记录；所有健康数据与目标、宠物和奖励计算保持独立，不用于获得奖励。")
                Text("仅供查看记录，不作为诊断或医疗建议。读取失败或不授权不会影响应用其他功能。")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("iPhone 健康数据")
        .onDisappear { controller.cancelAndClear() }
        .onChange(of: scenePhase) { _, phase in
            // Do not cancel on .inactive: the authorization sheet can cause that state.
            if phase == .background { controller.cancelAndClear() }
        }
    }

    @ViewBuilder
    private func readingRow(_ metric: HealthMetric, reading: HealthReading) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(metric.title).font(.headline)
            switch reading {
            case .unavailableOrNoData:
                Text("不可用、未允许读取或暂无数据。")
                    .foregroundStyle(.secondary)
            case .failed(let error):
                Text(error.message).foregroundStyle(.secondary)
            case .value(let measurement):
                Text(measurement.value.formatted(.number.precision(.fractionLength(0...2))) + " " + metric.unitLabel)
                    .font(.title2.monospacedDigit())
                if metric.isCumulative {
                    Text("今日 · HealthKit 合并统计（不是各来源相加）")
                        .font(.caption).foregroundStyle(.secondary)
                } else if metric == .sleep {
                    Text("最近 24 小时 · 仅睡眠阶段，已裁剪时段并合并重叠；不计卧床或清醒时间。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("最近一次 · " + measurement.interval.end.formatted(date: .abbreviated, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if metric.isCumulative || metric == .sleep {
                    Text(measurement.interval.start.formatted(date: .abbreviated, time: .shortened)
                         + " – " + measurement.interval.end.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("来源（\(measurement.sources.count)）") {
                    if measurement.sources.isEmpty {
                        Text("没有可用的来源详情。")
                    }
                    ForEach(measurement.sources, id: \.self) { source in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.name).font(.subheadline.bold())
                            Text(source.bundleIdentifier)
                            Text("版本：" + (source.version ?? "未提供"))
                            Text("设备：" + (source.device?.description.nilIfEmpty ?? "未提供"))
                        }
                        .font(.caption)
                        .textSelection(.enabled)
                    }
                    if metric.isCumulative {
                        Text("来源列表来自 HealthKit 统计，版本和设备来自匹配记录；不表示每台设备对合并总量的分配。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
