// File: c:\Users\YSun14\OneDrive - Rockwell Automation, Inc\Desktop\WorkProject\IOS_PayCheck\GoalPet\Features\Savings\SavingsGoalView.swift
// Purpose: Personal/family savings lists, goal drafts, progress, and recoverable contribution records.
// Dependencies: SwiftUI, Foundation; AppViewModel, SavingsGoal, SavingsContribution, Money, GoalMilestoneStatusView, InputError, DS, GPCard, InlineError, L10n. iOS 17+, Swift 5.

import Foundation
import SwiftUI

@MainActor
struct SavingsGoalView: View {
    let model: AppViewModel
    let familyID: UUID?
    @State private var showsPaused = false
    @State private var showsEditor = false

    init(model: AppViewModel, familyID: UUID? = nil) {
        self.model = model
        self.familyID = familyID
    }

    private var scopedGoals: [SavingsGoal] {
        model.data.goals.filter { $0.familyGroupID == familyID }
    }

    private var visibleGoals: [SavingsGoal] {
        scopedGoals.filter { ($0.statusRaw != "active") == showsPaused }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var canCreate: Bool {
        if let familyID { return model.data.families.contains { $0.id == familyID } }
        return !model.personalGoals.contains { $0.statusRaw == "active" }
    }

    var body: some View {
        List {
            Section {
                Picker("计划状态", selection: $showsPaused) {
                    Text("进行中").tag(false)
                    Text("已暂停").tag(true)
                }
                .pickerStyle(.segmented)
                if familyID == nil {
                    Text("本阶段支持一个进行中的个人计划。暂停后保留资金记录，可创建新计划；恢复旧计划前需先暂停其他进行中的个人计划。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("家庭目标仅保存在本机，不会与成员共享，也不会转移真实资金。家庭里程碑不发放个人 XP。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if visibleGoals.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label(showsPaused ? L10n.text("暂无暂停计划") : L10n.text("暂无进行中的计划"),
                              systemImage: "target")
                    } description: {
                        Text("为下一件期待的事，留下一点积蓄。")
                    } actions: {
                        Button("添加计划") { showsEditor = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canCreate)
                    }
                }
            } else {
                Section {
                    ForEach(visibleGoals) { goal in
                        NavigationLink {
                            GoalDetailView(model: model, goal: goal)
                        } label: {
                            SavingsGoalSummary(model: model, goal: goal)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.background)
        .tint(DS.finance)
        .navigationTitle(Text(familyID == nil ? L10n.text("储蓄计划") : L10n.text("家庭储蓄")))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showsEditor = true } label: { Label("添加计划", systemImage: "plus") }
                    .disabled(!canCreate)
            }
        }
        .sheet(isPresented: $showsEditor) {
            NavigationStack { GoalEditorView(model: model, familyID: familyID) }
        }
    }
}

@MainActor
private struct SavingsGoalSummary: View {
    let model: AppViewModel
    let goal: SavingsGoal

    var body: some View {
        VStack(alignment: .leading, spacing: DS.small) {
            Text(verbatim: goal.name).font(.headline)
            Text(verbatim: Money.format(model.balance(goal), currency: goal.currency))
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(DS.finance)
            Label(goal.statusRaw == "active" ? L10n.text("进行中") : L10n.text("已暂停"),
                  systemImage: goal.statusRaw == "active" ? "target" : "pause.circle")
                .font(.caption)
            LabeledContent("目标金额", value: Money.format(goal.targetMinor, currency: goal.currency))
                .font(.caption)
            LabeledContent("目标日期") { Text(goal.targetDate, style: .date) }
                .font(.caption)
        }
        .padding(.vertical, DS.small)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct GoalDetailView: View {
    let model: AppViewModel
    let goal: SavingsGoal
    @State private var showsEditor = false
    @State private var showsContributionEditor = false
    @State private var pendingDeletion: SavingsContribution?
    @State private var showsDeleted = false
    @State private var errorMessage: String?

    private var isActive: Bool { goal.statusRaw == "active" }
    private var milestones: [GoalMilestoneProgress] {
        model.evaluation.milestones.filter { $0.goalID == goal.id }
    }
    private var records: [SavingsContribution] {
        model.contributions(for: goal, includeDeleted: true)
            .filter { ($0.deletedAt != nil) == showsDeleted }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        List {
            if let errorMessage {
                Section { InlineError(message: errorMessage) }
            }
            Section {
                GPCard {
                    VStack(alignment: .leading, spacing: DS.spacing) {
                        Text(verbatim: goal.name)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                        LabeledContent("当前余额", value: Money.format(model.balance(goal), currency: goal.currency))
                        LabeledContent("目标金额", value: Money.format(goal.targetMinor, currency: goal.currency))
                        LabeledContent("初始金额", value: Money.format(goal.initialMinor, currency: goal.currency))
                        LabeledContent("目标日期") { Text(goal.targetDate, style: .date) }
                        if !isActive {
                            Label("已暂停，恢复后可新增存入或取出记录", systemImage: "pause.circle")
                                .font(.callout)
                        }
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                ForEach(milestones) { milestone in
                    GoalMilestoneStatusView(milestone: milestone, showsTitle: false)
                }
            } header: {
                Text("进度里程碑")
            } footer: {
                Text("初始金额计入当前进度，但不作为赚取奖励的存入。个人里程碑奖励还需创建计划后的个人净存入达到完整目标金额对应的比例；取出会减少净存入。家庭里程碑不发放个人 XP，暂停期间不发放新的里程碑奖励。已达到不等于已获奖，请查看奖励记录。")
            }

            Section {
                if isActive {
                    Button { showsContributionEditor = true } label: {
                        Label("记录存入或取出", systemImage: "plus.circle")
                    }
                }
                Toggle("查看已删除记录", isOn: $showsDeleted)
                if records.isEmpty {
                    Text(showsDeleted ? L10n.text("暂无已删除记录") : L10n.text("暂无资金记录"))
                        .foregroundStyle(.secondary)
                }
                ForEach(records) { record in
                    contributionRow(record)
                }
            } header: {
                Text("资金记录")
            } footer: {
                Text("删除、恢复或取出会重新计算余额与当前里程碑进度，但已获得的 XP 和宠物不会撤销。暂停后仍可删除或恢复历史记录；如需更正，请删除原记录后重新录入。不会转移真实资金。")
            }

            Section {
                Button(isActive ? L10n.text("暂停计划") : L10n.text("恢复计划")) {
                    perform { try model.setGoalPaused(id: goal.id, paused: isActive) }
                }
            } footer: {
                Text("暂停会保留余额、历史记录与已获得的奖励。恢复个人计划前，需先暂停其他进行中的个人计划。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.background)
        .tint(DS.finance)
        .navigationTitle(Text("计划详情"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("编辑计划") { showsEditor = true }.disabled(!isActive)
            }
        }
        .sheet(isPresented: $showsEditor) {
            NavigationStack { GoalEditorView(model: model, goal: goal) }
        }
        .sheet(isPresented: $showsContributionEditor) {
            NavigationStack { ContributionEditorView(model: model, goal: goal) }
        }
        .confirmationDialog("删除这条资金记录？", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible, presenting: pendingDeletion) { record in
            Button("删除记录", role: .destructive) {
                perform { try model.setDeleted(record, deleted: true) }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text("余额将重新计算。你可以在已删除记录中恢复；使余额小于零的操作将被拒绝。")
        }
    }

    private func contributionRow(_ record: SavingsContribution) -> some View {
        VStack(alignment: .leading, spacing: DS.small) {
            HStack {
                if record.signedMinor < 0 {
                    Label("取出", systemImage: "arrow.up.right")
                } else {
                    Label("存入", systemImage: "arrow.down.left")
                }
                Spacer()
                Text(verbatim: Money.format(record.signedMinor, currency: goal.currency))
                    .monospacedDigit()
            }
            LabeledContent("记录日期") { Text(record.date, style: .date) }
                .font(.caption)
            if goal.familyGroupID != nil {
                LabeledContent("记录成员", value: model.memberName(record.memberID)).font(.caption)
            }
            if !record.note.isEmpty { Text(verbatim: record.note).font(.callout) }
            if record.deletedAt != nil {
                Button("恢复记录") { perform { try model.setDeleted(record, deleted: false) } }
                    .buttonStyle(.borderless)
            } else {
                Button("删除记录", role: .destructive) { pendingDeletion = record }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, DS.small)
    }

    private func perform(_ action: () throws -> Void) {
        errorMessage = nil
        do { try action() }
        catch { errorMessage = L10n.text(error.localizedDescription) }
    }
}

@MainActor
struct GoalEditorView: View {
    let model: AppViewModel
    let goal: SavingsGoal?
    let familyID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var targetText: String
    @State private var initialText: String
    @State private var targetDate: Date
    @State private var errorMessage: String?

    init(model: AppViewModel, goal: SavingsGoal? = nil, familyID: UUID? = nil) {
        self.model = model
        self.goal = goal
        // Editing preserves the original scope, even if a different scope was supplied.
        self.familyID = goal == nil ? familyID : goal?.familyGroupID
        let currency = goal?.currency ?? model.currency
        _title = State(initialValue: goal?.name ?? "")
        _targetText = State(initialValue: goal.map { Money.input($0.targetMinor, currency: currency) } ?? "")
        _initialText = State(initialValue: Money.input(goal?.initialMinor ?? 0, currency: currency))
        _targetDate = State(initialValue: goal?.targetDate ?? Date.now)
    }

    var body: some View {
        Form {
            if let errorMessage { Section { InlineError(message: errorMessage) } }
            Section {
                TextField("计划名称", text: $title)
                LabeledContent("货币", value: goal?.currency ?? model.currency)
                TextField("目标金额", text: $targetText).keyboardType(.decimalPad)
                TextField("初始金额", text: $initialText).keyboardType(.decimalPad)
                DatePicker("目标日期", selection: $targetDate, displayedComponents: .date)
            } header: {
                Text("计划信息")
            } footer: {
                Text("目标日期需为今天或之后。金额不使用千位分隔符，初始金额不能超过目标金额；修改初始金额会影响当前余额。")
            }
            if familyID == nil {
                Section { Text("同一时间只能有一个进行中的个人计划。请先暂停原计划，再创建新计划。初始金额计入进度，但不会直接赚取 XP。") }
            } else {
                Section { Text("这是仅保存在本机的家庭目标，不会邀请成员、共享数据或转移真实资金，也不发放个人 XP。") }
            }
        }
        .tint(DS.finance)
        .navigationTitle(Text(goal == nil ? L10n.text("添加计划") : L10n.text("编辑计划")))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
        }
        .interactiveDismissDisabled()
    }

    private func save() {
        errorMessage = nil
        do {
            if let goal, goal.statusRaw != "active" {
                throw InputError.invalid("请先恢复计划再编辑")
            }
            try model.saveGoal(id: goal?.id, title: title, targetText: targetText,
                               initialText: initialText, date: targetDate, familyID: familyID)
            dismiss()
        } catch { errorMessage = L10n.text(error.localizedDescription) }
    }
}

@MainActor
struct ContributionEditorView: View {
    let model: AppViewModel
    let goal: SavingsGoal
    @Environment(\.dismiss) private var dismiss
    // Stable across rendering and failed retries; the view model deduplicates this operation ID.
    @State private var operationID = UUID()
    @State private var amountText = ""
    @State private var date = Date.now
    @State private var note = ""
    @State private var memberID: UUID?
    @State private var withdrawal = false
    @State private var errorMessage: String?

    init(model: AppViewModel, goal: SavingsGoal) {
        self.model = model
        self.goal = goal
        _memberID = State(initialValue: goal.familyGroupID.flatMap { model.members(in: $0).first?.id })
    }

    private var canSave: Bool {
        guard goal.statusRaw == "active" else { return false }
        guard let familyID = goal.familyGroupID else { return true }
        return model.members(in: familyID).contains { $0.id == memberID }
    }

    var body: some View {
        Form {
            if let errorMessage { Section { InlineError(message: errorMessage) } }
            Section {
                LabeledContent("储蓄计划", value: goal.name)
                LabeledContent("当前余额", value: Money.format(model.balance(goal), currency: goal.currency))
                Picker("记录类型", selection: $withdrawal) {
                    Text("存入").tag(false)
                    Text("取出").tag(true)
                }
                .pickerStyle(.segmented)
                LabeledContent("货币", value: goal.currency)
                TextField("金额", text: $amountText).keyboardType(.decimalPad)
                DatePicker("记录日期", selection: $date, in: ...Date.now, displayedComponents: .date)
                TextField("备注（可选）", text: $note, axis: .vertical).lineLimit(3...6)
            } footer: {
                Text("请输入正数金额，取出不能超过余额。这只是本机记录，不会执行银行存款、转账或提现。")
            }
            if let familyID = goal.familyGroupID {
                Section {
                    Picker("记录成员", selection: $memberID) {
                        Text("请选择成员").tag(Optional<UUID>.none)
                        ForEach(model.members(in: familyID)) { member in
                            Text(verbatim: member.displayName).tag(Optional(member.id))
                        }
                    }
                    if model.members(in: familyID).isEmpty {
                        Text("请先在家庭页面添加一个成员标签。")
                    }
                } footer: {
                    Text("成员仅是本机记录标签，不代表已登录、已加入或已授权的用户。")
                }
            }
            if goal.statusRaw != "active" {
                Section { Text("已暂停计划不能新增存入或取出记录，请先恢复计划。") }
            }
        }
        .tint(DS.finance)
        .navigationTitle(Text("记录资金"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }.disabled(!canSave)
            }
        }
        .interactiveDismissDisabled()
    }

    private func save() {
        errorMessage = nil
        do {
            try model.saveContribution(id: operationID, goal: goal, memberID: memberID,
                                       amountText: amountText, withdrawal: withdrawal, date: date, note: note)
            dismiss()
        } catch { errorMessage = L10n.text(error.localizedDescription) }
    }
}