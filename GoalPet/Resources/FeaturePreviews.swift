// File: c:\Users\YSun14\OneDrive - Rockwell Automation, Inc\Desktop\WorkProject\IOS_PayCheck\GoalPet\Resources\FeaturePreviews.swift
// Purpose: Isolated feature previews, including dark-mode accessibility Dynamic Type coverage.
// Dependencies: SwiftUI, PreviewHost, FinanceView, SavingsGoalView, HealthDashboardView, FamilyView.

import SwiftUI

#Preview("Finance") {
    PreviewHost { model in
        NavigationStack { FinanceView(model: model) }
    }
}

#Preview("Savings") {
    PreviewHost { model in
        NavigationStack { SavingsGoalView(model: model) }
    }
}

#Preview("Health") {
    PreviewHost { model in
        NavigationStack { HealthDashboardView(model: model) }
    }
}

#Preview("Family") {
    PreviewHost { model in
        NavigationStack { FamilyView(model: model) }
    }
}

#Preview("Health · Dark · Accessibility") {
    PreviewHost { model in
        NavigationStack { HealthDashboardView(model: model) }
    }
    .preferredColorScheme(.dark)
    .environment(\.dynamicTypeSize, .accessibility3)
}