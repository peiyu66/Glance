import SwiftUI
@preconcurrency import AVFoundation
@preconcurrency import Vision
import CoreImage
import CryptoKit

/// Immutable sample crosses the serial capture queue to the UI actor. Never stored on disk.
final class CameraFrame: @unchecked Sendable {
    let image: CGImage
    let fingerprint: SceneFingerprint
    let feature: VNFeaturePrintObservation?
    let labelSignature: String
    let time: TimeInterval
    init(image: CGImage, fingerprint: SceneFingerprint, feature: VNFeaturePrintObservation?, labelSignature: String = "", time: TimeInterval) {
        self.image = image; self.fingerprint = fingerprint; self.feature = feature; self.labelSignature = labelSignature; self.time = time
    }
}

struct CaptureStatistics: Sendable {
    var contrast: Float = 0; var edgeScore: Float = 0; var localProcessingMS: Double = 0
    var frames = 0; var samples = 0; var qualityRejected = 0; var saliencyRejected = 0; var visionRejected = 0; var accepted = 0
}

final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "Glance.camera", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var configured = false
    private var lastSample = 0.0
    private var generation = UUID()
    private var stats = CaptureStatistics()
    var onFrame: (@Sendable (CameraFrame?, UUID, CaptureStatistics) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?
    func start(generation: UUID) {
        queue.async { [self] in
            self.generation = generation; stats = CaptureStatistics()
            do {
                if !configured {
                    session.beginConfiguration(); defer { session.commitConfiguration() }
                    session.sessionPreset = .hd1920x1080
                    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw SIWCError.invalidResponse }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else { throw SIWCError.invalidResponse }; session.addInput(input)
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    output.setSampleBufferDelegate(self, queue: queue)
                    guard session.canAddOutput(output) else { throw SIWCError.invalidResponse }; session.addOutput(output)
                    if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
                    configured = true
                }
                if !session.isRunning { session.startRunning() }
            } catch { onFailure?("camera-configuration") }
        }
    }
    func stop() { queue.async { [self] in if session.isRunning { session.stopRunning() }; lastSample = 0 } }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        stats.frames += 1
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSample >= 0.25 else { return }; lastSample = now; stats.samples += 1
        autoreleasepool {
            guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { onFrame?(nil, generation, stats); return }
            let ci = CIImage(cvPixelBuffer: pixel); let extent = ci.extent
            let side = min(extent.width, extent.height) * 0.78
            let crop = CGRect(x: extent.midX - side / 2, y: extent.midY - side / 2, width: side, height: side)
            let square = ci.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            let scale = min(1, 768 / side)
            let reduced = square.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let image = context.createCGImage(reduced, from: reduced.extent), let fp = Self.fingerprint(image), let qualitySample = Self.fingerprint(image, side: 128) else { stats.qualityRejected += 1; onFrame?(nil, generation, stats); return }
            let quality = SceneQuality(qualitySample); stats.contrast = quality.contrast; stats.edgeScore = quality.edgeScore
            guard quality.usable else { stats.qualityRejected += 1; onFrame?(nil, generation, stats); return }
            do {
                let feature = VNGenerateImageFeaturePrintRequest()
                let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
                try VNImageRequestHandler(cgImage: image, orientation: .up).perform([feature, saliency])
                let boxes = saliency.results?.first?.salientObjects ?? []
                let hasCenterObject = boxes.contains { $0.boundingBox.contains(CGPoint(x: 0.5, y: 0.5)) && $0.boundingBox.width * $0.boundingBox.height >= 0.04 }
                guard hasCenterObject, let print = feature.results?.first as? VNFeaturePrintObservation else { stats.saliencyRejected += 1; onFrame?(nil, generation, stats); return }
                let label = try Self.labelSignature(image)
                stats.localProcessingMS = (ProcessInfo.processInfo.systemUptime-now)*1000
                stats.accepted += 1
                onFrame?(CameraFrame(image: image, fingerprint: fp, feature: print, labelSignature: label, time: now), generation, stats)
            } catch { stats.visionRejected += 1; onFrame?(nil, generation, stats); onFailure?("local-vision") }
        }
    }
    struct LabelReading {
        let signature: String
        let candidateCount: Int
        let maximumConfidence: Float
        let processingMS: Double
    }
    /// Return only a digest and safe counts. Ordinary OCR text never leaves this scope.
    static func labelReading(_ image: CGImage, minimumHeight: Float? = nil, minimumConfidence: Float = 0.5) throws -> LabelReading {
        let start = ProcessInfo.processInfo.systemUptime
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hant", "en-US"]
        request.usesLanguageCorrection = false
        // Use the same default-resolution configuration as the real-device probe.
        // The fixture compares the previous height and confidence settings separately.
        if let minimumHeight { request.minimumTextHeight = minimumHeight }
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        let candidates = (request.results ?? []).compactMap { $0.topCandidates(1).first }
        let lines = LabelEvidence.normalizedLines(candidates.map { ($0.string,$0.confidence) }, minimumConfidence: minimumConfidence)
        return LabelReading(signature: labelDigest(lines), candidateCount: candidates.count,
                            maximumConfidence: candidates.map(\.confidence).max() ?? 0,
                            processingMS: (ProcessInfo.processInfo.systemUptime-start)*1000)
    }
    static func labelSignature(_ image: CGImage) throws -> String { try labelReading(image).signature }
    static func labelDigest(_ lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func fingerprint(_ image: CGImage, side: Int = 32) -> SceneFingerprint? {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { pointer -> Bool in
            guard let context = CGContext(data: pointer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium; context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side)); return true
        }
        guard drawn else { return nil }
        var values: [Float] = []; values.reserveCapacity(side * side * 3)
        for i in stride(from: 0, to: bytes.count, by: 4) { values.append(contentsOf: bytes[i..<(i+3)].map { Float($0) / 255 }) }
        return SceneFingerprint(rgb: values, side: side)
    }

}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    final class Preview: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override func layoutSubviews() {
            super.layoutSubviews()
            if let c = preview.connection, c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        }
    }
    func makeUIView(context: Context) -> Preview { let view = Preview(); view.preview.session = session; view.preview.videoGravity = .resizeAspectFill; return view }
    func updateUIView(_ uiView: Preview, context: Context) {}
}
