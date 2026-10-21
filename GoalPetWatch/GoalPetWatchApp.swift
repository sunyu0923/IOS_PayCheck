import SwiftUI

@main
@MainActor struct GoalPetWatchApp: App {
    @StateObject private var store = WatchSnapshotStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchDashboardView(store: store)
                .task { store.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.start() }
                }
        }
    }
}
