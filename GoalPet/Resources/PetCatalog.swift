// File: c:\Users\YSun14\OneDrive - Rockwell Automation, Inc\Desktop\WorkProject\IOS_PayCheck\GoalPet\Resources\PetCatalog.swift
// Purpose: Three original pet presentation definitions and asset-free, crisp pixel illustrations.
// Dependencies: SwiftUI; DS and L10n from Core/DesignSystem.swift. iOS 17+, Swift 5.

import SwiftUI

struct PetDefinition: Identifiable {
    let id: String
    let name: String
    let story: String
    let unlockHint: String
    let palette: Color
}

enum PetCatalog {
    // Presentation only: unlock hints describe RewardEngine's policy but never enforce it.
    // Ownership comes from AppViewModel, not these hints. Stable species IDs also identify pixel art.
    static let all: [PetDefinition] = [
        PetDefinition(
            id: "cat",
            name: L10n.text("杏灯猫"),
            story: L10n.text("杏灯猫把窗边的暖光收进尾巴。每当你认真完成一件小事，它就为这一天点亮一盏想象中的灯。"),
            unlockHint: L10n.text("累计获得 20 XP 后自动解锁杏灯猫。拥有状态以本机奖励记录为准。"),
            palette: DS.reward
        ),
        PetDefinition(
            id: "whale",
            name: L10n.text("潮芽鲸"),
            story: L10n.text("潮芽鲸在安静的海湾收藏水滴。它相信，慢慢积攒的微小努力，也能汇成一片属于自己的海。"),
            unlockHint: L10n.text("累计获得 100 XP 后自动解锁潮芽鲸。拥有状态以本机奖励记录为准。"),
            palette: DS.finance
        ),
        PetDefinition(
            id: "bird",
            name: L10n.text("蓝邮鸟"),
            story: L10n.text("蓝邮鸟用一枚蓝色羽毛记录沿途的风景。它不催促远行，只提醒你在忙碌之间，给自己一次轻松的舒展。"),
            unlockHint: L10n.text("累计获得 250 XP 后自动解锁蓝邮鸟。拥有状态以本机奖励记录为准。"),
            palette: DS.health
        )
    ]
}

struct PixelPetView: View {
    let speciesID: String
    @Environment(\.displayScale) private var displayScale

    init(speciesID: String) {
        self.speciesID = speciesID
    }

    var body: some View {
        Canvas { context, size in
            let grid = sprite
            let columns = grid.map(\.count).max() ?? 16
            let scale = max(displayScale, 1)
            // Integral physical-pixel cells and origins prevent soft edges at 2x/3x scales.
            let cell = (min(size.width / CGFloat(columns), size.height / CGFloat(grid.count)) * scale).rounded(.down) / scale
            guard cell > 0 else { return }
            let originX = ((size.width - CGFloat(columns) * cell) * scale / 2).rounded(.down) / scale
            let originY = ((size.height - CGFloat(grid.count) * cell) * scale / 2).rounded(.down) / scale

            for (row, line) in grid.enumerated() {
                for (column, symbol) in line.enumerated() {
                    guard let color = color(for: symbol) else { continue }
                    let rect = CGRect(
                        x: originX + CGFloat(column) * cell,
                        y: originY + CGFloat(row) * cell,
                        width: cell,
                        height: cell
                    )
                    context.fill(Path(rect), with: .color(color), style: FillStyle(antialiased: false))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityDescription))
        .accessibilityAddTraits(.isImage)
    }

    private var accessibilityDescription: String {
        switch speciesID {
        case "cat": return L10n.text("杏灯猫，杏色尖耳、卷尾巴的原创像素猫")
        case "whale": return L10n.text("潮芽鲸，青绿色圆身体、喷水和翘尾巴的原创像素鲸")
        case "bird": return L10n.text("蓝邮鸟，蓝色翅膀、金色鸟喙和细脚的原创像素鸟")
        default: return L10n.text("未知宠物，像素问号占位图")
        }
    }

    // Original 16 × 16 grids: transparent dots, body B, highlight H, ink E, accent A.
    private var sprite: [String] {
        switch speciesID {
        case "cat":
            return [
                "................",
                "..BB......BB....",
                "..BAB....BAB....",
                "..BBBBBBBBBB....",
                "..BBBBBBBBBB....",
                "..BBEBBBBEBB....",
                "..BBHHAAHHBB....",
                "...BHHHHHHB.....",
                "....BBBBBB...BB.",
                "...BBBBBBBB..BB.",
                "...BBHHHHBB..BB.",
                "...BBHHHHBBBBBB.",
                "...BBHHHHBBBBB..",
                "...BBBBBBBB.....",
                "...BBB..BBB.....",
                "................"
            ]
        case "whale":
            return [
                "................",
                ".....AA.AA......",
                "......AAA.......",
                ".......A........",
                "....BBBBBBB.....",
                "..BBBBBBBBBBB...",
                ".BBBBBBBBBBBBB..",
                ".BBBBBBBBBBBBB..",
                ".BBBEBBBBBBBBB..",
                ".BBBBBBBBBBBBB.B",
                ".BBBBBBBBBBBBBBB",
                "..BHHHHHHHHBBBBB",
                "...HHHHHHHHBBB..",
                "....BBBBBBB.....",
                "......BBB.......",
                "................"
            ]
        case "bird":
            return [
                "................",
                ".......AA.......",
                "......BBBB......",
                ".....BBBBBB.....",
                ".....BBBEBBAA...",
                ".....BBBBBAAAA..",
                ".....BHHHBB.....",
                "....BBHHHHBB....",
                "...BBBBHHHBB....",
                "..BBBBBBHHBB....",
                ".BBBBABBHHBB....",
                "..BBBAAHHBB.....",
                "....BBBBBB......",
                ".....A..A.......",
                "....AA..AA......",
                "................"
            ]
        default:
            return [
                "................",
                "................",
                ".....BBBBBB.....",
                "....BB....BB....",
                "..........BB....",
                ".........BB.....",
                "........BB......",
                ".......BB.......",
                ".......BB.......",
                "................",
                ".......BB.......",
                ".......BB.......",
                "................",
                "................",
                "................",
                "................"
            ]
        }
    }

    private func color(for symbol: Character) -> Color? {
        switch symbol {
        case "B":
            switch speciesID {
            case "cat": return Color(red: 0.91, green: 0.58, blue: 0.29)
            case "whale": return Color(red: 0.18, green: 0.67, blue: 0.62)
            case "bird": return Color(red: 0.34, green: 0.58, blue: 0.88)
            default: return DS.primary
            }
        case "H": return Color(red: 1, green: 0.94, blue: 0.79)
        case "E": return Color(red: 0.10, green: 0.15, blue: 0.22)
        case "A":
            return speciesID == "whale"
                ? Color(red: 0.40, green: 0.76, blue: 0.93)
                : Color(red: 0.97, green: 0.70, blue: 0.39)
        default: return nil
        }
    }
}