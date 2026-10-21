// File: c:\Users\YSun14\OneDrive - Rockwell Automation, Inc\Desktop\WorkProject\IOS_PayCheck\GoalPet\Features\Pets\PetCollectionView.swift
// Purpose: Read-only pet ownership from AppViewModel, with an explicit catalog-only preview when absent.
// Dependencies: SwiftUI; AppViewModel, DS, GPCard, L10n, PetCatalog, PetDefinition, PixelPetView. iOS 17+, Swift 5.

import SwiftUI

@MainActor
struct PetCollectionView: View {
    let model: AppViewModel?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedPet: PetDefinition?

    init(model: AppViewModel? = nil) {
        self.model = model
    }

    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 240), spacing: DS.spacing)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.spacing) {
                    ownershipBanner

                    VStack(alignment: .leading, spacing: DS.small) {
                        Text("认识你的小小同伴")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .accessibilityAddTraits(.isHeader)
                        Text("三位原创像素朋友，三个关于日常的小故事。轻点卡片，翻开它们的介绍。")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        if let model {
                            Text("累计经验：\(model.experience) XP")
                                .font(.headline)
                                .monospacedDigit()
                                .foregroundStyle(DS.reward)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    LazyVGrid(columns: columns, spacing: DS.spacing) {
                        ForEach(PetCatalog.all) { pet in
                            Button {
                                selectedPet = pet
                            } label: {
                                catalogCard(pet)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: pet.name))
                            .accessibilityValue(Text(verbatim: ownershipTitle(pet)))
                            .accessibilityHint(Text("打开宠物故事与解锁说明"))
                        }
                    }

                    Text(model == nil
                        ? L10n.text("仅图鉴预览：未连接个人数据，不能判断是否已获得宠物。")
                        : L10n.text("拥有状态来自本机奖励记录，不根据图鉴文案判断。奖励自动保存，无需领取；删除来源记录或暂停目标不会收回已获得的宠物。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DS.spacing)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .background(DS.background)
            .foregroundStyle(DS.primary)
            .navigationTitle(Text("宠物图鉴"))
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedPet) { pet in
                PetDetailSheet(pet: pet, model: model)
            }
        }
    }

    private var ownershipBanner: some View {
        Label {
            Text(model == nil ? L10n.text("仅图鉴预览 · 未连接个人数据") : L10n.text("我的宠物 · 本机奖励记录"))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle.fill")
                .accessibilityHidden(true)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(DS.finance)
        .padding(DS.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.finance.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.radius))
        .accessibilityElement(children: .combine)
    }

    private func catalogCard(_ pet: PetDefinition) -> some View {
        GPCard {
            VStack(alignment: .leading, spacing: DS.spacing) {
                PixelPetView(speciesID: pet.id)
                    .frame(width: 144, height: 144)
                    .padding(DS.spacing)
                    .frame(maxWidth: .infinity)
                    .background(pet.palette.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.radius - DS.small))
                    .accessibilityHidden(true)

                Label(ownershipTitle(pet), systemImage: ownershipIcon(pet))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(pet.palette)

                Text(verbatim: pet.name)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(DS.primary)

                Text(verbatim: pet.unlockHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Label("阅读故事", systemImage: "arrow.up.right")
                    .font(.body.weight(.medium))
                    .foregroundStyle(pet.palette)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ownershipTitle(_ pet: PetDefinition) -> String {
        guard let model else { return L10n.text("仅图鉴预览 · 拥有状态未知") }
        return model.unlockedPetIDs.contains(pet.id) ? L10n.text("已获得") : L10n.text("尚未解锁")
    }

    private func ownershipIcon(_ pet: PetDefinition) -> String {
        guard let model else { return "book" }
        return model.unlockedPetIDs.contains(pet.id) ? "checkmark.seal.fill" : "lock"
    }
}

@MainActor
private struct PetDetailSheet: View {
    let pet: PetDefinition
    let model: AppViewModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.spacing) {
                    Group {
                        if let model {
                            Label(model.unlockedPetIDs.contains(pet.id) ? L10n.text("已获得") : L10n.text("尚未解锁"),
                                  systemImage: model.unlockedPetIDs.contains(pet.id) ? "checkmark.seal.fill" : "lock")
                        } else {
                            Label("仅图鉴预览 · 拥有状态未知", systemImage: "book")
                        }
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(pet.palette)

                    PixelPetView(speciesID: pet.id)
                        .frame(width: 192, height: 192)
                        .padding(DS.spacing)
                        .frame(maxWidth: .infinity)
                        .background(pet.palette.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.radius))

                    GPCard {
                        VStack(alignment: .leading, spacing: DS.small) {
                            Text("它的故事")
                                .font(.title2.bold())
                                .accessibilityAddTraits(.isHeader)
                            Text(verbatim: pet.story)
                                .font(.body)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    GPCard {
                        VStack(alignment: .leading, spacing: DS.small) {
                            Label("解锁说明", systemImage: "sparkles")
                                .font(.headline)
                                .foregroundStyle(pet.palette)
                                .accessibilityAddTraits(.isHeader)
                            Text(verbatim: pet.unlockHint)
                                .font(.body)
                            Text(model == nil
                                 ? L10n.text("这里只展示图鉴文案，未连接个人奖励记录，不代表已获得宠物。")
                                 : L10n.text("宠物由奖励引擎自动解锁，本页只读取拥有状态，不提供领取操作。已获得的宠物不会因进度下降而收回。"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(DS.spacing)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(DS.background)
            .foregroundStyle(DS.primary)
            .navigationTitle(Text(verbatim: pet.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityHint(Text("关闭宠物详情"))
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}

#Preview("图鉴 · 浅色") {
    PetCollectionView()
        .preferredColorScheme(.light)
}

#Preview("图鉴 · 深色") {
    PetCollectionView()
        .preferredColorScheme(.dark)
}

#Preview("图鉴 · 辅助功能字号") {
    PetCollectionView()
        .environment(\.dynamicTypeSize, .accessibility3)
}