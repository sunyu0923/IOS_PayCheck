// Production lifecycle integration. Previews do not start a WatchConnectivity session.
import SwiftUI
import Combine

@MainActor
struct AppRuntimeView: View {
    let model: AppViewModel
    @StateObject private var watch = PhoneWatchSync()
    @Environment(\.scenePhase) private var phase
    @State private var lastDay: Int?
    @State private var refreshFailed = false
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        RootTabView(model: model, watch: watch)
            .safeAreaInset(edge: .top) {
                if refreshFailed {
                    Button("目标状态刷新失败，点此重试") { refresh() }
                        .font(.footnote).padding(8)
                }
            }
            .task { refresh() }
            .onChange(of: phase) { _, phase in
                if phase == .active { refresh() }
            }
            .onChange(of: model.evaluation) { _, _ in publish() }
            .onChange(of: model.experience) { _, _ in publish() }
            .onChange(of: model.unlockedPetIDs) { _, _ in publish() }
            .onChange(of: watch.isEnabled) { _, _ in publish() }
            .onReceive(clock) { date in
                guard phase == .active else { return }
                let day = Int(floor(date.timeIntervalSince1970 / 86_400))
                if day != lastDay { refresh() }
                else { publish() }
            }
    }

    private func refresh() {
        do {
            try model.refreshProgress()
            lastDay = Int(floor(Date().timeIntervalSince1970 / 86_400))
            refreshFailed = false
        } catch { refreshFailed = true }
        watch.start()
        if !refreshFailed { publish() }
    }

    private func publish() {
        watch.publish(tasks: model.evaluation.tasks.map {
            WatchTaskSnapshot(id: $0.id, title: $0.title, isComplete: $0.isComplete)
        }, experience: model.experience, petIDs: model.unlockedPetIDs.sorted(), now: Date())
    }
}