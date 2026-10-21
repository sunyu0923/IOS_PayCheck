// File: C:/Users/YSun14/OneDrive - Rockwell Automation, Inc/Desktop/WorkProject/IOS_PayCheck/GoalPet/Features/Nutrition/FoodRecognitionViewModel.swift
// Purpose: Ephemeral photo/draft workflow. Upload consent and review are separate, resettable gates.
// Dependencies: FoodRecognitionService, FoodImageProcessor, FoodDraft, Observation. No database access.
import Foundation
import Observation

@MainActor @Observable final class FoodRecognitionViewModel {
    @ObservationIgnored private let service: any FoodRecognitionService
    @ObservationIgnored private let processor = FoodImageProcessor()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var image: PreparedFoodImage?

    private(set) var imageData: Data?
    private(set) var isPreparing = false
    private(set) var isRecognizing = false
    private(set) var error: FoodRecognitionError?
    private(set) var source = FoodRecognitionMode.manual
    private(set) var hasDraft = false
    private(set) var isSaved = false
    private(set) var demoResult: ConfirmedFoodMeal?
    private(set) var draftID = UUID()
    var hasReviewed = false
    var uploadConsent = false
    var items: [EditableFoodItem] = [] { didSet { hasReviewed = false } }
    var mealType = MealType.lunch { didSet { hasReviewed = false } }
    var date = Date.now { didSet { hasReviewed = false } }

    init(service: any FoodRecognitionService) { self.service = service }
    var mode: FoodRecognitionMode { service.mode }
    var uploadNotice: FoodUploadNotice? { service.uploadNotice }
    var canRecognize: Bool { image != nil && !isPreparing && !isRecognizing && !isSaved }
    var canConfirm: Bool { hasDraft && !items.isEmpty && hasReviewed && !isPreparing && !isRecognizing && !isSaved }

    // Call before PhotosPicker transfer so an older transfer cannot replace a new selection.
    func beginPhotoSelection() -> UUID {
        reset(); isPreparing = true
        return generation
    }
    func preparePhoto(_ data: Data, selectionID: UUID) async {
        guard selectionID == generation else { return }
        do {
            let prepared = try await processor.prepare(data)
            guard selectionID == generation, !Task.isCancelled else { return }
            image = prepared; imageData = prepared.jpegData; isPreparing = false
        } catch {
            guard selectionID == generation else { return }
            self.error = FoodImageProcessor.safe(error); isPreparing = false
        }
    }
    func photoSelectionFailed(_ selectionID: UUID, cause: Error? = nil) {
        guard selectionID == generation else { return }
        error = cause.map(FoodImageProcessor.safe) ?? .invalidImage; isPreparing = false
    }

    func recognize() async {
        guard canRecognize, let image else { return }
        if mode == .remote && (!uploadConsent || uploadNotice == nil) {
            error = .consentRequired; return
        }
        let operation = generation
        isRecognizing = true; error = nil; hasDraft = false; items = []
        defer {
            if operation == generation { isRecognizing = false; uploadConsent = false }
        }
        do {
            let result = try await service.recognize(image: image, requestID: requestID)
            try Task.checkCancellation()
            guard operation == generation else { return }
            try result.validate()
            source = mode; mealType = result.mealType
            items = result.foods.map { EditableFoodItem(food: $0, isAIRecognized: mode == .remote) }
            hasDraft = true
        } catch {
            guard operation == generation else { return }
            self.error = FoodRecognitionError.safe(error)
        }
    }

    func startManual() {
        reset(); source = .manual; items = [EditableFoodItem()]; hasDraft = true
    }
    func loadMockExample() {
        reset()
        do {
            let result = try FoodRecognitionResponse.decode(Data(MockFoodRecognitionService.sampleJSON.utf8))
            source = .mock; mealType = result.mealType; items = result.foods.map { EditableFoodItem(food: $0) }
            hasDraft = true
        } catch { self.error = FoodRecognitionError.safe(error) }
    }
    func addItem() {
        guard items.count < FoodRecognitionResponse.maximumFoods, !isSaved else { return }
        items.append(EditableFoodItem())
    }
    func removeItem(id: UUID) { if !isSaved { items.removeAll { $0.id == id } } }
    func discardPhoto() { image = nil; imageData = nil; uploadConsent = false }

    func confirmedMeal() throws -> ConfirmedFoodMeal {
        guard canConfirm else { throw FoodRecognitionError.invalidInput }
        return try ConfirmedFoodMeal.confirm(id: draftID, mealType: mealType, date: date,
                                            source: source, drafts: items, userConfirmed: hasReviewed)
    }
    func markSaved(_ meal: ConfirmedFoodMeal) {
        if meal.source == .mock { demoResult = meal } // Memory only; no formal totals/rewards.
        isSaved = true; discardPhoto()
    }
    func report(_ error: Error) { self.error = FoodRecognitionError.safe(error) }

    func reset() {
        generation = UUID(); requestID = UUID(); draftID = UUID()
        image = nil; imageData = nil; isPreparing = false; isRecognizing = false
        error = nil; items = []; source = .manual; hasDraft = false
        isSaved = false; demoResult = nil; hasReviewed = false; uploadConsent = false; date = .now
    }
}