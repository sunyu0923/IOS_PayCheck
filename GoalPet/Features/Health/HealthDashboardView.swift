// File: c:\Users\YSun14\OneDrive - Rockwell Automation, Inc\Desktop\WorkProject\IOS_PayCheck\GoalPet\Features\Health\HealthDashboardView.swift
// Purpose: Accessible weight history, descriptive health estimates, and save-only draft editors.
// Dependencies: SwiftUI, Charts, Foundation; AppViewModel, Models, HealthMath, NumberInput,
// InputError, DS, GPCard, InlineError, L10n. iOS 17+, Swift 5. No SwiftData or HealthKit access.

import SwiftUI
import Charts
import Foundation

@MainActor
struct HealthDashboardView: View {
    let model: AppViewModel

    @State private var sheet: HealthDashboardSheet?
    @State private var pendingDeletion: WeightRecord?
    @State private var confirmsDeletion = false
    @State private var errorMessage: String?
    @State private var showsBMI = false

    private var records: [WeightRecord] {
        model.data.weights.sorted {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date
        }
    }

    private var goalKind: HealthGoalKind {
        HealthGoalKind(rawValue: model.healthGoal?.kindRaw ?? "") ?? .record
    }

    private var targetKG: Double? {
        guard goalKind == .lose || goalKind == .gain,
              let target = model.healthGoal?.targetKG, target.isFinite else { return nil }
        return target
    }

    // The enclosing tab/router supplies the dashboard's NavigationStack.
    var body: some View {
        List {
            Section {
                NavigationLink("按需读取 iPhone 健康数据") { HealthKitView() }
                NavigationLink("体重阶段与每日任务") { GoalProgressView(model: model) }
            }
            Section {
                NavigationLink {
                    NutritionHistoryView(model: model)
                } label: {
                    Label("饮食与食物识别", systemImage: "fork.knife")
                }
                Text(model.foodRecognitionService.mode == .remote
                     ? "远程识别需单独同意上传；确认后的饮食记录保存在本机。"
                     : "默认使用离线 Mock 演示；手动确认的真实记录仅保存在本机。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                if let errorMessage {
                    InlineError(message: errorMessage)
                }
                latestCard
                goalCard
                HealthWeightChart(points: model.weightPoints, unit: model.unit, targetKG: targetKG)
                estimatesCard
            }
            .listRowInsets(EdgeInsets(top: DS.small, leading: DS.spacing,
                                     bottom: DS.small, trailing: DS.spacing))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            Section {
                if records.isEmpty {
                    Text("尚无体重记录。添加一次测量即可开始查看历史。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(records, id: \.id) { record in
                        recordRow(record)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { requestDeletion(record) } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                Button { sheet = .editWeight(record) } label: {
                                    Label("编辑", systemImage: "pencil")
                                }
                                .tint(DS.health)
                            }
                    }
                }
            } header: {
                Text("体重记录")
            } footer: {
                Text("记录按测量时间从新到旧排列。编辑与删除会更新图表；删除后无法恢复。")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DS.background)
        .tint(DS.health)
        .navigationTitle(Text("健康记录"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { sheet = .profile } label: {
                    Label("个人资料", systemImage: "person.crop.circle")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { sheet = .newWeight } label: {
                    Label("记录体重", systemImage: "plus")
                }
            }
        }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .newWeight: WeightEntryView(model: model)
            case .editWeight(let record): WeightEntryView(model: model, record: record)
            case .goal: HealthGoalEditorView(model: model)
            case .profile: ProfileEditorView(model: model)
            }
        }
        .alert("删除体重记录？", isPresented: $confirmsDeletion, presenting: pendingDeletion) { record in
            Button("取消", role: .cancel) { pendingDeletion = nil }
            Button("删除", role: .destructive) { delete(record) }
        } message: { record in
            Text(verbatim: HealthViewText.weight(record.kilograms, unit: model.unit)
                 + " · " + HealthViewText.date(record.date)
                 + "\n" + L10n.text("此操作无法撤销，图表和估算也会更新。"))
        }
    }

    private var latestCard: some View {
        GPCard {
            VStack(alignment: .leading, spacing: DS.small) {
                Label("最近一次测量", systemImage: "scalemass")
                    .font(.headline)
                    .foregroundStyle(DS.health)
                if let latest = model.latestWeight {
                    Text(verbatim: HealthViewText.weight(latest.kilograms, unit: model.unit))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .monospacedDigit()
                    Text(verbatim: HealthViewText.date(latest.date))
                        .foregroundStyle(.secondary)
                } else {
                    Text("从一次记录开始")
                        .font(.title2.bold())
                    Text("体重会随水分、测量时间等因素波动，单次读数不代表长期趋势。")
                        .foregroundStyle(.secondary)
                }
                Button("记录体重") { sheet = .newWeight }
                    .buttonStyle(.borderedProminent)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var goalCard: some View {
        GPCard {
            VStack(alignment: .leading, spacing: DS.small) {
                Label("健康目标", systemImage: "flag")
                    .font(.headline)
                if let goal = model.healthGoal {
                    Text(verbatim: goalKind.title)
                        .font(.title2.bold())
                    if let targetKG {
                        LabeledContent {
                            Text(verbatim: HealthViewText.weight(targetKG, unit: model.unit))
                        } label: { Text("目标参考值") }
                    }
                    Text(verbatim: L10n.text("最近更新") + " · " + HealthViewText.date(goal.updatedAt))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if goalKind == .maintain {
                        Text("维持模式仅观察记录与波动，不显示减重进度，也不以单次读数判断是否达成。")
                    } else if goalKind == .record {
                        Text("只记录模式不设目标体重，也不评定进度。")
                    } else {
                        Text("图中的目标线仅供参考，不是预测或达成判定。短期读数或平均值越过参考线，不代表目标已稳定达成。")
                    }
                } else {
                    Text("尚未设置目标")
                    Text("可以选择只记录、维持体重，或在确认成年后设置变化方向。")
                        .foregroundStyle(.secondary)
                }
                Button(model.healthGoal == nil ? L10n.text("设置目标") : L10n.text("编辑目标")) {
                    sheet = .goal
                }
                .buttonStyle(.bordered)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var estimatesCard: some View {
        GPCard {
            VStack(alignment: .leading, spacing: DS.small) {
                Label("了解估算", systemImage: "info.circle")
                    .font(.headline)
                if let bmr = model.bmr, let tdee = model.tdee {
                    LabeledContent {
                        Text(verbatim: HealthViewText.energy(bmr))
                            .monospacedDigit()
                    } label: { Text("基础代谢估算（BMR）") }
                    Text("BMR 描述静息状态下的能量消耗估算。")
                        .font(.footnote)
                    LabeledContent {
                        Text(verbatim: HealthViewText.energy(tdee))
                            .monospacedDigit()
                    } label: { Text("每日总消耗估算（TDEE）") }
                    Text("TDEE 根据所选活动水平估计每日总能量消耗；它不是建议摄入量。未提供生理性别时显示公式范围，该范围不是置信区间。")
                        .font(.footnote)
                    Toggle("显示 BMI 数值估算（可选）", isOn: $showsBMI)
                    if showsBMI, let weight = model.latestWeight?.kilograms,
                       let height = model.profile?.heightCM,
                       let bmi = HealthMath.bmi(kg: weight, heightCM: height) {
                        Text(verbatim: "BMI · " + NumberInput.format(bmi))
                            .font(.title3.monospacedDigit())
                        Text("BMI 仅由体重与身高计算，不区分肌肉、脂肪或个体情况，不能独立评价健康。")
                            .font(.footnote)
                    }
                } else {
                    Text(verbatim: estimateExplanation)
                    Button("编辑估算资料") { sheet = .profile }
                        .buttonStyle(.bordered)
                }
                Divider()
                Text("这些数值仅供一般信息参考，不是诊断、饮食处方或热量目标。公式可能不适用于妊娠、哺乳、疾病或特殊训练等情况；如需个人建议，请咨询合格医疗专业人员。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var estimateExplanation: String {
        var reasons: [String] = []
        if model.profile?.estimatesEnabled != true {
            reasons.append(L10n.text("描述性估算尚未启用，可在个人资料中自愿开启。"))
        }
        if model.latestWeight == nil { reasons.append(L10n.text("缺少体重记录。")) }
        if model.profile?.heightCM == nil { reasons.append(L10n.text("缺少身高。")) }
        if let age = model.age {
            if age < 18 {
                reasons.append(L10n.text("未满 18 岁，不提供成人代谢估算或减重、增重目标；仍可记录或选择维持模式。"))
            } else if age > 100 {
                reasons.append(L10n.text("年龄超出当前估算公式的适用范围（18 至 100 岁）。"))
            }
        } else {
            reasons.append(L10n.text("缺少出生日期，无法确认成年，因此不提供成人估算。"))
        }
        if let kg = model.latestWeight?.kilograms, !(30...350).contains(kg) {
            reasons.append(L10n.text("体重超出当前估算公式的适用范围（30 至 350 kg），不影响保存记录。"))
        }
        if let height = model.profile?.heightCM, !(120...230).contains(height) {
            reasons.append(L10n.text("身高超出当前估算公式的适用范围（120 至 230 cm）。"))
        }
        return reasons.isEmpty ? L10n.text("当前资料不适用于此估算公式。") : reasons.joined(separator: "\n")
    }

    private func recordRow(_ record: WeightRecord) -> some View {
        VStack(alignment: .leading, spacing: DS.small) {
            Text(verbatim: HealthViewText.weight(record.kilograms, unit: model.unit))
                .font(.headline.monospacedDigit())
            Text(verbatim: HealthViewText.date(record.date))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !record.note.isEmpty {
                Text(verbatim: record.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Visible controls also work without discovering swipe gestures.
            HStack(spacing: DS.spacing) {
                Button { sheet = .editWeight(record) } label: {
                    Label("编辑", systemImage: "pencil")
                        .padding(.vertical, DS.small)
                }
                .accessibilityLabel(Text(verbatim: L10n.text("编辑记录") + " · " + HealthViewText.date(record.date)))
                Button(role: .destructive) { requestDeletion(record) } label: {
                    Label("删除", systemImage: "trash")
                        .padding(.vertical, DS.small)
                }
                .accessibilityLabel(Text(verbatim: L10n.text("删除记录") + " · " + HealthViewText.date(record.date)))
            }
            .buttonStyle(.borderless)
        }
        .accessibilityElement(children: .contain)
    }

    private func requestDeletion(_ record: WeightRecord) {
        pendingDeletion = record
        confirmsDeletion = true
    }

    private func delete(_ record: WeightRecord) {
        do {
            if let current = model.data.weights.first(where: { $0.id == record.id }) {
                try model.deleteWeight(current)
            }
            errorMessage = nil
            pendingDeletion = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum HealthDashboardSheet: Identifiable {
    case newWeight, editWeight(WeightRecord), goal, profile

    var id: String {
        switch self {
        case .newWeight: return "newWeight"
        case .editWeight(let record): return "editWeight-\(record.id)"
        case .goal: return "goal"
        case .profile: return "profile"
        }
    }
}

private struct HealthWeightChart: View {
    let points: [WeightPoint]
    let unit: WeightUnit
    let targetKG: Double?

    private let dailyLabel = L10n.text("每日原始值（同日均值）")
    private let averageLabel = L10n.text("7 日移动平均")

    var body: some View {
        // Keep derived series out of @State so edits, deletions, units, and goal changes update immediately.
        let daily = HealthMath.daily(points)
        let average = HealthMath.movingAverage(points)
        GPCard {
            VStack(alignment: .leading, spacing: DS.spacing) {
                Text("体重趋势")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if daily.isEmpty {
                    Text("添加体重记录后显示趋势图。")
                        .foregroundStyle(.secondary)
                } else {
                    Chart {
                        ForEach(daily) { point in
                            LineMark(x: .value(L10n.text("日期"), point.date),
                                     y: .value(unit.rawValue, unit.display(point.kg)),
                                     series: .value(L10n.text("序列"), dailyLabel))
                                .foregroundStyle(by: .value(L10n.text("序列"), dailyLabel))
                                .lineStyle(StrokeStyle(lineWidth: 2))
                                .symbol(.circle)
                                .interpolationMethod(.linear)
                        }
                        ForEach(average) { point in
                            LineMark(x: .value(L10n.text("日期"), point.date),
                                     y: .value(unit.rawValue, unit.display(point.kg)),
                                     series: .value(L10n.text("序列"), averageLabel))
                                .foregroundStyle(by: .value(L10n.text("序列"), averageLabel))
                                .lineStyle(StrokeStyle(lineWidth: 3, dash: [6, 4]))
                                .symbol(.square)
                                .interpolationMethod(.linear)
                        }
                        if let targetKG {
                            RuleMark(y: .value(L10n.text("目标参考值"), unit.display(targetKG)))
                                .foregroundStyle(DS.primary.opacity(0.7))
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 4]))
                        }
                    }
                    .chartForegroundStyleScale(domain: [dailyLabel, averageLabel],
                                               range: [DS.health, DS.reward])
                    .chartLegend(.hidden)
                    .chartYScale(domain: yDomain(daily))
                    .chartXScale(domain: xDomain(daily))
                    .chartYAxisLabel(unit.rawValue)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel(format: .dateTime.month().day())
                        }
                    }
                    .frame(height: 240)
                    // A visible, VoiceOver-readable summary and the complete record list replace noisy marks.
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DS.small) {
                        Label(dailyLabel + " · " + L10n.text("实线"), systemImage: "circle.fill")
                            .foregroundStyle(DS.health)
                        Label(averageLabel + " · " + L10n.text("虚线"), systemImage: "square.fill")
                            .foregroundStyle(DS.reward)
                        if let targetKG {
                            Text(verbatim: L10n.text("点线：目标参考值") + " · "
                                 + HealthViewText.weight(targetKG, unit: unit))
                        }
                    }
                    .font(.footnote)
                    Text(verbatim: summary(daily: daily, average: average))
                        .accessibilityLabel(Text(verbatim: L10n.text("图表摘要") + "。"
                                                 + summary(daily: daily, average: average)))
                }
                Text("每日原始序列未做跨日平滑；同日多条记录取均值。7 日平均使用当天及前 6 个日历日内已记录日的均值，每天等权，至少有 3 个记录日才显示；缺失日不按零计算。连线不代表未记录日期的测量。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func yDomain(_ daily: [WeightPoint]) -> ClosedRange<Double> {
        let values = (daily.map(\.kg) + (targetKG.map { [$0] } ?? [])).map { unit.display($0) }
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let padding = max((high - low) * 0.15, unit.display(1))
        return max(0, low - padding)...(high + padding)
    }

    private func xDomain(_ daily: [WeightPoint]) -> ClosedRange<Date> {
        let first = daily.first?.date ?? .now
        let last = daily.last?.date ?? first
        if first < last { return first...last }
        let calendar = Calendar.current
        let lower = calendar.date(byAdding: .day, value: -1, to: first) ?? first.addingTimeInterval(-86400)
        let upper = calendar.date(byAdding: .day, value: 1, to: last) ?? last.addingTimeInterval(86400)
        return lower...upper
    }

    private func summary(daily: [WeightPoint], average: [WeightPoint]) -> String {
        guard let first = daily.first, let last = daily.last,
              let low = daily.map(\.kg).min(), let high = daily.map(\.kg).max() else {
            return L10n.text("尚无图表数据。")
        }
        var parts = [
            L10n.text("记录日期范围") + "：" + first.date.formatted(date: .abbreviated, time: .omitted)
                + " – " + last.date.formatted(date: .abbreviated, time: .omitted) + "。",
            L10n.text("记录天数") + "：" + daily.count.formatted() + "。",
            L10n.text("每日值范围") + "：" + HealthViewText.weight(low, unit: unit)
                + " – " + HealthViewText.weight(high, unit: unit) + "。",
            L10n.text("最近每日值") + "：" + HealthViewText.weight(last.kg, unit: unit) + "。"
        ]
        if let recent = average.last {
            parts.append(L10n.text("最近可用的 7 日平均") + "（"
                         + recent.date.formatted(date: .abbreviated, time: .omitted) + "）："
                         + HealthViewText.weight(recent.kg, unit: unit) + "。")
        }
        if average.last?.date != last.date {
            parts.append(L10n.text("最新日期的 7 日窗口不足 3 个记录日，暂不显示该日平均值。"))
        }
        if let targetKG {
            parts.append(L10n.text("目标参考值") + "：" + HealthViewText.weight(targetKG, unit: unit)
                         + "。" + L10n.text("参考线不表示已达成目标。"))
        }
        return parts.joined(separator: " ")
    }
}

@MainActor
struct WeightEntryView: View {
    let model: AppViewModel
    private let isEditing: Bool
    private let originalValue: String

    @Environment(\.dismiss) private var dismiss
    @State private var id: UUID
    @State private var value: String
    @State private var date: Date
    @State private var note: String
    @State private var inputUnit: WeightUnit
    @State private var errorMessage: String?

    init(model: AppViewModel, record: WeightRecord? = nil) {
        self.model = model
        isEditing = record != nil
        originalValue = record.map { NumberInput.format(model.unit.display($0.kilograms)) } ?? ""
        _id = State(initialValue: record?.id ?? UUID())
        _value = State(initialValue: record.map { NumberInput.format(model.unit.display($0.kilograms)) } ?? "")
        _date = State(initialValue: record?.date ?? .now)
        _note = State(initialValue: record?.note ?? "")
        _inputUnit = State(initialValue: model.unit)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage { Section { InlineError(message: errorMessage) } }
                Section {
                    TextField(L10n.text("体重") + " (" + inputUnit.rawValue + ")", text: $value)
                        .keyboardType(.decimalPad)
                    DatePicker("测量时间", selection: $date, in: ...Date.now,
                               displayedComponents: [.date, .hourAndMinute])
                    TextField("备注（可选）", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                } footer: {
                    Text("请确认单位。记录时间不能晚于现在；保存前不会修改任何记录。")
                }
            }
            .navigationTitle(isEditing ? L10n.text("编辑体重") : L10n.text("记录体重"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
            }
            .tint(DS.health)
        }
    }

    private func save() {
        do {
            // saveWeight interprets text using the VM's current unit; never silently reinterpret a draft.
            guard inputUnit == model.unit else {
                throw InputError.invalid("体重单位已在其他位置改变。请保留输入，关闭后重新打开此表单并确认新单位。")
            }
            if isEditing, !model.data.weights.contains(where: { $0.id == id }) {
                throw InputError.invalid("此记录已被删除，无法保存编辑。请关闭后重新添加记录。")
            }
            try model.saveWeight(id: id, value: value, date: date, note: note,
                                 preserveMeasurement: isEditing && value == originalValue)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
struct HealthGoalEditorView: View {
    let model: AppViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var kind: HealthGoalKind
    @State private var target: String
    @State private var inputUnit: WeightUnit
    @State private var errorMessage: String?

    init(model: AppViewModel) {
        self.model = model
        _kind = State(initialValue: HealthGoalKind(rawValue: model.healthGoal?.kindRaw ?? "") ?? .record)
        _target = State(initialValue: model.healthGoal?.targetKG.map { NumberInput.format(model.unit.display($0)) } ?? "")
        _inputUnit = State(initialValue: model.unit)
    }

    private var needsTarget: Bool { kind == .lose || kind == .gain }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage { Section { InlineError(message: errorMessage) } }
                Section {
                    Picker("目标类型", selection: $kind) {
                        ForEach(HealthGoalKind.allCases) { option in
                            Text(verbatim: option.title).tag(option)
                        }
                    }
                    if needsTarget {
                        TextField(L10n.text("目标体重") + " (" + inputUnit.rawValue + ")", text: $target)
                            .keyboardType(.decimalPad)
                    }
                } footer: {
                    Text("只记录与维持模式无需目标体重，也不显示减重进度。减重或增重目标需要先确认成年。")
                }
                Section {
                    if model.latestWeight == nil {
                        Text("请先保存一次体重记录，再设置目标。")
                    }
                    if (model.age ?? 0) < 18 {
                        Text("未成年或年龄未知时，仅可保存只记录或维持模式。出生日期可在个人资料中自愿提供。")
                    }
                    Text("保存会以最近一次体重重新设置目标起点与开始时间，并更新图表参考线；不会改写历史体重。目标值不是医学建议，也不保证任何时间内达成。")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .navigationTitle(Text("健康目标"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
            }
            .tint(DS.health)
        }
    }

    private func save() {
        do {
            if needsTarget, inputUnit != model.unit {
                throw InputError.invalid("体重单位已在其他位置改变。请保留输入，关闭后重新打开此表单并确认新单位。")
            }
            try model.saveHealthGoal(kind: kind, targetText: needsTarget ? target : "")
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
struct ProfileEditorView: View {
    let model: AppViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var nickname: String
    @State private var unit: WeightUnit
    @State private var height: String
    @State private var includesBirth: Bool
    @State private var birth: Date
    @State private var sex: BiologicalSex
    @State private var activity: ActivityLevel
    @State private var estimates: Bool
    @State private var errorMessage: String?

    init(model: AppViewModel) {
        self.model = model
        let profile = model.profile
        _nickname = State(initialValue: profile?.displayName ?? "")
        _unit = State(initialValue: model.unit)
        _height = State(initialValue: profile?.heightCM.map { NumberInput.format($0) } ?? "")
        _includesBirth = State(initialValue: profile?.dateOfBirth != nil)
        // Do not invent an adult birth date; this is an unsaved picker placeholder only.
        _birth = State(initialValue: profile?.dateOfBirth ?? .now)
        _sex = State(initialValue: BiologicalSex(rawValue: profile?.sexRaw ?? "") ?? .unspecified)
        _activity = State(initialValue: ActivityLevel(rawValue: profile?.activityRaw ?? "") ?? .sedentary)
        _estimates = State(initialValue: profile?.estimatesEnabled ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage { Section { InlineError(message: errorMessage) } }
                Section {
                    TextField("昵称", text: $nickname)
                    Picker("体重单位", selection: $unit) {
                        ForEach(WeightUnit.allCases) { option in
                            Text(verbatim: option.rawValue).tag(option)
                        }
                    }
                } header: { Text("基本资料") } footer: {
                    Text("昵称最多保存 60 个字符。更改体重单位只改变显示与后续输入单位，不改写历史测量。")
                }
                Section {
                    TextField("身高（cm，可选；留空可清除）", text: $height)
                        .keyboardType(.decimalPad)
                    Toggle("提供出生日期（可选）", isOn: $includesBirth)
                    if includesBirth {
                        DatePicker("出生日期", selection: $birth, in: ...Date.now, displayedComponents: .date)
                    }
                    Picker("生理性别（估算公式使用）", selection: $sex) {
                        ForEach(BiologicalSex.allCases) { option in
                            Text(verbatim: option.title).tag(option)
                        }
                    }
                    Picker("活动水平", selection: $activity) {
                        ForEach(ActivityLevel.allCases) { option in
                            Text(verbatim: option.title).tag(option)
                        }
                    }
                    Toggle("启用描述性代谢估算", isOn: $estimates)
                } header: { Text("可选估算资料") } footer: {
                    Text("估算需要体重、身高与成年年龄资料；生理性别可不提供。不提供出生日期或未满 18 岁时，不提供成人估算，已有减重或增重目标将在保存资料时改为只记录并清除目标参考值。关闭出生日期开关只在保存后清除日期。")
                }
                Section {
                    Text("BMR 与 TDEE 仅描述公式估计的能量消耗，不是建议摄入量或热量目标。BMI 可在仪表盘单独选择显示，不作为健康评价或诊断。")
                    Text("更改以上内容不会立即写入；取消会放弃本次草稿。")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .navigationTitle(Text("个人资料"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
            }
            .tint(DS.health)
        }
    }

    private func save() {
        do {
            try model.saveProfile(displayName: nickname, unit: unit, heightText: height,
                                  birth: includesBirth ? birth : nil, sex: sex,
                                  activity: activity, estimates: estimates)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum HealthViewText {
    static func weight(_ kg: Double, unit: WeightUnit) -> String {
        NumberInput.format(unit.display(kg)) + " " + unit.rawValue
    }

    static func date(_ value: Date) -> String {
        value.formatted(date: .abbreviated, time: .shortened)
    }

    static func energy(_ range: ClosedRange<Double>) -> String {
        let low = range.lowerBound.formatted(.number.precision(.fractionLength(0)))
        let high = range.upperBound.formatted(.number.precision(.fractionLength(0)))
        return (low == high ? low : low + " – " + high) + " " + L10n.text("千卡/日")
    }
}