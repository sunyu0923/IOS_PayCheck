// Path: C:/Users/YSun14/OneDrive - Rockwell Automation, Inc/Desktop/WorkProject/IOS_PayCheck/GoalPet/App/GoalPetApp.swift
// Purpose: Composition root and recoverable storage startup. Dependencies: LocalRepository, AppViewModel, RootTabView.
import SwiftUI

@main
struct GoalPetApp: App {
    var body: some Scene {
        WindowGroup { AppBootstrapView() }
    }
}

@MainActor
struct AppBootstrapView: View {
    @State private var model: AppViewModel?
    @State private var failed = false

    var body: some View {
        Group {
            if let model {
                AppRuntimeView(model: model)
            } else if failed {
                ContentUnavailableView {
                    Label("暂时无法打开本机数据", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("原始数据不会被自动删除。请确认设备存储空间后重试。错误码：STORE_OPEN")
                } actions: {
                    Button("重试", action: open).buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView("正在打开本机数据")
            }
        }
        .task { if model == nil && !failed { open() } }
    }

    private func open() {
        failed = false
        do {
            let container = try LocalRepository.makeContainer()
            let repository = try LocalRepository(container: container)
            model = try AppViewModel(repository: repository)
        } catch {
            // Never silently replace a failed persistent store with an empty one.
            failed = true
        }
    }
}