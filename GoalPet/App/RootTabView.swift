// Path: C:/Users/YSun14/OneDrive - Rockwell Automation, Inc/Desktop/WorkProject/IOS_PayCheck/GoalPet/App/RootTabView.swift
// Purpose: Five-tab native navigation and appearance preferences. Dependencies: feature views, AppViewModel, DesignSystem.
import SwiftUI

@MainActor
struct RootTabView: View {
    let model: AppViewModel
    var watch: PhoneWatchSync? = nil
    @AppStorage("appearance") private var appearance = AppTheme.system.rawValue

    var body: some View {
        TabView {
            NavigationStack { DashboardView(model: model) }
                .tabItem { Label("首页", systemImage: "house.fill") }
            NavigationStack { FinanceView(model: model) }
                .tabItem { Label("记账", systemImage: "creditcard.fill") }
            NavigationStack { HealthDashboardView(model: model) }
                .tabItem { Label("健康", systemImage: "heart.fill") }
            NavigationStack { PetCollectionView(model: model) }
                .tabItem { Label("宠物", systemImage: "pawprint.fill") }
            NavigationStack { SettingsView(model: model, appearance: $appearance, watch: watch) }
                .tabItem { Label("我的", systemImage: "person.crop.circle.fill") }
        }
        .tint(DS.accent)
        .preferredColorScheme((AppTheme(rawValue: appearance) ?? .system).colorScheme)
    }
}

@MainActor
struct SettingsView: View {
    let model: AppViewModel
    @Binding var appearance: String
    var watch: PhoneWatchSync? = nil
    @State private var showProfile = false

    var body: some View {
        Form {
            Section("目标与设备") {
                NavigationLink("每日任务、阶段与奖励") { GoalProgressView(model: model) }
                NavigationLink("iPhone HealthKit 数据") { HealthKitView() }
                if let watch {
                    NavigationLink("Apple Watch 同步") { WatchSettingsView(sync: watch) }
                }
            }
            Section("个人") {
                Button("资料与单位") { showProfile = true }
                Picker("外观", selection: $appearance) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0.rawValue) }
                }
                LabeledContent("当前货币", value: model.currency)
                Text("本阶段固定使用人民币。模型与格式化已支持其他货币，暂不提供汇率换算。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("一起实现目标") {
                NavigationLink { FamilyView(model: model) } label: {
                    Label("家庭与共同目标", systemImage: "person.2.fill")
                }
                Text("本地演示：成员是规划用标签，不会邀请真实用户，也不会同步或上传数据。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("存储与版本") {
                NavigationLink("最近删除的账单") { RecentlyDeletedView(model: model) }
                Label("HealthKit 与家庭数据不发送给第三方", systemImage: "lock.shield")
                Text("系统设备备份不等于应用主动同步。照片识别与配对手表同步须分别同意。本地奖励账本已实现，但尚未提供全量导出、删除和已验证的旧库迁移，不能直接作为 App Store 成品发布。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("GoalPet · 本地目标与配对设备版本")
            }
        }
        .navigationTitle("我的")
        .sheet(isPresented: $showProfile) { ProfileEditorView(model: model) }
    }
}

#Preview("完整应用 · 示例数据") {
    PreviewHost { RootTabView(model: $0) }
}