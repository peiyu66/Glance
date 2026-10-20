import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Only receives the one item returned by the system picker. Never opens a library.
enum SelectedPhoto {
    enum Failure: Error { case unsupportedOrTooLarge }
    /// Preserve the entire image/aspect ratio, apply orientation, strip metadata, and
    /// create the single JPEG shared by preview, archive, barcode scan and request.
    nonisolated static func jpeg(from data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= 40 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 100_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 768
              ] as CFDictionary) else { throw Failure.unsupportedOrTooLarge }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.unsupportedOrTooLarge
        }
        CGImageDestinationAddImage(destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { throw Failure.unsupportedOrTooLarge }
        return output as Data
    }
}
