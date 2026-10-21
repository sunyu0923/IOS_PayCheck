// File: C:/Users/YSun14/OneDrive - Rockwell Automation, Inc/Desktop/WorkProject/IOS_PayCheck/GoalPet/Features/Nutrition/FoodDraft.swift
// Purpose: Editable value drafts and explicitly confirmed immutable meals; no persistence side effects.
// Dependencies: FoodRecognitionContract, NumberInput, Foundation.
import Foundation

struct FoodItemValue: Equatable, Sendable {
    let id: UUID
    let name: String
    let cookingMethod: String
    let servingDescription: String
    let weightGrams: Double?
    let calories: Double?
    let calorieRange: CalorieRange?
    let proteinGrams: Double?
    let carbohydrateGrams: Double?
    let fatGrams: Double?
    let isAIRecognized: Bool
}

struct EditableFoodItem: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var cookingMethod: String
    var servingDescription: String
    var weightText: String
    var caloriesText: String
    var lowerCaloriesText: String
    var upperCaloriesText: String
    var proteinText: String
    var carbohydrateText: String
    var fatText: String
    let isAIRecognized: Bool
    let questions: [String]
    let confidence: Double?
    private let original: RecognizedFood?

    init(food: RecognizedFood? = nil, isAIRecognized: Bool = false) {
        id = UUID(); name = food?.name ?? ""; cookingMethod = food?.cookingMethod ?? ""
        servingDescription = food?.servingDescription ?? ""
        weightText = food?.estimatedWeightGrams.map(Self.editingText) ?? ""
        caloriesText = food?.estimatedCalories.map(Self.editingText) ?? ""
        lowerCaloriesText = food?.calorieRange.map { Self.editingText($0.lower) } ?? ""
        upperCaloriesText = food?.calorieRange.map { Self.editingText($0.upper) } ?? ""
        proteinText = food?.proteinGrams.map(Self.editingText) ?? ""
        carbohydrateText = food?.carbohydrateGrams.map(Self.editingText) ?? ""
        fatText = food?.fatGrams.map(Self.editingText) ?? ""
        self.isAIRecognized = isAIRecognized; questions = food?.questions ?? []; confidence = food?.confidence
        original = food
    }

    func validated() throws -> FoodItemValue {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120, cookingMethod.count <= 120,
              servingDescription.count <= 200 else { throw FoodRecognitionError.invalidInput }
        let weight = try Self.number(weightText, original: original?.estimatedWeightGrams)
        if let weight, weight <= 0 { throw FoodRecognitionError.invalidInput }
        let calories = try Self.number(caloriesText, original: original?.estimatedCalories)
        let lower = try Self.number(lowerCaloriesText, original: original?.calorieRange?.lower)
        let upper = try Self.number(upperCaloriesText, original: original?.calorieRange?.upper)
        let range: CalorieRange?
        switch (lower, upper) {
        case (nil, nil): range = nil
        case (.some(let low), .some(let high)):
            guard low <= high else { throw FoodRecognitionError.invalidInput }
            if let calories, !(low...high).contains(calories) { throw FoodRecognitionError.invalidInput }
            range = CalorieRange(lower: low, upper: high)
        default: throw FoodRecognitionError.invalidInput
        }
        // Unknown nutrients remain nil, not fabricated zero. Manual entries may omit calories.
        return FoodItemValue(id: id, name: title, cookingMethod: cookingMethod,
                             servingDescription: servingDescription, weightGrams: weight, calories: calories,
                             calorieRange: range, proteinGrams: try Self.number(proteinText, original: original?.proteinGrams),
                             carbohydrateGrams: try Self.number(carbohydrateText, original: original?.carbohydrateGrams),
                             fatGrams: try Self.number(fatText, original: original?.fatGrams),
                             isAIRecognized: isAIRecognized)
    }

    private static func editingText(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...16)))
    }

    private static func number(_ text: String, original: Double? = nil) throws -> Double? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        do {
            let value: Double
            if let original, text == editingText(original) { value = original }
            else { value = try NumberInput.parse(text) }
            guard value.isFinite, (0...20_000).contains(value) else { throw FoodRecognitionError.invalidInput }
            return value
        } catch { throw FoodRecognitionError.invalidInput }
    }
}

struct ConfirmedFoodMeal: Equatable, Sendable {
    let id: UUID
    let mealType: MealType
    let date: Date
    let source: FoodRecognitionMode
    let foods: [FoodItemValue]

    // Explicit confirmation is a product gate, not a security credential.
    // Only this factory creates a validated immutable snapshot for persistence.
    private init(id: UUID, mealType: MealType, date: Date, source: FoodRecognitionMode, foods: [FoodItemValue]) {
        self.id = id; self.mealType = mealType; self.date = date; self.source = source; self.foods = foods
    }

    static func confirm(id: UUID, mealType: MealType, date: Date, source: FoodRecognitionMode,
                        drafts: [EditableFoodItem], userConfirmed: Bool, now: Date = .now) throws -> Self {
        guard userConfirmed else { throw FoodRecognitionError.consentRequired }
        guard date <= now, !drafts.isEmpty, drafts.count <= FoodRecognitionResponse.maximumFoods,
              Set(drafts.map(\.id)).count == drafts.count else { throw FoodRecognitionError.invalidInput }
        return try Self(id: id, mealType: mealType, date: date, source: source,
                        foods: drafts.map { try $0.validated() })
    }
}