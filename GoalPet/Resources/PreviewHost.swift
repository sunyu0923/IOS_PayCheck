// Path: C:/Users/YSun14/OneDrive - Rockwell Automation, Inc/Desktop/WorkProject/IOS_PayCheck/GoalPet/Resources/PreviewHost.swift
// Purpose: Isolated in-memory SwiftUI preview fixture; never writes to the production store.
// Dependencies: LocalRepository, AppViewModel, Models, SwiftUI.
import SwiftUI

@MainActor
struct PreviewHost<Content: View>: View {
    private let content: (AppViewModel) -> Content
    @State private var model: AppViewModel?
    @State private var failed = false

    init(@ViewBuilder content: @escaping (AppViewModel) -> Content) { self.content = content }

    var body: some View {
        Group {
            if let model { content(model) }
            else if failed { Text("无法加载预览示例") }
            else { ProgressView("加载预览") }
        }.task {
            guard model == nil && !failed else { return }
            do { model = try PreviewFixtures.makeModel() }
            catch { failed = true }
        }
    }
}

@MainActor enum PreviewFixtures {
    static func makeModel() throws -> AppViewModel {
        let repository = try LocalRepository(container: LocalRepository.makeContainer(inMemory: true))
        let model = try AppViewModel(repository: repository)
        try model.setBudget(amountText: "3000", startDay: 1)
        try model.saveTransaction(id: UUID(), kind: .expense, amountText: "32", category: "餐饮", date: .now, note: "预览示例")
        try model.saveGoal(title: "旅行基金 · 示例", targetText: "12000", initialText: "1800", date: .now, familyID: nil)
        for index in 0..<7 {
            if let date = Calendar.current.date(byAdding: .day, value: -index, to: .now) {
                try model.saveWeight(id: UUID(), value: NumberInput.format(70 + Double(index) * 0.1), date: date, note: "预览示例")
            }
        }
        try model.createFamily(title: "伙伴小家 · 示例")
        if let family = model.data.families.first {
            try model.addMember(familyID: family.id, displayName: "伙伴 · 示例")
            try model.saveGoal(title: "共同旅行 · 示例", targetText: "20000", initialText: "0", date: .now, familyID: family.id)
        }
        return model
    }
}