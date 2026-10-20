// Exact production metrics on saved generated baseline and controlled variants.
let baseline = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let context = CIContext(options: [.cacheIntermediates: false])
var rows: [[String: Any]] = []
@MainActor func measure(_ image: CGImage, name: String, source: String) {
    guard let visible = ProductionCapture.visibleImage(CIImage(cgImage: image), viewport: CGSize(width: 768, height: 768), context: context) else { fatalError("visible image render unavailable") }
    let start = ProcessInfo.processInfo.systemUptime
    var values: [CentralFocusQuality] = []
    for _ in 0..<5 { values.append(ProductionCapture.centralFocusQuality(visible)) }
    let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000 / 5
    let q = values.last!
    rows.append(["name": name, "source": source, "visibleSize": [visible.width, visible.height], "state":q.state.rawValue, "reason":q.reason.rawValue, "mean":q.mean, "variance":q.variance, "tenengrad":q.tenengrad, "laplacianVariance":q.laplacianVariance, "score":q.score, "milliseconds":elapsed])
}
let files = try FileManager.default.contentsOfDirectory(at: baseline, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasSuffix("-source.png") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
for file in files {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("generated PNG unavailable") }
    measure(image, name:file.deletingPathExtension().lastPathComponent, source:file.lastPathComponent)
    if file.lastPathComponent == "coarse-blur-0-source.png" {
        let original = CIImage(cgImage:image)
        let variants: [(String, CIImage)] = [
            ("motion-24", original.clampedToExtent().applyingFilter("CIMotionBlur", parameters:[kCIInputRadiusKey:24,kCIInputAngleKey:0]).cropped(to:original.extent)),
            ("motion-diagonal-24", original.clampedToExtent().applyingFilter("CIMotionBlur", parameters:[kCIInputRadiusKey:24,kCIInputAngleKey:Double.pi / 4]).cropped(to:original.extent)),
            ("center-blur-24", original.clampedToExtent().applyingFilter("CIGaussianBlur", parameters:[kCIInputRadiusKey:24]).cropped(to:CGRect(x:original.extent.midX - 270,y:original.extent.midY - 270,width:540,height:540)).composited(over:original)),
            ("exposure-minus-1", original.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:-1])),
            ("exposure-plus-1", original.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:1]))
        ]
        for (name, variant) in variants { if let rendered=context.createCGImage(variant,from:original.extent) { measure(rendered,name:name,source:file.lastPathComponent) } }
    }
}
for name in ["smooth-gradient", "sharp-circle", "white", "black"] {
    let width = 1080, height = 1920
    var bytes = [UInt8](repeating: 128, count: width * height)
    for y in 0..<height { for x in 0..<width {
        let value: Double
        switch name {
        case "smooth-gradient": value = Double(x) / Double(width - 1)
        case "sharp-circle": value = hypot(Double(x - width / 2), Double(y - height / 2)) < 140 ? 0.9 : 0.1
        case "white": value = 1
        default: value = 0
        }
        bytes[y * width + x] = UInt8((value * 255).rounded())
    } }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    measure(image, name: name, source: "deterministic-generated-" + name)
}
let data=try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys])
try data.write(to:output)
print("Measured \(rows.count) generated images with exact production OpenCV focus path; no camera/network.")
