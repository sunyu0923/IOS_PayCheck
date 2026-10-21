// File: C:/Users/YSun14/OneDrive - Rockwell Automation, Inc/Desktop/WorkProject/IOS_PayCheck/GoalPet/Models/FoodModels.swift
// Purpose: Confirmed meals and cascade-owned food items. Images never enter this database.
// Dependencies: SwiftData, Foundation, FoodDraft values.
import Foundation
import SwiftData

@Model final class FoodRecord {
    @Attribute(.unique) var id: UUID
    var mealTypeRaw: String
    var recordDate: Date
    var confirmedAt: Date
    var sourceRaw: String
    @Relationship(deleteRule: .cascade, inverse: \FoodItem.record)
    var items: [FoodItem] = []

    init(meal: ConfirmedFoodMeal, confirmedAt: Date) {
        id = meal.id; mealTypeRaw = meal.mealType.rawValue; recordDate = meal.date
        self.confirmedAt = confirmedAt; sourceRaw = meal.source.rawValue
    }

    var knownCalories: Double { items.compactMap(\.calories).reduce(0, +) }
    var hasIncompleteCalories: Bool { items.contains { $0.calories == nil } }
}

@Model final class FoodItem {
    @Attribute(.unique) var id: UUID
    var record: FoodRecord?
    var name: String
    var cookingMethod: String
    var servingDescription: String
    var weightGrams: Double?
    var calories: Double?
    var calorieLower: Double?
    var calorieUpper: Double?
    var proteinGrams: Double?
    var carbohydrateGrams: Double?
    var fatGrams: Double?
    var isAIRecognized: Bool

    init(value: FoodItemValue) {
        id = value.id; name = value.name; cookingMethod = value.cookingMethod
        servingDescription = value.servingDescription; weightGrams = value.weightGrams
        calories = value.calories; calorieLower = value.calorieRange?.lower; calorieUpper = value.calorieRange?.upper
        proteinGrams = value.proteinGrams; carbohydrateGrams = value.carbohydrateGrams
        fatGrams = value.fatGrams; isAIRecognized = value.isAIRecognized
    }
}