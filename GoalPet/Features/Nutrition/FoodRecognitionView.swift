// File: C:/Users/YSun14/OneDrive - Rockwell Automation, Inc/Desktop/WorkProject/IOS_PayCheck/GoalPet/Features/Nutrition/FoodRecognitionView.swift
// Purpose: Consent-gated photo recognition sheet and explicitly reviewed, editable meal drafts.
// Dependencies: SwiftUI, PhotosUI, UIKit, Foundation; AppViewModel, FoodRecognitionViewModel,
// FoodDraft, FoodRecognitionContract, FoodImageProcessor (through the VM), DS, InlineError,
// InputError, NumberInput, L10n. iOS 17+, Swift 5. No networking or database access in this view.

import SwiftUI
import PhotosUI
import UIKit
import Foundation

@MainActor
struct FoodRecognitionView: View {
    let model: AppViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var recognition: FoodRecognitionViewModel
    @State private var selectedItem: PhotosPickerItem?
    @State private var recognitionTask: Task<Void, Never>?
    @State private var saveError: String?
    @State private var pendingAction: DraftAction?
    @State private var confirmsDiscard = false

    init(model appModel: AppViewModel) {
        model = appModel
        _recognition = State(initialValue: FoodRecognitionViewModel(service: appModel.foodRecognitionService))
    }

    private var isBusy: Bool {
        recognition.isPreparing || recognition.isRecognizing || recognitionTask != nil
    }

    private var needsDiscardConfirmation: Bool {
        !recognition.isSaved && (recognition.hasDraft || selectedItem != nil
            || recognition.imageData != nil || isBusy)
    }

    var body: some View {
        NavigationStack {
            Form {
                if recognition.isSaved {
                    successSection
                } else {
                    serviceSection
                    photoSection
                    entrySection
                    if let error = recognition.error, error != .cancelled {
                        Section {
                            InlineError(message: (error.errorDescription ?? L10n.text("无法完成识别。"))
                                        + "\n" + error.code)
                        }
                    }
                    if let saveError {
                        Section { InlineError(message: saveError) }
                    }
                    if recognition.hasDraft {
                        FoodRecognitionResultView(recognition: recognition, onSave: save)
                            .disabled(isBusy)
                    } else if !isBusy {
                        Section {
                            Text("尚无食物结果。选择照片不会自动上传或保存；也可以直接手动记录或查看 Mock 演示。")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.background)
            .tint(DS.health)
            .navigationTitle(Text("饮食记录"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { request(.close) }
                }
            }
            .interactiveDismissDisabled(needsDiscardConfirmation)
            .confirmationDialog("放弃尚未保存的内容？", isPresented: $confirmsDiscard,
                                titleVisibility: .visible) {
                Button("放弃并继续", role: .destructive) {
                    if let pendingAction { perform(pendingAction) }
                    pendingAction = nil
                }
                Button("继续编辑", role: .cancel) { pendingAction = nil }
            } message: {
                Text("本次照片副本和草稿将从内存移除，图库原图不会删除。取消无法撤回已上传到服务器的数据。")
            }
        }
        .task(id: selectedItem) {
            // Capture the generation BEFORE transfer; cancellation alone cannot prevent stale transfers.
            guard let item = selectedItem, !Task.isCancelled else { return }
            cancelRecognition()
            saveError = nil
            let selectionID = recognition.beginPhotoSelection()
            do {
                guard let photo = try await item.loadTransferable(type: FoodPhotoTransfer.self) else {
                    guard !Task.isCancelled, selectedItem == item else { return }
                    recognition.photoSelectionFailed(selectionID)
                    return
                }
                guard !Task.isCancelled, selectedItem == item else { return }
                await recognition.preparePhoto(photo.data, selectionID: selectionID)
            } catch {
                // Older/cancelled picker tasks must never replace the current selection's status.
                guard !Task.isCancelled, selectedItem == item else { return }
                recognition.photoSelectionFailed(selectionID, cause: error)
            }
        }
        .onDisappear { reset() }
    }

    private var serviceSection: some View {
        Section {
            switch recognition.mode {
            case .mock:
                Label("Mock 演示 · 不上传", systemImage: "externaldrive")
                    .font(.headline)
                    .foregroundStyle(DS.reward)
                Text("当前为离线固定示例，不会分析所选照片，也不会上传。Mock 结果仅留在本次会话内，不进入正式记录、统计或奖励。")
            case .remote:
                Label("Remote 远程识别", systemImage: "network")
                    .font(.headline)
                    .foregroundStyle(DS.health)
                if let notice = recognition.uploadNotice {
                    LabeledContent("处理方", value: notice.processorName)
                    LabeledContent("处理用途", value: notice.purpose)
                    LabeledContent("保留政策", value: notice.retention)
                    Link(destination: notice.privacyPolicyURL) {
                        Label("查看隐私政策", systemImage: "arrow.up.right.square")
                    }
                } else {
                    Text("缺少处理方隐私说明，上传已禁用；仍可使用手动记录或 Mock 演示。")
                }
                Text("仅在你同意并点击确认上传后，才发送本机处理过的 JPEG。取消请求或移除本机照片，不能撤回或删除服务器已收到的数据；服务器处理以保留政策为准。")
            case .manual:
                Label("手动记录 · 不上传", systemImage: "square.and.pencil")
                Text("当前服务不提供照片识别，请新建手动记录。")
            }
        } header: {
            Text("识别服务与隐私")
        } footer: {
            Text("饮食记录不与家庭成员共享。照片只作临时处理，不写入本地饮食数据库；选择照片无需相机权限。")
        }
    }

    private var photoSection: some View {
        @Bindable var recognition = recognition
        return Section {
            PhotosPicker(selection: $selectedItem, matching: .images, preferredItemEncoding: .current) {
                Label("选择一张食物照片", systemImage: "photo")
                    .padding(.vertical, DS.small)
            }
            // Replacing a draft must be explicit. A new selection during preparation is safe.
            .disabled(recognition.hasDraft || recognitionTask != nil || recognition.isRecognizing
                      || recognition.mode == .manual)

            if let data = recognition.imageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: DS.radius))
                    .accessibilityLabel(Text("本机处理后的 JPEG 照片预览"))
                Button("移除内存中的照片", role: .destructive) { removePhoto() }
                    .disabled(isBusy)
            }

            if recognition.isPreparing {
                ProgressView("正在读取并准备照片…")
            } else if recognition.isRecognizing || recognitionTask != nil {
                ProgressView(recognition.mode == .remote ? L10n.text("正在请求远程识别…") : L10n.text("正在加载 Mock 结果…"))
            }
            if isBusy {
                Button("取消处理并清空草稿", role: .destructive) { reset() }
            }

            if !recognition.hasDraft {
                if recognition.mode == .remote {
                    Toggle("我已了解处理方、用途和保留政策，同意本次照片上传", isOn: $recognition.uploadConsent)
                        .disabled(!recognition.canRecognize || recognition.uploadNotice == nil || isBusy)
                    Button("确认上传并识别") { recognize() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!recognition.canRecognize || !recognition.uploadConsent
                                  || recognition.uploadNotice == nil || isBusy)
                } else if recognition.mode == .mock {
                    Button("使用照片流程查看 Mock 结果（不上传）") { recognize() }
                        .disabled(!recognition.canRecognize || isBusy)
                }
            }
        } header: {
            Text("照片（可选）")
        } footer: {
            Text("预览是缩小、重新编码并移除源元数据的 JPEG。移除仅清理本次内存副本，图库原图不会删除。已有草稿时，请先清空再选择新照片。")
        }
    }

    private var entrySection: some View {
        Section {
            Button("新建空白手动记录") { request(.manual) }
            Button("查看 Mock 示例（无需照片）") { request(.mock) }
            if needsDiscardConfirmation {
                Button("清空并重新开始", role: .destructive) { request(.reset) }
            }
        } footer: {
            Text("手动记录总是从空白开始，不会把已填充的 Mock 结果转换为正式记录。未点击确认保存前，所有编辑都只是草稿。")
        }
    }

    private var successSection: some View {
        Section {
            Label(recognition.source == .mock ? L10n.text("Mock 演示已确认") : L10n.text("饮食记录已保存"),
                  systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(DS.health)
            if recognition.source == .mock {
                Text("仅保留在本次会话内，关闭后清除；未写入正式饮食记录，也不计入统计或奖励。")
            } else {
                Text("已保存你确认的食物与估算值。照片副本已移除，记录不与家庭成员共享。")
            }
            Button("关闭") { perform(.close) }
                .buttonStyle(.borderedProminent)
        }
    }

    private func recognize() {
        guard recognitionTask == nil, recognition.canRecognize else { return }
        saveError = nil
        recognitionTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            await recognition.recognize()
            guard !Task.isCancelled else { return }
            recognitionTask = nil
        }
    }

    private func cancelRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func reset() {
        cancelRecognition()
        selectedItem = nil
        recognition.reset() // Invalidates outstanding transfer/processing/service generations.
        saveError = nil
    }

    private func removePhoto() {
        guard !isBusy else { return }
        selectedItem = nil
        recognition.discardPhoto() // Preserve any reviewed food draft, but revoke upload consent.
    }

    private func request(_ action: DraftAction) {
        if needsDiscardConfirmation {
            pendingAction = action
            confirmsDiscard = true
        } else {
            perform(action)
        }
    }

    private func perform(_ action: DraftAction) {
        reset()
        switch action {
        case .close: dismiss()
        case .manual: recognition.startManual()
        case .mock: recognition.loadMockExample()
        case .reset: break
        }
    }

    private func save() {
        guard recognition.canConfirm, !isBusy else { return }
        saveError = nil
        do {
            // This is the ONLY confirmation/persistence path, invoked by the explicit save button.
            let meal = try recognition.confirmedMeal()
            if meal.source != .mock { try model.saveConfirmedMeal(meal) }
            recognition.markSaved(meal)
            selectedItem = nil
        } catch let error as InputError {
            saveError = error.errorDescription ?? L10n.text("暂时无法保存，请保留输入并重试。")
        } catch let error as FoodRecognitionError {
            saveError = (error.errorDescription ?? L10n.text("请检查输入后重试。")) + "\n" + error.code
        } catch {
            saveError = L10n.text("暂时无法保存，草稿已保留，请重试。错误码：STORE_WRITE")
        }
        // Never report local validation/storage failures through the VM's transport-error mapper.
    }

    private enum DraftAction { case close, manual, mock, reset }
}

/// Form sections, composed inside FoodRecognitionView's single Form (not a nested scrolling form).
@MainActor
struct FoodRecognitionResultView: View {
    @Bindable var recognition: FoodRecognitionViewModel
    let onSave: () -> Void

    var body: some View {
        Group {
            Section {
                Text(verbatim: sourceTitle)
                    .font(.headline)
                    .foregroundStyle(DS.health)
                Picker("餐别", selection: $recognition.mealType) {
                    ForEach(MealType.allCases) { type in
                        Text(verbatim: type.title).tag(type)
                    }
                }
                DatePicker("用餐时间", selection: $recognition.date, in: ...Date.now,
                           displayedComponents: [.date, .hourAndMinute])
            } header: { Text("待确认的餐食") }

            ForEach($recognition.items) { $item in
                foodSection($item)
            }

            Section {
                if recognition.items.isEmpty {
                    Text("没有可保存的食物，请手动添加。缺失数据不代表零。")
                        .foregroundStyle(.secondary)
                }
                Button { recognition.addItem() } label: {
                    Label("添加食物", systemImage: "plus")
                }
                .disabled(recognition.items.count >= FoodRecognitionResponse.maximumFoods || recognition.isSaved)
                Text(verbatim: L10n.text("食物数量") + "：\(recognition.items.count)/\(FoodRecognitionResponse.maximumFoods)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } footer: {
                Text("每餐最多 30 项。留空表示未知，不会填为零或以范围中点代替。重量若填写必须大于零；数值最多 20,000。")
            }

            Section {
                // Static app-owned guidance; never trust/render a provider-supplied diagnostic disclaimer.
                Text("照片无法准确判断重量、食材和用油量。所有热量与营养值均为估算，仅供一般记录参考，不是诊断、饮食处方或摄入目标；个体建议请咨询合格专业人员。")
                    .foregroundStyle(.secondary)
                Toggle("我已核对食物、分量及估算值，并确认保存这些内容", isOn: $recognition.hasReviewed)
                Text("修改任何食物、餐别或时间后，需要重新勾选确认。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(recognition.source == .mock ? L10n.text("确认 Mock 结果（仅本次会话）") : L10n.text("确认并保存记录")) {
                    onSave()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!recognition.canConfirm)
            } header: { Text("人工核对（必选）") }
        }
        .disabled(recognition.isSaved || recognition.isPreparing || recognition.isRecognizing)
    }

    private var sourceTitle: String {
        switch recognition.source {
        case .mock: return L10n.text("Mock 固定演示 · 不写入正式记录")
        case .remote: return L10n.text("Remote 识别草稿 · 需要人工核对")
        case .manual: return L10n.text("手动记录草稿")
        }
    }

    private func foodSection(_ item: Binding<EditableFoodItem>) -> some View {
        Section {
            TextField("食物名称（必填，最多 120 字）", text: item.name)
            TextField("烹饪方式（可选，最多 120 字）", text: item.cookingMethod)
            TextField("分量描述（可选，最多 200 字）", text: item.servingDescription, axis: .vertical)
            numberField("估算重量（g）", text: item.weightText)
            numberField("热量点估值（kcal）", text: item.caloriesText)
            numberField("热量估算下限（kcal，可选）", text: item.lowerCaloriesText)
            numberField("热量估算上限（kcal，可选）", text: item.upperCaloriesText)
            Text("上下限可同时留空；填写范围时需同时提供两端，点估值若填写需在范围内。范围不是置信区间。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            numberField("估算蛋白质（g）", text: item.proteinText)
            numberField("估算碳水化合物（g）", text: item.carbohydrateText)
            numberField("估算脂肪（g）", text: item.fatText)
            if let confidence = item.wrappedValue.confidence {
                Text(verbatim: L10n.text("原始置信度分值") + "：" + NumberInput.format(confidence)
                     + " · " + L10n.text("未校准（not calibrated），不代表准确率"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("置信度：未提供；不是已验证的准确率。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !item.wrappedValue.questions.isEmpty {
                Text("需要确认的问题")
                    .font(.subheadline.bold())
                ForEach(Array(item.wrappedValue.questions.enumerated()), id: \.offset) { question in
                    Text(verbatim: question.element)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("删除此食物", role: .destructive) {
                recognition.removeItem(id: item.wrappedValue.id)
            }
        } header: { Text("食物与估算值") }
    }

    private func numberField(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        LabeledContent {
            TextField("未知", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(Text(title))
        } label: { Text(title) }
    }
}

#Preview("饮食记录 · Mock") {
    PreviewHost { FoodRecognitionView(model: $0) }
}