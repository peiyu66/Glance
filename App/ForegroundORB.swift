import Foundation
@preconcurrency import Vision
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Immutable native descriptors cross queues; all OpenCV calls run serially.
final class ForegroundORBFeatures: @unchecked Sendable {
    let native: GLOpenCVFeatures
    init(native: GLOpenCVFeatures) { self.native = native }
}

enum ForegroundORB {
    enum Failure: Error { case maskUnavailable, maskFormat, encoding }

    /// Same revision, central-instance eligibility and byte conversion as the
    /// frozen MaskProbe. Failure is a cache miss, never a whole-image fallback.
    static func features(_ image: CGImage) throws -> ForegroundORBFeatures {
        let request = VNGenerateForegroundInstanceMaskRequest()
        request.revision = 1
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])
        guard let observation = request.results?.first,
              observation.allInstances.count == 1 else { throw Failure.maskUnavailable }
        let low = observation.instanceMask
        CVPixelBufferLockBaseAddress(low, .readOnly)
        let label: Int
        if CVPixelBufferGetPixelFormatType(low) == kCVPixelFormatType_OneComponent8,
           let address = CVPixelBufferGetBaseAddress(low) {
            label = Int(address.advanced(by: (CVPixelBufferGetHeight(low) / 2) * CVPixelBufferGetBytesPerRow(low) + CVPixelBufferGetWidth(low) / 2).load(as: UInt8.self))
        } else { label = 0 }
        CVPixelBufferUnlockBaseAddress(low, .readOnly)
        guard label > 0, observation.allInstances.contains(label) else { throw Failure.maskUnavailable }
        let mask = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: label), from: handler)
        let bytes = try maskBytes(mask, width: image.width, height: image.height)
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { throw Failure.encoding }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encoding }
        let native = try GLOpenCVBridge.features(png: png as Data, mask: bytes)
        return ForegroundORBFeatures(native: native)
    }

    private static func maskBytes(_ buffer: CVPixelBuffer, width: Int, height: Int) throws -> Data {
        guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float else { throw Failure.maskFormat }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure.maskFormat }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float.self)
            for x in 0..<width {
                guard row[x].isFinite else { throw Failure.maskFormat }
                bytes[y * width + x] = UInt8(max(0, min(255, Int((row[x] * 255).rounded()))))
            }
        }
        return Data(bytes)
    }

    static func matches(_ reference: ForegroundORBFeatures, _ query: ForegroundORBFeatures) -> Bool {
        GLOpenCVBridge.compare(reference.native, query.native)["vote"] as? String == "match"
    }
}

/// A single serial worker also orders reference updates against extraction.
/// Payloads are immutable and never replaced after a request has been sent.
final class FixedForegroundMatcher: @unchecked Sendable {
    struct Reference: Sendable {
        let id: UUID
        let capturedAt: Double
        let features: ForegroundORBFeatures
    }
    struct Observation: Sendable {
        let features: ForegroundORBFeatures?
        let matches: [UUID]
        let evaluated: Set<UUID>
        let milliseconds: Double
    }
    private let queue = DispatchQueue(label: "Glance.fixed-foreground-orb", qos: .userInitiated)
    private var references: [Reference] = []
    func update(_ references: [Reference]) {
        queue.async { self.references = references }
    }
    private func evaluate(_ query: ForegroundORBFeatures?, capturedAt: Double, began: Double) -> Observation {
        let active = references.filter { capturedAt >= $0.capturedAt && capturedAt - $0.capturedAt < 90 }
        let matches = query.map { query in active.filter { ForegroundORB.matches($0.features, query) }.map(\.id) } ?? []
        return Observation(features: query, matches: matches, evaluated: Set(active.map(\.id)), milliseconds: (ProcessInfo.processInfo.systemUptime - began) * 1000)
    }
    /// Explicit offline fixture only. Real ORB with a generated, known foreground mask.
    func synthetic(_ png: Data, mask: Data, capturedAt: Double) throws -> Observation {
        guard ProcessInfo.processInfo.arguments.contains("--camera-orb-fixture") else { throw ForegroundORB.Failure.encoding }
        return try queue.sync {
            let began = ProcessInfo.processInfo.systemUptime
            let query = ForegroundORBFeatures(native: try GLOpenCVBridge.features(png: png, mask: mask))
            return evaluate(query, capturedAt: capturedAt, began: began)
        }
    }
    func prepare(_ image: CGImage, capturedAt: Double) -> Observation {
        queue.sync {
            autoreleasepool {
                let began = ProcessInfo.processInfo.systemUptime
                let query = try? ForegroundORB.features(image)
                return evaluate(query, capturedAt: capturedAt, began: began)
            }
        }
    }
}
