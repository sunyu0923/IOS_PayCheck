// File: c:\Users\YSun14\OneDrive - Rockwell Automation, Inc\Desktop\WorkProject\IOS_PayCheck\GoalPet\Features\Family\FamilyView.swift
// Purpose: A single local family, member labels, and navigation to locally recorded family savings.
// Dependencies: SwiftUI, Foundation; AppViewModel, FamilyGroup, SavingsGoalView, DS, GPCard, InlineError, L10n. iOS 17+, Swift 5.

import Foundation
import SwiftUI

@MainActor
struct FamilyView: View {
    let model: AppViewModel
    @State private var showsFamilyEditor = false
    @State private var memberEditorFamily: FamilyGroup?
    @State private var renameTarget: FamilyRenameTarget?
    @State private var archiveTarget: FamilyArchiveTarget?
    @State private var showsArchiveConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage { Section { InlineError(message: errorMessage) } }
            Section {
                GPCard {
                    VStack(alignment: .leading, spacing: DS.small) {
                        Label("仅限本机的家庭规划", systemImage: "iphone")
                            .font(.headline)
                            .foregroundStyle(DS.finance)
                        Text("本页只在此设备保存家庭名称、成员标签和储蓄记录。没有真实邀请、登录、身份验证或数据共享，也不会转移真实资金。")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("不会共享个人账本、健康或饮食数据。角色只是本机标签，不代表账号权限。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if let family = model.data.families.first {
                Section {
                    LabeledContent("家庭名称", value: family.name)
                    LabeledContent("创建日期") { Text(family.createdAt, style: .date) }
                    Button("重命名家庭") {
                        renameTarget = FamilyRenameTarget(id: family.id, name: family.name, isMember: false)
                    }
                } header: {
                    Text("我的本地家庭")
                } footer: {
                    Text("本阶段仅支持一个本地家庭组。")
                }

                Section {
                    ForEach(model.familyMembers(in: family.id)) { member in
                        memberRow(member, familyID: family.id)
                    }
                    Button { memberEditorFamily = family } label: {
                        Label("添加成员标签", systemImage: "person.badge.plus")
                    }
                } header: {
                    Text("成员标签")
                } footer: {
                    Text("添加标签不会发送邀请或通知。净记录额按目标币种分别统计存入减取出，包含归档目标，不含初始金额及已删除记录。")
                }

                let archivedMembers = model.familyMembers(in: family.id, includeArchived: true).filter(\.isArchived)
                if !archivedMembers.isEmpty {
                    Section {
                        ForEach(archivedMembers) { member in
                            memberRow(member, familyID: family.id)
                        }
                    } header: {
                        Text("已归档成员标签")
                    } footer: {
                        Text("归档只停止新记录中的成员选择，不会删除历史。名称仍保留；如有重名，请先重命名再恢复。")
                    }
                }

                Section {
                    NavigationLink {
                        SavingsGoalView(model: model, familyID: family.id)
                    } label: {
                        Label("查看或创建家庭储蓄计划", systemImage: "person.2.circle")
                    }
                } header: {
                    Text("共同目标 · 本机记录")
                } footer: {
                    Text("家庭计划与个人计划分开显示。进入后可查看进行中及已归档的目标，并按成员标签记录存入或取出。")
                }
            } else {
                Section {
                    ContentUnavailableView {
                        Label("创建一个本地家庭", systemImage: "house")
                    } description: {
                        Text("用一个家庭名称，整理你在本机记录的共同储蓄目标。")
                    } actions: {
                        Button("创建家庭") { showsFamilyEditor = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.background)
        .tint(DS.finance)
        .navigationTitle(Text("家庭"))
        .sheet(isPresented: $showsFamilyEditor) {
            NavigationStack { LocalFamilyEditorView(model: model) }
        }
        .sheet(item: $memberEditorFamily) { family in
            NavigationStack { LocalFamilyEditorView(model: model, family: family) }
        }
        .sheet(item: $renameTarget) { target in
            NavigationStack { FamilyRenameEditor(model: model, target: target) }
        }
        .confirmationDialog("更改本机成员标签状态？", isPresented: $showsArchiveConfirmation,
                            titleVisibility: .visible, presenting: archiveTarget) { target in
            Button(target.archived ? L10n.text("归档成员标签") : L10n.text("恢复成员标签")) {
                errorMessage = nil
                do { try model.setFamilyMemberArchived(id: target.id, archived: target.archived) }
                catch { errorMessage = L10n.text(error.localizedDescription) }
                archiveTarget = nil
            }
            Button("取消", role: .cancel) { archiveTarget = nil }
        } message: { target in
            Text(verbatim: target.name + "\n")
                + Text("仅更改此设备上的标签状态，历史资金记录和目标余额保持不变。不会发送通知。")
        }
    }

    private func memberRow(_ member: FamilyMember, familyID: UUID) -> some View {
        VStack(alignment: .leading, spacing: DS.small) {
            Label {
                Text(verbatim: member.displayName).font(.headline)
            } icon: {
                Image(systemName: member.isArchived ? "archivebox" : "person.crop.circle")
                    .foregroundStyle(DS.finance)
            }
            Text(member.roleRaw == "owner" ? L10n.text("创建者标签 · 不能归档 · 非登录账号")
                 : L10n.text("本机成员标签 · 非登录账号"))
                .font(.caption).foregroundStyle(.secondary)
            let currencies = Set(model.data.goals.filter { $0.familyGroupID == familyID }.map(\.currency)).sorted()
            if currencies.isEmpty {
                Text("暂无家庭储蓄记录").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(currencies, id: \.self) { code in
                LabeledContent {
                    Text(verbatim: Money.format(model.memberContributionTotal(
                        familyID: familyID, memberID: member.id, currency: code), currency: code))
                        .monospacedDigit()
                } label: {
                    Text("净记录额") + Text(verbatim: " · \(code)")
                }
                .font(.callout)
            }
            HStack {
                Button("重命名") {
                    renameTarget = FamilyRenameTarget(id: member.id, name: member.displayName, isMember: true)
                }
                .accessibilityLabel(Text("重命名") + Text(verbatim: " \(member.displayName)"))
                Spacer()
                if member.roleRaw != "owner" || member.isArchived {
                    Button(member.isArchived ? L10n.text("恢复标签") : L10n.text("归档标签")) {
                        archiveTarget = FamilyArchiveTarget(id: member.id, name: member.displayName,
                                                            archived: !member.isArchived)
                        showsArchiveConfirmation = true
                    }
                    .accessibilityLabel(Text(member.isArchived ? L10n.text("恢复标签") : L10n.text("归档标签"))
                                        + Text(verbatim: " \(member.displayName)"))
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, DS.small)
    }
}

private struct FamilyRenameTarget: Identifiable {
    let id: UUID
    let name: String
    let isMember: Bool
}

private struct FamilyArchiveTarget {
    let id: UUID
    let name: String
    let archived: Bool
}

@MainActor
private struct FamilyRenameEditor: View {
    let model: AppViewModel
    let target: FamilyRenameTarget
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var errorMessage: String?

    init(model: AppViewModel, target: FamilyRenameTarget) {
        self.model = model
        self.target = target
        _name = State(initialValue: target.name)
    }

    var body: some View {
        Form {
            if let errorMessage { Section { InlineError(message: errorMessage) } }
            Section {
                TextField(target.isMember ? L10n.text("成员标签名称") : L10n.text("家庭名称"), text: $name)
            } footer: {
                Text("名称需为 1 至 60 个字符。成员名称不可与本家庭的任何标签重名（包含已归档标签，不区分大小写和音调符号）。")
            }
            Section {
                Text("只更新本机名称，不更改成员标识、资金记录或目标余额。取消不会保存输入。")
            }
        }
        .tint(DS.finance)
        .navigationTitle(Text(target.isMember ? L10n.text("重命名成员标签") : L10n.text("重命名家庭")))
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
            if target.isMember { try model.renameFamilyMember(id: target.id, displayName: name) }
            else { try model.renameFamily(id: target.id, title: name) }
            dismiss()
        } catch { errorMessage = L10n.text(error.localizedDescription) }
    }
}

@MainActor
private struct LocalFamilyEditorView: View {
    let model: AppViewModel
    let family: FamilyGroup?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var errorMessage: String?

    init(model: AppViewModel, family: FamilyGroup? = nil) {
        self.model = model
        self.family = family
    }

    var body: some View {
        Form {
            if let errorMessage { Section { InlineError(message: errorMessage) } }
            Section {
                if let family {
                    LabeledContent("所属家庭", value: family.name)
                    TextField("成员标签名称", text: $name)
                } else {
                    TextField("家庭名称", text: $name)
                }
            } footer: {
                Text("名称需为 1 至 60 个字符。保存前不会更改数据；取消将丢弃本次输入。")
            }
            Section {
                if family == nil {
                    Text("本阶段只支持一个本地家庭。创建时会自动添加“我”作为创建者标签。")
                } else {
                    Text("这是成员标签，不是真实邀请。不会创建账号、发送通知或向其他设备共享数据。")
                }
            }
        }
        .tint(DS.finance)
        .navigationTitle(Text(family == nil ? L10n.text("创建家庭") : L10n.text("添加成员标签")))
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
            if let family {
                try model.addMember(familyID: family.id, displayName: name)
            } else {
                try model.createFamily(title: name)
            }
            dismiss()
        } catch { errorMessage = L10n.text(error.localizedDescription) }
    }
}
