// File: c:\Users\YSun14\OneDrive - Rockwell Automation, Inc\Desktop\WorkProject\IOS_PayCheck\GoalPet\Features\Finance\FinanceView.swift
// Purpose: Finance overview, current-cycle ledger, transaction drafts, budget editing, and recovery.
// Dependencies: Foundation, SwiftUI, AppViewModel, Models, Calculations (Money),
// DesignSystem (DS, GPCard, InlineError, L10n), SavingsGoalView; iOS 17+, Swift 5.
// Persistence is owned by AppViewModel; these views only read its observable snapshot.

import Foundation
import SwiftUI

@MainActor
struct FinanceView: View {
    let model: AppViewModel

    @State private var kindFilter: TransactionKind?
    @State private var searchText = ""
    @State private var showAllHistory = false
    @State private var transactionSheet: FinanceTransactionSheet?
    @State private var showingBudget = false
    @State private var pendingDeletion: LedgerTransaction?
    @State private var confirmingDeletion = false
    @State private var errorMessage: String?

    private var transactions: [LedgerTransaction] {
        guard let period = model.period else { return [] }
        return model.activeTransactions.filter {
            $0.currency == model.currency && (showAllHistory || ($0.date >= period.start && $0.date < period.end))
                && FinanceLedgerFilter.matches($0, kind: kindFilter, search: searchText)
        }.sorted {
            if $0.date == $1.date { return $0.id.uuidString < $1.id.uuidString }
            return $0.date > $1.date
        }
    }

    private func monthTotal(_ kind: TransactionKind) -> Int64 {
        guard let month = Calendar.current.dateInterval(of: .month, for: .now) else { return 0 }
        return model.activeTransactions.filter {
            $0.currency == model.currency && $0.kindRaw == kind.rawValue
                && $0.date >= month.start && $0.date < month.end
        }.reduce(Int64(0)) { $0 + $1.amountMinor }
    }

    var body: some View {
        List {
            Section {
                monthCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                budgetCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                NavigationLink {
                    SavingsGoalView(model: model)
                } label: {
                    Label(L10n.text("储蓄目标"), systemImage: "flag.fill")
                }
                NavigationLink {
                    RecentlyDeletedView(model: model)
                } label: {
                    Label(L10n.text("最近删除"), systemImage: "trash")
                }
            }

            if let errorMessage {
                Section {
                    InlineError(message: errorMessage)
                }
            }

            Section {
                Toggle("显示全部历史", isOn: $showAllHistory)
                FinanceKindPicker(selection: $kindFilter)
                if transactions.isEmpty {
                    ContentUnavailableView(
                        L10n.text("暂无匹配账单"),
                        systemImage: "list.bullet.rectangle",
                        description: Text("可切换全部历史、调整筛选或新增账单。")
                    )
                }
                ForEach(transactions, id: \.id) { transaction in
                    Button {
                        transactionSheet = FinanceTransactionSheet(transaction: transaction)
                    } label: {
                        FinanceTransactionRow(transaction: transaction)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text(L10n.text("编辑账单")))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            requestDeletion(transaction)
                        } label: {
                            Label(L10n.text("删除"), systemImage: "trash")
                        }
                        Button {
                            transactionSheet = FinanceTransactionSheet(transaction: transaction)
                        } label: {
                            Label(L10n.text("编辑"), systemImage: "pencil")
                        }
                        .tint(DS.finance)
                    }
                    .contextMenu {
                        Button {
                            transactionSheet = FinanceTransactionSheet(transaction: transaction)
                        } label: {
                            Label(L10n.text("编辑"), systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            requestDeletion(transaction)
                        } label: {
                            Label(L10n.text("删除"), systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text(showAllHistory ? "全部历史账单" : "当前预算周期账单")
            } footer: {
                VStack(alignment: .leading, spacing: DS.small) {
                    FinanceCycleLabel(period: model.period)
                    Text(L10n.text("筛选与搜索仅影响账单列表，不影响汇总。"))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.background)
        .tint(DS.finance)
        .navigationTitle(L10n.text("财务"))
        .searchable(text: $searchText, prompt: L10n.text("搜索分类或备注"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    transactionSheet = FinanceTransactionSheet(transaction: nil)
                } label: {
                    Label(L10n.text("新增账单"), systemImage: "plus")
                }
            }
        }
        .sheet(item: $transactionSheet) { sheet in
            NavigationStack {
                AddTransactionView(model: model, transaction: sheet.transaction)
                    .id(sheet.id)
            }
        }
        .sheet(isPresented: $showingBudget) {
            NavigationStack {
                BudgetEditorView(model: model)
            }
        }
        .confirmationDialog(
            L10n.text("删除这笔账单？"),
            isPresented: $confirmingDeletion,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { transaction in
            Button(L10n.text("删除账单"), role: .destructive) {
                do {
                    try model.setDeleted(transaction, deleted: true)
                    errorMessage = nil
                    pendingDeletion = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            Button(L10n.text("取消"), role: .cancel) { pendingDeletion = nil }
        } message: { transaction in
            Text("\(L10n.text(transaction.category)) · \(Money.format(transaction.amountMinor, currency: transaction.currency))\n\(L10n.text("删除后可在“最近删除”中恢复。"))")
        }
    }

    private var monthCard: some View {
        GPCard {
            VStack(alignment: .leading, spacing: DS.spacing) {
                Label(L10n.text("本自然月汇总"), systemImage: "calendar")
                    .font(.headline)
                    .foregroundStyle(DS.finance)
                Text(Date.now, format: .dateTime.year().month())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                moneyRow(L10n.text("收入"), amount: monthTotal(.income))
                moneyRow(L10n.text("支出"), amount: monthTotal(.expense))
                Divider()
                moneyRow(L10n.text("结余"), amount: monthTotal(.income) - monthTotal(.expense))
                Text(L10n.text("按自然月统计，与下方预算周期可能不同。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var budgetCard: some View {
        GPCard {
            VStack(alignment: .leading, spacing: DS.spacing) {
                Label(L10n.text("当前预算周期"), systemImage: "chart.bar.fill")
                    .font(.headline)
                    .foregroundStyle(DS.finance)
                FinanceCycleLabel(period: model.period)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if model.period != nil {
                    moneyRow(L10n.text("周期收入"), amount: model.total(.income))
                    moneyRow(L10n.text("周期支出"), amount: model.total(.expense))
                    if let budget = model.budget {
                        let expense = model.total(.expense)
                        let remaining = budget.amountMinor - expense
                        moneyRow(L10n.text("周期预算"), amount: budget.amountMinor)
                        ProgressView(value: GoalMath.savings(current: expense, target: budget.amountMinor))
                            .accessibilityLabel(Text(L10n.text("预算使用进度")))
                        moneyRow(
                            L10n.text(remaining >= 0 ? "剩余预算" : "超出预算"),
                            amount: remaining >= 0 ? remaining : -remaining
                        )
                    } else {
                        Text(L10n.text("尚未设置预算，默认周期从每月 1 日开始。"))
                            .foregroundStyle(.secondary)
                    }
                }
                Button(L10n.text(model.budget == nil ? "设置预算" : "编辑预算")) {
                    showingBudget = true
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func moneyRow(_ title: String, amount: Int64) -> some View {
        LabeledContent {
            Text(verbatim: Money.format(amount, currency: model.currency))
                .monospacedDigit()
                .foregroundStyle(DS.primary)
        } label: {
            Text(verbatim: title)
        }
    }

    private func requestDeletion(_ transaction: LedgerTransaction) {
        pendingDeletion = transaction
        confirmingDeletion = true
    }
}

@MainActor
struct AddTransactionView: View {
    let model: AppViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var draftID: UUID
    @State private var kind: TransactionKind
    @State private var amountText: String
    @State private var category: String
    @State private var date: Date
    @State private var note: String
    @State private var errorMessage: String?
    private let isEditing: Bool
    private let recordCurrency: String

    init(model: AppViewModel, transaction: LedgerTransaction? = nil) {
        self.model = model
        isEditing = transaction != nil
        recordCurrency = transaction?.currency ?? model.currency
        let initialKind = TransactionKind(rawValue: transaction?.kindRaw ?? "") ?? .expense
        let initialCategory = transaction?.category ?? ""
        _draftID = State(initialValue: transaction?.id ?? UUID())
        _kind = State(initialValue: initialKind)
        _amountText = State(initialValue: transaction.map {
            Money.input($0.amountMinor, currency: $0.currency)
        } ?? "")
        _category = State(initialValue: initialKind.categories.contains(initialCategory)
            ? initialCategory : (initialKind.categories.first ?? "其他"))
        _date = State(initialValue: min(transaction?.date ?? .now, .now))
        _note = State(initialValue: transaction?.note ?? "")
    }

    // Update both fields in the same binding setter so the category Picker never
    // renders with a selection that is absent from the new kind's categories.
    private var kindSelection: Binding<TransactionKind> {
        Binding(get: { kind }, set: { newKind in
            if !newKind.categories.contains(category) {
                category = newKind.categories.first ?? "其他"
            }
            kind = newKind
        })
    }

    var body: some View {
        Form {
            if let errorMessage {
                Section { InlineError(message: errorMessage) }
            }
            Section {
                Picker(L10n.text("账单类型"), selection: kindSelection) {
                    ForEach(TransactionKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent(L10n.text("货币"), value: recordCurrency)
                TextField(L10n.text("金额"), text: $amountText)
                    .keyboardType(.decimalPad)
                Picker(L10n.text("分类"), selection: $category) {
                    ForEach(kind.categories, id: \.self) { category in
                        Text(L10n.text(category)).tag(category)
                    }
                }
                DatePicker(L10n.text("日期"), selection: $date, in: ...Date.now, displayedComponents: [.date, .hourAndMinute])
                TextField(L10n.text("备注"), text: $note, axis: .vertical)
                    .lineLimit(3...6)
            } footer: {
                Text(L10n.text("请输入正数金额，不使用千位分隔符。记录时间不能晚于现在。"))
            }
        }
        .tint(DS.finance)
        .navigationTitle(L10n.text(isEditing ? "编辑账单" : "新增账单"))
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.text("取消")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.text("保存"), action: save)
            }
        }
    }

    private func save() {
        do {
            try model.saveTransaction(id: draftID, kind: kind, amountText: amountText,
                                      category: category, date: date, note: note)
            dismiss()
        } catch {
            // Keep all draft fields and the operation UUID intact for a safe retry.
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
struct BudgetEditorView: View {
    let model: AppViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var amountText: String
    @State private var startDay: Int
    @State private var errorMessage: String?

    init(model: AppViewModel) {
        self.model = model
        _amountText = State(initialValue: model.budget.map {
            Money.input($0.amountMinor, currency: $0.currency)
        } ?? "")
        _startDay = State(initialValue: min(28, max(1, model.budget?.startDay ?? 1)))
    }

    var body: some View {
        Form {
            if let errorMessage {
                Section { InlineError(message: errorMessage) }
            }
            Section {
                LabeledContent(L10n.text("货币"), value: model.currency)
                TextField(L10n.text("每周期预算金额"), text: $amountText)
                    .keyboardType(.decimalPad)
                Picker(L10n.text("每月起始日"), selection: $startDay) {
                    ForEach(1...28, id: \.self) { day in
                        Text("\(day)").tag(day)
                    }
                }
            } footer: {
                Text(L10n.text("起始日可选 1 至 28 日。周期包含起始日，不包含下个月的起始日；仅支出占用预算。"))
            }
        }
        .tint(DS.finance)
        .navigationTitle(L10n.text("编辑预算"))
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.text("取消")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.text("保存")) {
                    do {
                        try model.setBudget(amountText: amountText, startDay: startDay)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }
}

@MainActor
struct RecentlyDeletedView: View {
    let model: AppViewModel

    @State private var kindFilter: TransactionKind?
    @State private var searchText = ""
    @State private var errorMessage: String?

    private var transactions: [LedgerTransaction] {
        model.data.transactions.filter {
            $0.deletedAt != nil && $0.currency == model.currency
                && FinanceLedgerFilter.matches($0, kind: kindFilter, search: searchText)
        }.sorted {
            let left = $0.deletedAt ?? .distantPast
            let right = $1.deletedAt ?? .distantPast
            if left == right { return $0.id.uuidString < $1.id.uuidString }
            return left > right
        }
    }

    var body: some View {
        List {
            if let errorMessage {
                Section { InlineError(message: errorMessage) }
            }
            Section {
                FinanceKindPicker(selection: $kindFilter)
                if transactions.isEmpty {
                    ContentUnavailableView(
                        L10n.text("没有匹配的已删除账单"), systemImage: "trash",
                        description: Text(L10n.text("这里显示当前货币下所有日期的已删除账单。"))
                    )
                }
                ForEach(transactions, id: \.id) { transaction in
                    VStack(alignment: .leading, spacing: DS.small) {
                        FinanceTransactionRow(transaction: transaction)
                        if let deletedAt = transaction.deletedAt {
                            LabeledContent {
                                Text(deletedAt, format: .dateTime.year().month().day().hour().minute())
                            } label: {
                                Text(L10n.text("删除时间"))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Button {
                            do {
                                try model.setDeleted(transaction, deleted: false)
                                errorMessage = nil
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        } label: {
                            Label(L10n.text("恢复账单"), systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } header: {
                Text("\(L10n.text("全部日期")) · \(model.currency)")
            } footer: {
                Text(L10n.text("恢复后，账单将按原日期重新计入对应月份和预算周期。"))
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.background)
        .tint(DS.finance)
        .navigationTitle(L10n.text("最近删除"))
        .searchable(text: $searchText, prompt: L10n.text("搜索分类或备注"))
    }
}

// A presentation identity is created by user action, never by a body evaluation.
private struct FinanceTransactionSheet: Identifiable {
    let id = UUID()
    let transaction: LedgerTransaction?
}

@MainActor
private enum FinanceLedgerFilter {
    static func matches(_ transaction: LedgerTransaction, kind: TransactionKind?, search: String) -> Bool {
        if let kind, transaction.kindRaw != kind.rawValue { return false }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || transaction.category.localizedStandardContains(query)
            || L10n.text(transaction.category).localizedStandardContains(query)
            || transaction.note.localizedStandardContains(query)
    }
}

private struct FinanceKindPicker: View {
    @Binding var selection: TransactionKind?

    var body: some View {
        Picker(L10n.text("账单类型"), selection: $selection) {
            Text(L10n.text("全部")).tag(nil as TransactionKind?)
            ForEach(TransactionKind.allCases) { kind in
                Text(kind.title).tag(Optional(kind))
            }
        }
        .pickerStyle(.segmented)
    }
}

private struct FinanceCycleLabel: View {
    let period: DateInterval?

    var body: some View {
        if let period {
            VStack(alignment: .leading, spacing: DS.small / 2) {
                Text("\(L10n.text("开始（含）"))：\(period.start.formatted(date: .abbreviated, time: .omitted))")
                Text("\(L10n.text("结束（不含）"))：\(period.end.formatted(date: .abbreviated, time: .omitted))")
            }
        } else {
            Text(L10n.text("无法计算当前预算周期，请检查预算起始日。"))
        }
    }
}

@MainActor
private struct FinanceTransactionRow: View {
    let transaction: LedgerTransaction

    private var kind: TransactionKind? { TransactionKind(rawValue: transaction.kindRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.small) {
            HStack(alignment: .firstTextBaseline, spacing: DS.small) {
                Text(L10n.text(transaction.category))
                    .font(.headline)
                Spacer(minLength: DS.small)
                Text(verbatim: Money.format(transaction.amountMinor, currency: transaction.currency))
                    .monospacedDigit()
                    .font(.headline)
            }
            Text("\(kind?.title ?? L10n.text("未知类型")) · \(transaction.date.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !transaction.note.isEmpty {
                Text(verbatim: transaction.note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .foregroundStyle(DS.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}