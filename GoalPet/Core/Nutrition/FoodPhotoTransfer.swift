// File: C:/Users/YSun14/OneDrive - Rockwell Automation, Inc/Desktop/WorkProject/IOS_PayCheck/GoalPet/Core/Nutrition/FoodPhotoTransfer.swift
// Purpose: Bound PhotosPicker file reads BEFORE allocating an entire original photo.
// Dependencies: Foundation, CoreTransferable, UniformTypeIdentifiers, FoodImageProcessor.
import Foundation
import CoreTransferable
import UniformTypeIdentifiers

struct FoodPhotoTransfer: Transferable, Sendable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            // The provider URL is valid only inside this closure. Never retain or copy it.
            FoodPhotoTransfer(data: try readBounded(from: received.file))
        }
    }

    static func readBounded(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        let limit = FoodImageProcessor.maximumSourceBytes
        while true {
            try Task.checkCancellation()
            let remaining = limit + 1 - data.count
            guard remaining > 0 else { throw FoodRecognitionError.imageTooLarge }
            let chunk = try handle.read(upToCount: min(128 * 1024, remaining)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            guard data.count <= limit else { throw FoodRecognitionError.imageTooLarge }
        }
        guard !data.isEmpty else { throw FoodRecognitionError.invalidImage }
        return data
    }
}