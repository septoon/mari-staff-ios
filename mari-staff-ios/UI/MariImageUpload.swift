import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

struct MariPreparedUploadImage {
    let data: Data
    let fileName: String
    let mimeType: String
    let previewImage: UIImage
}

enum MariImagePreparationError: LocalizedError {
    case unsupportedType
    case fileTooLarge
    case unreadableImage
    case webpEncodingFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedType:
            "Поддерживаются только изображения"
        case .fileTooLarge:
            "Размер файла должен быть не больше 12 МБ"
        case .unreadableImage:
            "Не удалось прочитать изображение"
        case .webpEncodingFailed:
            "Не удалось сконвертировать изображение в WEBP"
        }
    }
}

enum MariImagePreparation {
    private static let maxInputBytes = 12 * 1024 * 1024
    private static let maxDimension: CGFloat = 2200
    private static let compressionQuality: CGFloat = 0.9

    static func prepareWebPImage(
        from rawData: Data,
        suggestedBaseName: String
    ) throws -> MariPreparedUploadImage {
        guard rawData.count <= maxInputBytes else {
            throw MariImagePreparationError.fileTooLarge
        }

        guard let sourceImage = UIImage(data: rawData), sourceImage.size.width > 0, sourceImage.size.height > 0 else {
            throw MariImagePreparationError.unsupportedType
        }

        let normalizedImage = resizedImage(from: sourceImage)
        guard let cgImage = normalizedImage.cgImage else {
            throw MariImagePreparationError.unreadableImage
        }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded,
            UTType.webP.identifier as CFString,
            1,
            nil
        ) else {
            throw MariImagePreparationError.webpEncodingFailed
        }

        let properties = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality,
        ] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, properties)

        guard CGImageDestinationFinalize(destination) else {
            throw MariImagePreparationError.webpEncodingFailed
        }

        return MariPreparedUploadImage(
            data: encoded as Data,
            fileName: "\(sanitizeBaseName(suggestedBaseName)).webp",
            mimeType: "image/webp",
            previewImage: normalizedImage
        )
    }

    private static func resizedImage(from image: UIImage) -> UIImage {
        let sourceSize = image.size
        let scale = min(1, maxDimension / max(sourceSize.width, sourceSize.height))
        let targetSize = CGSize(
            width: max(1, round(sourceSize.width * scale)),
            height: max(1, round(sourceSize.height * scale))
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private static func sanitizeBaseName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "image" : collapsed.lowercased()
    }
}
