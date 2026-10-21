// Path: C:/Users/YSun14/OneDrive - Rockwell Automation, Inc/Desktop/WorkProject/IOS_PayCheck/GoalPet/Features/Dashboard/DashboardView.swift
// Purpose: Live local dashboard, quick entry and family navigation. Dependencies: AppViewModel, feature editors, PetCatalog, DesignSystem.
import SwiftUI

@MainActor
struct DashboardView: View {
    let model: AppViewModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showTransaction = false
    @State private var showWeight = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.spacing) {
                Text(Date.now, format: .dateTime.year().month().day().weekday())
                    .font(.subheadline).foregroundStyle(.secondary)
                if let name = model.profile?.displayName, !name.isEmpty {
                    Text("你好，\(name)").font(.title2.bold())
                }
                GPCard {
                    VStack(alignment: .leading, spacing: DS.spacing) {
                        HStack {
                            Label("一点一滴，都是进展", systemImage: "sparkle").font(.headline)
                            Spacer()
                        }
                        PixelPetView(speciesID: PetCatalog.all.first?.id ?? "cat")
                            .frame(height: 144).frame(maxWidth: .infinity)
                        Text("把小小坚持，养成新的伙伴。")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                        Text("宠物形象为图鉴演示，尚未接入孵化或奖励。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top),
                                         count: typeSize.isAccessibilitySize ? 1 : 2), spacing: DS.spacing) {
                    MetricCard(title: "本期支出", value: Money.format(model.total(.expense), currency: model.currency),
                               systemImage: "creditcard", tint: DS.finance)
                    MetricCard(title: "最近体重", value: latestWeightText,
                               systemImage: "heart", tint: DS.health)
                }
                GPCard {
                    VStack(alignment: .leading, spacing: DS.small) {
                        Text("月度预算").font(.headline)
                        if let budget = model.budget {
                            Text(Money.format(budget.amountMinor - model.total(.expense), currency: budget.currency))
                                .font(.title2.bold()).monospacedDigit()
                            Text("当前周期剩余；计划可以随时调整。")
                                .font(.caption).foregroundStyle(.secondary)
                            if let period = model.period {
                                Text("\(period.start.formatted(date: .abbreviated, time: .omitted)) 至 \(period.end.formatted(date: .abbreviated, time: .omitted))（不含结束日）")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else { Text("尚未设置预算，可在记账页设置。") }
                    }
                }
                Text("今天，记录一小步").font(.title3.bold())
                Button { showTransaction = true } label: { Label("记一笔收入或支出", systemImage: "plus.circle.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button { showWeight = true } label: { Label("记录体重", systemImage: "scalemass").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)

                GPCard {
                    VStack(alignment: .leading, spacing: DS.small) {
                        NavigationLink { SavingsGoalView(model: model) } label: {
                            Label("我的攒钱目标", systemImage: "flag.fill").font(.headline)
                        }
                        if let goal = model.personalGoals.first(where: { $0.statusRaw == "active" }) {
                            Text(goal.name)
                            ProgressView(value: GoalMath.savings(current: model.balance(goal), target: goal.targetMinor)).tint(DS.finance)
                            Text("\(Money.format(model.balance(goal), currency: goal.currency)) / \(Money.format(goal.targetMinor, currency: goal.currency))")
                                .font(.subheadline).monospacedDigit()
                        } else { Text("先选一个值得期待的小目标。").foregroundStyle(.secondary) }
                    }
                }
                GPCard {
                    NavigationLink { FamilyView(model: model) } label: {
                        VStack(alignment: .leading, spacing: DS.small) {
                            Label("家庭与共同目标", systemImage: "person.2.fill").font(.headline)
                            Text("本机规划演示 · 不会共享个人账单或健康记录")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding(DS.spacing)
        }
        .background(DS.background)
        .navigationTitle("攒攒兽")
        .sheet(isPresented: $showTransaction) { NavigationStack { AddTransactionView(model: model) } }
        .sheet(isPresented: $showWeight) { WeightEntryView(model: model) }
    }

    private var latestWeightText: String {
        guard let record = model.latestWeight else { return L10n.text("尚未记录") }
        return "\(NumberInput.format(model.unit.display(record.kilograms))) \(model.unit.rawValue)"
    }
}

#Preview("首页 · 浅色") {
    PreviewHost { model in NavigationStack { DashboardView(model: model) } }.preferredColorScheme(.light)
}
#Preview("首页 · 深色") {
    PreviewHost { model in NavigationStack { DashboardView(model: model) } }.preferredColorScheme(.dark)
}