// File: C:/Users/YSun14/OneDrive - Rockwell Automation, Inc/Desktop/WorkProject/IOS_PayCheck/GoalPet/Core/Nutrition/FoodImageProcessor.swift
// Purpose: Prepare bounded, orientation-corrected JPEG uploads in memory without retaining original images or metadata.
// Dependencies: Foundation, ImageIO, UniformTypeIdentifiers, FoodRecognitionError; iOS 17+, Swift 5.
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PreparedFoodImage: Sendable {
    let jpegData: Data
    let width: Int
    let height: Int

    // Only this file's processor can construct an upload from freshly encoded pixels.
    fileprivate init(jpegData: Data, width: Int, height: Int) throws {
        guard !jpegData.isEmpty, width > 0, height > 0 else {
            throw FoodRecognitionError.invalidImage
        }
        guard jpegData.count <= FoodImageProcessor.maximumUploadBytes,
              width <= FoodImageProcessor.maximumPixelDimension,
              height <= FoodImageProcessor.maximumPixelDimension else {
            throw FoodRecognitionError.imageTooLarge
        }
        self.jpegData = jpegData
        self.width = width
        self.height = height
    }
}

struct FoodImageProcessor: Sendable {
    // Byte limits use binary megabytes (MiB).
    static let maximumSourceBytes = 20 * 1024 * 1024
    static let maximumUploadBytes = 4 * 1024 * 1024
    static let maximumPixelDimension = 1_600
    private static let maximumSourcePixels = 80_000_000

    func prepare(_ source: Data) async throws -> PreparedFoodImage {
        guard !Task.isCancelled else { throw FoodRecognitionError.cancelled }

        let worker = Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                try Self.process(source)
            }
        }

        return try await withTaskCancellationHandler(operation: {
            do {
                let image = try await worker.value
                try Task.checkCancellation()
                return image
            } catch {
                if Task.isCancelled { throw FoodRecognitionError.cancelled }
                throw Self.safe(error)
            }
        }, onCancel: {
            worker.cancel()
        })
    }

    /// Image processing errors must not fall back to the contract's transport error.
    static func safe(_ error: Error) -> FoodRecognitionError {
        if error is CancellationError { return .cancelled }
        if let error = error as? FoodRecognitionError {
            switch error {
            case .invalidImage, .imageTooLarge, .cancelled: return error
            default: return .invalidImage
            }
        }
        return .invalidImage
    }

    private static func process(_ source: Data) throws -> PreparedFoodImage {
        try Task.checkCancellation()
        guard !source.isEmpty else { throw FoodRecognitionError.invalidImage }
        guard source.count <= maximumSourceBytes else {
            throw FoodRecognitionError.imageTooLarge
        }

        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let imageSource = CGImageSourceCreateWithData(source as CFData, sourceOptions as CFDictionary),
              let identifier = CGImageSourceGetType(imageSource),
              let type = UTType(identifier as String),
              [UTType.jpeg, .png, .heic, .heif].contains(where: { type.conforms(to: $0) }),
              CGImageSourceGetCount(imageSource) > 0,
              CGImageSourceGetStatus(imageSource) == .statusComplete else {
            throw FoodRecognitionError.invalidImage
        }
        try Task.checkCancellation()

        // Only the first image/frame is processed. Inspect its header before decoding pixels.
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            imageSource, 0, sourceOptions as CFDictionary
        ) as? [CFString: Any],
              let width = positiveDimension(properties[kCGImagePropertyPixelWidth]),
              let height = positiveDimension(properties[kCGImagePropertyPixelHeight]) else {
            throw FoodRecognitionError.invalidImage
        }
        // Division avoids overflow from an untrusted width * height product.
        guard width <= maximumSourcePixels / height else {
            throw FoodRecognitionError.imageTooLarge
        }
        try Task.checkCancellation()

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            imageSource, 0, thumbnailOptions as CFDictionary
        ) else {
            throw FoodRecognitionError.invalidImage
        }
        try Task.checkCancellation()
        guard image.width > 0, image.height > 0 else {
            throw FoodRecognitionError.invalidImage
        }
        guard image.width <= maximumPixelDimension, image.height <= maximumPixelDimension else {
            throw FoodRecognitionError.imageTooLarge
        }

        // Each attempt has a fresh destination; no source properties, EXIF or GPS are copied.
        for qualityStep in stride(from: 9, through: 1, by: -1) {
            try Task.checkCancellation()
            let data = try autoreleasepool {
                try encodeJPEG(image, quality: Double(qualityStep) / 10)
            }
            try Task.checkCancellation()
            if data.count <= maximumUploadBytes {
                let prepared = try PreparedFoodImage(
                    jpegData: data, width: image.width, height: image.height
                )
                try Task.checkCancellation()
                return prepared
            }
        }
        try Task.checkCancellation()
        throw FoodRecognitionError.imageTooLarge
    }

    private static func positiveDimension(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let dimension = Int(exactly: number.doubleValue), dimension > 0 else {
            return nil
        }
        return dimension
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) throws -> Data {
        try Task.checkCancellation()
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw FoodRecognitionError.invalidImage
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(destination) else {
            throw FoodRecognitionError.invalidImage
        }
        try Task.checkCancellation()
        guard output.length > 0 else { throw FoodRecognitionError.invalidImage }
        return output as Data
    }
}