// File: c:\Users\YSun14\OneDrive - Rockwell Automation, Inc\Desktop\WorkProject\IOS_PayCheck\GoalPet\Core\DesignSystem.swift
// Purpose: Shared adaptive colors, accessible cards, Chinese-source localization, and theme selection.
// Dependencies: SwiftUI, UIKit, Foundation; iOS 17+, Swift 5. No external dependencies.

import Foundation
import SwiftUI
import UIKit

enum DS {
    static let spacing: CGFloat = 16
    static let small: CGFloat = 8
    static let radius: CGFloat = 22

    static var background: Color { Color(uiColor: .systemGroupedBackground) }
    static var surface: Color { Color(uiColor: .secondarySystemGroupedBackground) }
    static var primary: Color { Color(uiColor: .label) }
    static var accent: Color { adaptive(light: 0x405BCC, dark: 0xA8B8FF) }

    static var finance: Color {
        adaptive(light: 0x146B63, dark: 0x7BDFCB)
    }

    static var health: Color {
        adaptive(light: 0xA93249, dark: 0xFFB4BD)
    }

    static var reward: Color {
        adaptive(light: 0x775600, dark: 0xF5D580)
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

struct GPCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(DS.spacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radius))
            .overlay {
                RoundedRectangle(cornerRadius: DS.radius)
                    .strokeBorder(Color(uiColor: .separator).opacity(0.3), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

struct MetricCard: View {
    private let title: LocalizedStringKey
    private let value: String
    private let systemImage: String
    private let tint: Color

    init(title: LocalizedStringKey, value: String, systemImage: String, tint: Color) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        GPCard {
            VStack(alignment: .leading, spacing: DS.small) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(verbatim: value)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(DS.primary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct InlineError: View {
    private let message: String

    init(message: String) {
        self.message = message
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.small) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color(uiColor: .systemRed))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.small / 2) {
                Text("提示")
                    .font(.headline)
                Text(verbatim: message)
                    .font(.body)
            }
            .foregroundStyle(DS.primary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radius))
        .accessibilityElement(children: .combine)
    }
}

enum L10n {
    // Chinese source strings remain readable without a localization resource.
    static func text(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L10n.text("跟随系统")
        case .light: return L10n.text("浅色")
        case .dark: return L10n.text("深色")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

#Preview("设计卡片") {
    ScrollView {
        VStack(spacing: DS.spacing) {
            GPCard {
                VStack(alignment: .leading, spacing: DS.small) {
                    Text("每一小步，都值得珍藏")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text("卡片样式演示，非真实账户数据。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            MetricCard(title: "演示目标", value: "3", systemImage: "flag.fill", tint: DS.finance)
            InlineError(message: L10n.text("这是一条提示样式示例。"))
        }
        .padding(DS.spacing)
    }
    .background(DS.background)
}