// File: C:/Users/YSun14/OneDrive - Rockwell Automation, Inc/Desktop/WorkProject/IOS_PayCheck/GoalPet/Features/Nutrition/NutritionHistoryView.swift
// Purpose: All-date confirmed meal history, estimated food details and confirmation-gated deletion.
// Dependencies: SwiftUI, Foundation; AppViewModel, FoodRecord/FoodItem, MealType,
// FoodRecognitionMode, FoodRecognitionView, NumberInput, InputError, DS, InlineError,
// L10n, PreviewHost. iOS 17+, Swift 5. Caller owns navigation; no direct database access.

import SwiftUI
import Foundation

@MainActor
struct NutritionHistoryView: View {
    let model: AppViewModel

    @State private var showsRecognition = false
    @State private var pendingDeletion: UUID?
    @State private var confirmsDeletion = false
    @State private var errorMessage: String?

    private var meals: [FoodRecord] {
        model.data.meals.sorted {
            $0.recordDate == $1.recordDate
                ? $0.id.uuidString < $1.id.uuidString : $0.recordDate > $1.recordDate
        }
    }

    // The caller supplies NavigationStack. Only the add sheet creates its own stack.
    var body: some View {
        List {
            Section {
                Label("私人饮食记录", systemImage: "lock.shield")
                    .font(.headline)
                    .foregroundStyle(DS.health)
                Text("仅显示你已确认保存的餐食，按用餐时间从新到旧排列，包含所有日期。记录不与家庭成员共享，照片不保存在饮食数据库中。")
                    .foregroundStyle(.secondary)
                Text("热量和营养值均为估算；空白或未知不等于零。Mock 演示不会进入此列表。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Section { InlineError(message: errorMessage) }
            }
            Section {
                if meals.isEmpty {
                    ContentUnavailableView {
                        Label("尚无饮食记录", systemImage: "fork.knife")
                    } description: {
                        Text("手动添加一餐，或选择照片并在核对后确认保存。没有记录不代表摄入为零。")
                    } actions: {
                        Button("添加饮食记录") { showsRecognition = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ForEach(meals, id: \.id) { meal in
                        VStack(alignment: .leading, spacing: DS.small) {
                            NavigationLink {
                                NutritionMealDetailView(model: model, mealID: meal.id)
                            } label: {
                                mealRow(meal)
                            }
                            Button(role: .destructive) { requestDeletion(meal.id) } label: {
                                Label("删除记录", systemImage: "trash")
                                    .padding(.vertical, DS.small)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text(verbatim: L10n.text("删除记录") + " · "
                                                     + NutritionHistoryText.date(meal.recordDate)))
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("删除", role: .destructive) { requestDeletion(meal.id) }
                        }
                    }
                }
            } header: { Text("全部饮食记录") }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DS.background)
        .tint(DS.health)
        .navigationTitle(Text("饮食历史"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showsRecognition = true } label: {
                    Label("添加饮食记录", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showsRecognition) { FoodRecognitionView(model: model) }
        .alert("删除这餐饮食记录？", isPresented: $confirmsDeletion, presenting: pendingDeletion) { id in
            Button("取消", role: .cancel) { pendingDeletion = nil }
            Button("删除", role: .destructive) { delete(id) }
        } message: { id in
            if let meal = model.data.meals.first(where: { $0.id == id }) {
                Text(verbatim: NutritionHistoryText.mealType(meal.mealTypeRaw) + " · "
                     + NutritionHistoryText.date(meal.recordDate) + "\n"
                     + L10n.text("此餐及所有食物条目将从本地记录删除，无法撤销。不会删除图库原图，也不能撤回服务器已收到的数据。"))
            } else {
                Text("此记录已不存在。")
            }
        }
    }

    private func mealRow(_ meal: FoodRecord) -> some View {
        VStack(alignment: .leading, spacing: DS.small) {
            Text(verbatim: NutritionHistoryText.mealType(meal.mealTypeRaw))
                .font(.headline)
                .foregroundStyle(DS.primary)
            Text(verbatim: NutritionHistoryText.date(meal.recordDate))
                .font(.subheadline)
            Text(verbatim: NutritionHistoryText.source(meal.sourceRaw))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(verbatim: NutritionHistoryText.calories(meal))
                .font(.subheadline.monospacedDigit())
            Text(verbatim: L10n.text("食物条目") + "：\(meal.items.count)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func requestDeletion(_ id: UUID) {
        pendingDeletion = id
        confirmsDeletion = true
    }

    private func delete(_ id: UUID) {
        defer { pendingDeletion = nil }
        do {
            if let meal = model.data.meals.first(where: { $0.id == id }) {
                try model.deleteMeal(meal)
            }
            errorMessage = nil
        } catch let error as InputError {
            errorMessage = error.errorDescription ?? L10n.text("删除失败，请重试。")
        } catch {
            errorMessage = L10n.text("暂时无法删除，请重试。错误码：STORE_WRITE")
        }
    }
}

@MainActor
private struct NutritionMealDetailView: View {
    let model: AppViewModel
    let mealID: UUID

    private var meal: FoodRecord? { model.data.meals.first { $0.id == mealID } }

    var body: some View {
        List {
            // Resolve by ID on each render instead of retaining a potentially deleted model object.
            if let meal {
                Section {
                    LabeledContent("餐别", value: NutritionHistoryText.mealType(meal.mealTypeRaw))
                    LabeledContent("用餐时间", value: NutritionHistoryText.date(meal.recordDate))
                    LabeledContent("确认时间", value: NutritionHistoryText.date(meal.confirmedAt))
                    LabeledContent("来源", value: NutritionHistoryText.source(meal.sourceRaw))
                    Text(verbatim: NutritionHistoryText.calories(meal))
                        .font(.headline.monospacedDigit())
                    if meal.hasIncompleteCalories {
                        Text("部分食物没有热量点估值，已知小计不是整餐总量；未知值不按零计算，也不使用范围中点补齐。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: { Text("已确认的餐食") }

                if meal.items.isEmpty {
                    Section { Text("此餐没有食物条目，热量与营养数据未知。") }
                }
                ForEach(meal.items.sorted { $0.id.uuidString < $1.id.uuidString }, id: \.id) { item in
                    foodSection(item)
                }
                Section {
                    Text("所有数值均为记录时确认的估算，仅供一般信息参考，不是诊断、饮食处方或摄入目标。热量范围不是置信区间。")
                    Text("本地记录不与家庭成员共享，不包含照片。删除本地记录不能撤回已上传到服务器的数据。")
                } header: { Text("估算与隐私说明") }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("记录不存在", systemImage: "fork.knife",
                                       description: Text("此记录可能已被删除，请返回饮食历史。"))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DS.background)
        .tint(DS.health)
        .navigationTitle(Text("餐食详情"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func foodSection(_ item: FoodItem) -> some View {
        Section {
            LabeledContent("烹饪方式", value: NutritionHistoryText.optionalText(item.cookingMethod))
            LabeledContent("分量描述", value: NutritionHistoryText.optionalText(item.servingDescription))
            LabeledContent("估算重量", value: NutritionHistoryText.value(item.weightGrams, unit: "g"))
            LabeledContent("热量点估值", value: NutritionHistoryText.value(item.calories, unit: "kcal"))
            LabeledContent("热量估算范围", value: NutritionHistoryText.range(item))
            LabeledContent("估算蛋白质", value: NutritionHistoryText.value(item.proteinGrams, unit: "g"))
            LabeledContent("估算碳水化合物", value: NutritionHistoryText.value(item.carbohydrateGrams, unit: "g"))
            LabeledContent("估算脂肪", value: NutritionHistoryText.value(item.fatGrams, unit: "g"))
            if item.isAIRecognized {
                Text("AI 识别起草，经用户核对；确认不代表估算已被科学验证。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(verbatim: item.name)
        }
    }
}

@MainActor
private enum NutritionHistoryText {
    static func date(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }

    static func mealType(_ raw: String) -> String {
        MealType(rawValue: raw)?.title ?? L10n.text("未知餐别")
    }

    static func source(_ raw: String) -> String {
        switch FoodRecognitionMode(rawValue: raw) {
        case .manual: return L10n.text("手动记录 · 用户确认")
        case .remote: return L10n.text("Remote 识别 · 用户核对")
        case .mock: return L10n.text("Mock 演示 · 非正式记录")
        case nil: return L10n.text("来源未知")
        }
    }

    static func optionalText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L10n.text("未记录") : text
    }

    static func value(_ number: Double?, unit: String) -> String {
        guard let number else { return L10n.text("未知（未记录）") }
        return NumberInput.format(number) + " " + unit
    }

    static func range(_ item: FoodItem) -> String {
        guard item.calorieLower != nil || item.calorieUpper != nil else { return L10n.text("未知（未记录）") }
        return value(item.calorieLower, unit: "kcal") + " – " + value(item.calorieUpper, unit: "kcal")
    }

    static func calories(_ meal: FoodRecord) -> String {
        guard !meal.items.isEmpty, meal.items.contains(where: { $0.calories != nil }) else {
            return L10n.text("热量合计：未知（未记录热量点估值）")
        }
        let label = meal.hasIncompleteCalories
            ? L10n.text("已知热量小计（估算；不完整）") : L10n.text("热量合计（估算）")
        return label + "：" + value(meal.knownCalories, unit: "kcal")
    }
}

#Preview("饮食历史 · 空记录") {
    PreviewHost { model in
        NavigationStack { NutritionHistoryView(model: model) }
    }
}