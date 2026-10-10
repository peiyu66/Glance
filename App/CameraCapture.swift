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
    let regionalText: RegionalText?
    let time: TimeInterval
    let registration: NativeSceneRegistration.Observation?
    init(image: CGImage, fingerprint: SceneFingerprint, feature: VNFeaturePrintObservation?, labelSignature: String = "", regionalText: RegionalText? = nil, time: TimeInterval, registration: NativeSceneRegistration.Observation? = nil) {
        self.image = image; self.fingerprint = fingerprint; self.feature = feature; self.labelSignature = labelSignature; self.regionalText = regionalText; self.time = time; self.registration = registration
    }
}

struct CaptureStatistics: Sendable {
    var targetCropFraction: Double?
    var targetTextBoxes: Int?
    var targetBarcodeBoxes: Int?
    var stabilizationSupported: Bool?
    var stabilizationPreferred: Int?
    var stabilizationActive: Int?
    var standardStabilizationSupported: Bool?
    var lowLatencyStabilizationSupported: Bool?
    var stabilizationRequested: Int?
    var stabilizationSelectionReason: String?
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
    private var firstCaptureOnly = false
    private var liveCurrent = false
    private let liveRegistration = NativeSceneRegistration()
    func resetLiveRegistration() { liveRegistration.reset() }
    func prepareLiveFrame(_ image:CGImage,time:Double) throws -> CameraFrame {
        _ = try Self.prepareFirstCapture(image,time:time)
        guard let evidence=liveRegistration.observe(image) else { throw PreparationFailure.invalidCrop }
        return CameraFrame(image:image,fingerprint:evidence.fingerprint,feature:nil,time:time,registration:evidence)
    }
    func start(generation: UUID, firstCaptureOnly: Bool = false, liveCurrent: Bool = false) {
        queue.async { [self] in
            self.generation = generation; self.firstCaptureOnly = firstCaptureOnly; self.liveCurrent = liveCurrent; liveRegistration.reset(); stats = CaptureStatistics()
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
                // Prefer a mode explicitly documented not to add pipeline latency.
                // Supported connection and active format are both required. The
                // resulting active mode is sampled separately, never assumed.
                if let connection = session.outputs.compactMap({ $0 as? AVCaptureVideoDataOutput }).first?.connection(with: .video) {
                    var requested: AVCaptureVideoStabilizationMode = .off
                    stats.stabilizationSelectionReason = "low-latency-unavailable"
                    if #available(iOS 26.0, *), let input = connection.inputPorts.first?.input as? AVCaptureDeviceInput {
                        let supported = input.device.activeFormat.isVideoStabilizationModeSupported(.lowLatency)
                        stats.lowLatencyStabilizationSupported = supported
                        if connection.isVideoStabilizationSupported && supported {
                            requested = .lowLatency; stats.stabilizationSelectionReason = "connection-and-format-supported"
                        } else { stats.stabilizationSelectionReason = "connection-or-format-unsupported" }
                    }
                    stats.stabilizationRequested = requested.rawValue
                    connection.preferredVideoStabilizationMode = requested
                }
                if !session.isRunning { session.startRunning() }
            } catch { onFailure?("camera-configuration") }
        }
    }
    func stop() { queue.async { [self] in if session.isRunning { session.stopRunning() }; lastSample = 0 } }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        stats.stabilizationSupported = connection.isVideoStabilizationSupported
        stats.stabilizationPreferred = connection.preferredVideoStabilizationMode.rawValue
        stats.stabilizationActive = connection.activeVideoStabilizationMode.rawValue
        if let input = connection.inputPorts.first?.input as? AVCaptureDeviceInput { stats.standardStabilizationSupported = input.device.activeFormat.isVideoStabilizationModeSupported(.standard) }
        stats.frames += 1
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSample >= 0.25 else { return }; lastSample = now; stats.samples += 1
        autoreleasepool {
            guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { onFrame?(nil, generation, stats); return }
            let ci = CIImage(cvPixelBuffer: pixel)
            guard let image = Self.centralImage(ci, context: context), let fp = Self.fingerprint(image), let qualitySample = Self.fingerprint(image, side: 128) else { stats.qualityRejected += 1; onFrame?(nil, generation, stats); return }
            let quality = SceneQuality(qualitySample); stats.contrast = quality.contrast; stats.edgeScore = quality.edgeScore
            guard quality.usable else { stats.qualityRejected += 1; onFrame?(nil, generation, stats); return }
            if firstCaptureOnly {
                do {
                    let prepared = try liveCurrent ? prepareLiveFrame(image,time:now) : Self.prepareFirstCapture(image,time:now)
                    stats.localProcessingMS = (ProcessInfo.processInfo.systemUptime-now)*1000
                    stats.targetCropFraction = 1; stats.accepted += 1
                    onFrame?(prepared, generation, stats)
                } catch { stats.qualityRejected += 1; onFrame?(nil, generation, stats) }
                return
            }
            do {
                let prepared=try Self.prepareTarget(image,time:now)
                stats.localProcessingMS=(ProcessInfo.processInfo.systemUptime-now)*1000
                stats.targetCropFraction=Double(prepared.crop.width*prepared.crop.height)
                stats.targetTextBoxes=prepared.includedTextBoxes;stats.targetBarcodeBoxes=prepared.includedBarcodeBoxes
                stats.accepted += 1
                onFrame?(prepared.frame,generation,stats)
            } catch PreparationFailure.noCentralObject { stats.saliencyRejected += 1;onFrame?(nil,generation,stats) }
              catch PreparationFailure.qualityRejected { stats.qualityRejected += 1;onFrame?(nil,generation,stats) }
              catch { stats.visionRejected += 1;onFrame?(nil,generation,stats);onFailure?("local-vision") }

        }
    }
    /// Shared by camera samples and full-size generated source frames.
    static func centralImage(_ ci: CIImage, context: CIContext) -> CGImage? {
        let extent = ci.extent
        let side = min(extent.width, extent.height) * 0.78
        let crop = CGRect(x: extent.midX-side/2, y: extent.midY-side/2, width: side, height: side)
        let square = ci.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let scale = min(1, 768/side)
        let reduced = square.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(reduced, from: reduced.extent)
    }
    /// First-stage fixed central ROI; no OCR, feature identity or saliency re-crop.
    static func prepareFirstCapture(_ image: CGImage, time: Double) throws -> CameraFrame {
        guard let fingerprint = Self.fingerprint(image), let quality = Self.fingerprint(image, side: 128), SceneQuality(quality).usable else { throw PreparationFailure.qualityRejected }
        return CameraFrame(image: image, fingerprint: fingerprint, feature: nil, time: time)
    }

    struct CurrentImageEvidence {
        let pixels: DisplayPixelEvidence
        let translationX: Double
        let translationY: Double
        let commonFraction: Double
        let processingMS: Double
    }
    /// Current and reference retain fixed central coordinates. The frozen request
    /// image is never replaced by a newer frame. This is not a reacquisition API.
    static func compareCurrentImage(_ current: CGImage, to reference: CGImage, context: CIContext) throws -> CurrentImageEvidence {
        let start=ProcessInfo.processInfo.systemUptime
        guard current.width==reference.width,current.height==reference.height else { throw PreparationFailure.invalidCrop }
        let request=VNTranslationalImageRegistrationRequest(targetedCGImage:current,options:[:],completionHandler:nil)
        try VNImageRequestHandler(cgImage:reference,orientation:.up).perform([request])
        guard let observation=request.results?.first else { throw PreparationFailure.featureUnavailable }
        let transform=observation.alignmentTransform
        guard transform.tx.isFinite,transform.ty.isFinite,abs(transform.tx)<=12,abs(transform.ty)<=12 else { throw PreparationFailure.invalidCrop }
        let fixed=CIImage(cgImage:reference),floating=CIImage(cgImage:current).transformed(by:transform)
        // Only measured overlap is compared; report the overlap explicitly. The
        // candidate must pass edge-content/occlusion negatives before adoption.
        let common=fixed.extent.intersection(floating.extent).insetBy(dx:1,dy:1)
        let fraction=Double(common.width*common.height/(fixed.extent.width*fixed.extent.height))
        guard !common.isEmpty,fraction>=0.97,
              let a=context.createCGImage(floating,from:common),let b=context.createCGImage(fixed,from:common),
              let currentPixels=fingerprint(a,side:256),let referencePixels=fingerprint(b,side:256) else { throw PreparationFailure.invalidCrop }
        return CurrentImageEvidence(pixels:DisplayPixelEvidence(current:currentPixels,reference:referencePixels),
            translationX:Double(transform.tx),translationY:Double(transform.ty),commonFraction:fraction,
            processingMS:(ProcessInfo.processInfo.systemUptime-start)*1000)
    }

    enum PreparationFailure: Error { case noCentralObject, invalidCrop, qualityRejected, featureUnavailable }
    struct PreparedTarget {
        let frame: CameraFrame
        let reading: LabelReading
        let crop: CGRect
        let sourceSignature: String
        let includedTextBoxes: Int
        let includedBarcodeBoxes: Int
        let stageMS: [String:Double]
    }
    /// One bitmap supplies the JPEG, fingerprints, feature print and OCR. Bounds
    /// intersecting the central object are expanded to include complete labels.
    static func prepareTarget(_ image: CGImage, time: Double, allowMissingFeature: Bool = false, diagnosticRegion: CGRect? = nil, fixedCanvas: Bool = false) throws -> PreparedTarget {
        let preparationStart=ProcessInfo.processInfo.systemUptime
        let saliency=VNGenerateObjectnessBasedSaliencyImageRequest()
        let sourceText=textRequest()
        let barcodes=VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage:image,orientation:.up).perform([saliency,sourceText,barcodes])
        let sourceFinished=ProcessInfo.processInfo.systemUptime
        let candidates=(saliency.results?.first?.salientObjects ?? []).filter {
            $0.boundingBox.contains(CGPoint(x:0.5,y:0.5)) && $0.boundingBox.width*$0.boundingBox.height >= 0.04
        }
        guard let object=candidates.max(by: { $0.confidence < $1.confidence }) else { throw PreparationFailure.noCentralObject }
        let unit=CGRect(x:0,y:0,width:1,height:1)
        let detected=diagnosticRegion ?? object.boundingBox
        let seed=detected.insetBy(dx:-detected.width*0.04,dy:-detected.height*0.04).intersection(unit)
        var crop=seed; var textCount=0, barcodeCount=0
        func belongs(_ box: CGRect) -> Bool {
            let area=box.width*box.height; guard area>0 else { return false }
            let overlap=seed.intersection(box)
            return seed.contains(CGPoint(x:box.midX,y:box.midY)) || (!overlap.isNull && overlap.width*overlap.height/area >= 0.5)
        }
        for observation in sourceText.results ?? [] where belongs(observation.boundingBox) {
            crop=crop.union(observation.boundingBox); textCount += 1
        }
        for observation in barcodes.results ?? [] where belongs(observation.boundingBox) {
            crop=crop.union(observation.boundingBox); barcodeCount += 1
        }
        crop=crop.insetBy(dx:-crop.width*0.02,dy:-crop.height*0.02).intersection(unit)
        let pixels=CGRect(x:crop.minX*CGFloat(image.width),y:(1-crop.maxY)*CGFloat(image.height),width:crop.width*CGFloat(image.width),height:crop.height*CGFloat(image.height)).integral.intersection(CGRect(x:0,y:0,width:image.width,height:image.height))
        let preparedImage:CGImage?
        if fixedCanvas, let context=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.setFillColor(CGColor(gray:0.92,alpha:1));context.fill(CGRect(x:0,y:0,width:image.width,height:image.height))
            context.clip(to:CGRect(x:crop.minX*CGFloat(image.width),y:crop.minY*CGFloat(image.height),width:crop.width*CGFloat(image.width),height:crop.height*CGFloat(image.height)))
            context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));preparedImage=context.makeImage()
        } else { preparedImage=image.cropping(to:pixels) }
        guard let target=preparedImage, let fp=fingerprint(target), let quality=fingerprint(target,side:128), SceneQuality(quality).usable else { throw PreparationFailure.qualityRejected }
        let cropFinished=ProcessInfo.processInfo.systemUptime
        let feature=VNGenerateImageFeaturePrintRequest()
        if allowMissingFeature { try? VNImageRequestHandler(cgImage:target,orientation:.up).perform([feature]) }
        else { try VNImageRequestHandler(cgImage:target,orientation:.up).perform([feature]) }
        let print=feature.results?.first as? VNFeaturePrintObservation
        guard print != nil || allowMissingFeature else { throw PreparationFailure.featureUnavailable }
        // Reuse OCR boxes wholly contained in the final JPEG instead of a second
        // rescaled OCR pass. Geometry is transformed into that same crop's space.
        let barcodeEvidence=(barcodes.results ?? []).filter { crop.contains($0.boundingBox) }.compactMap { observation -> RegionalText.Line? in
            guard let payload=observation.payloadStringValue else { return nil }
            let b=observation.boundingBox
            return RegionalText.Line(text:"#barcode:"+labelDigest([payload]),confidence:observation.confidence,box:.init(x:Double(b.minX),y:Double(b.minY),width:Double(b.width),height:Double(b.height)))
        }
        let reading=reading(from:sourceText,start:preparationStart,objectRegion:crop,requireWholeBounds:true,barcodes:barcodeEvidence,evidenceRegion:fixedCanvas ? unit : nil)
        let featureFinished=ProcessInfo.processInfo.systemUptime
        let source=LabelEvidence.normalizedLines((sourceText.results ?? []).compactMap { $0.topCandidates(1).first }.map { ($0.string,$0.confidence) })
        return PreparedTarget(frame:CameraFrame(image:target,fingerprint:fp,feature:print,labelSignature:reading.signature,regionalText:reading.regional,time:time),reading:reading,crop:crop,sourceSignature:labelDigest(source),includedTextBoxes:textCount,includedBarcodeBoxes:barcodeCount,stageMS:["sourceVision":(sourceFinished-preparationStart)*1000,"cropAndFingerprint":(cropFinished-sourceFinished)*1000,"targetFeatureAndEvidence":(featureFinished-cropFinished)*1000,"total":(featureFinished-preparationStart)*1000])
    }
    private static func textRequest(minimumHeight: Float? = nil) -> VNRecognizeTextRequest {
        let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate
        request.recognitionLanguages=["zh-Hant","en-US"];request.usesLanguageCorrection=false
        if let minimumHeight { request.minimumTextHeight=minimumHeight }
        return request
    }

    struct LabelReading {
        let regional: RegionalText
        let signature: String
        let candidateCount: Int
        let maximumConfidence: Float
        let processingMS: Double
    }
    /// Region text is transient memory-only identity evidence; never log/serialize it.
    static func labelReading(_ image: CGImage, minimumHeight: Float? = nil, minimumConfidence: Float = 0.5, objectRegion: CGRect? = nil) throws -> LabelReading {
        let start = ProcessInfo.processInfo.systemUptime
        let request=textRequest(minimumHeight:minimumHeight)
        try VNImageRequestHandler(cgImage:image,orientation:.up).perform([request])
        return reading(from:request,start:start,minimumConfidence:minimumConfidence,objectRegion:objectRegion)
    }
    private static func reading(from request: VNRecognizeTextRequest, start: Double, minimumConfidence: Float = 0.5, objectRegion: CGRect? = nil, requireWholeBounds: Bool = false, barcodes: [RegionalText.Line] = [], evidenceRegion: CGRect? = nil) -> LabelReading {
        let region=objectRegion ?? CGRect(x:0,y:0,width:1,height:1)
        let observations=(request.results ?? []).filter { observation in
            let b=observation.boundingBox
            if requireWholeBounds && !region.contains(b) { return false }
            // Barcode bars can yield spurious OCR; decoded barcode evidence owns
            // that region. Human-readable digits below it remain separate text.
            return !barcodes.contains { code in
                let codeBox=CGRect(x:code.box.x,y:code.box.y,width:code.box.width,height:code.box.height)
                let overlap=codeBox.intersection(b)
                return !overlap.isNull && overlap.width*overlap.height >= b.width*b.height*0.5
            }
        }
        let candidates = observations.compactMap { $0.topCandidates(1).first }
        let lines = LabelEvidence.normalizedLines(candidates.map { ($0.string,$0.confidence) }, minimumConfidence: minimumConfidence)
        let regionalLines=observations.compactMap { observation -> RegionalText.Line? in
            guard let candidate=observation.topCandidates(1).first else { return nil }
            let b=observation.boundingBox
            return RegionalText.Line(text:candidate.string,confidence:candidate.confidence,box:.init(x:Double(b.minX),y:Double(b.minY),width:Double(b.width),height:Double(b.height)))
        }
        let coordinates=evidenceRegion ?? region
        let regional=RegionalText(lines:regionalLines+barcodes,object:.init(x:Double(coordinates.minX),y:Double(coordinates.minY),width:Double(coordinates.width),height:Double(coordinates.height)))
        return LabelReading(regional: regional, signature: labelDigest(lines+barcodes.map(\.text)), candidateCount: candidates.count,
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
    var onStabilization: (Bool, Int, Int) -> Void
    final class Preview: UIView {
        var onStabilization: ((Bool, Int, Int) -> Void)?
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override func layoutSubviews() {
            super.layoutSubviews()
            if let c = preview.connection {
                if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
                onStabilization?(c.isVideoStabilizationSupported, c.preferredVideoStabilizationMode.rawValue, c.activeVideoStabilizationMode.rawValue)
            }
        }
    }
    func makeUIView(context: Context) -> Preview { let view = Preview(); view.onStabilization = onStabilization; view.preview.session = session; view.preview.videoGravity = .resizeAspectFill; return view }
    func updateUIView(_ uiView: Preview, context: Context) {}
}
