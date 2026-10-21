import SwiftUI

@MainActor struct WatchDashboardView: View {
    @ObservedObject var store: WatchSnapshotStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            NavigationStack {
                List {
                    Section {
                        Label("GoalPet", systemImage: "pawprint.fill")
                            .font(.headline)
                            .foregroundStyle(.mint)
                        Text(store.status).font(.caption2)
                        if let snapshot = store.state.visibleSnapshot {
                            if snapshot.isStale(at: timeline.date) {
                                Label("Stale · open iPhone", systemImage: "clock.badge.exclamationmark")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            Text("Updated \(snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                            if !store.isCached, let received = store.state.receivedAt {
                                Text("Received \(received.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let snapshot = store.state.visibleSnapshot {
                        Section("Daily tasks · UTC") {
                            if snapshot.tasks.isEmpty { Text("No tasks shared").font(.caption) }
                            ForEach(snapshot.tasks) { task in
                                Label(task.title, systemImage: task.isComplete ? "checkmark.circle.fill" : "circle")
                                    .font(.caption)
                                    .foregroundStyle(task.isComplete ? Color.mint : Color.primary)
                                    .accessibilityLabel("\(task.title), \(task.isComplete ? "complete" : "incomplete")")
                            }
                        }
                        Section("Pet collection") {
                            Label("\(snapshot.experience) XP", systemImage: "sparkles")
                                .foregroundStyle(.mint)
                            if snapshot.petIDs.isEmpty { Text("No pets shared").font(.caption) }
                            ForEach(snapshot.petIDs, id: \.self) { petID in
                                Label(petID, systemImage: "pawprint").font(.caption)
                            }
                        }
                    } else {
                        Section {
                            Text(store.state.isLocallyBlocked ? "Hidden on this watch" :
                                 (store.state.latest?.isCleared == true ? "Waiting for new shared data" : "No snapshot yet"))
                                .font(.headline)
                        }
                    }

                    Section("Watch privacy") {
                        if store.state.isLocallyBlocked {
                            Button("Show new iPhone updates", systemImage: "eye") {
                                store.showNewPhoneUpdates()
                            }
                            Text("Data stays hidden until you allow updates here. Previously received data will not return; open iPhone for a new update.")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Button(role: .destructive) {
                                store.clearAndHide()
                            } label: {
                                Label("Clear and hide on Watch", systemImage: "eye.slash")
                            }
                            Text("Immediately clears this app's saved tasks, XP and pets, even offline. iPhone sharing cannot undo this choice.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    Section("Read-only companion") {
                        Text("To refresh, open GoalPet on your iPhone and enable Watch sharing. Changes sync when available.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text("Complete tasks on iPhone. This watch cannot award XP or edit data.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("GoalPet")
            }
        }
    }
}
