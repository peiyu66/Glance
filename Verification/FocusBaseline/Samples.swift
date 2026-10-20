// Appended after exact production crop/fingerprint/quality declarations.
// These targets are generated fixtures, never photographs or optical ground truth.
import Darwin
func note(_ value: String) { FileHandle.standardError.write(Data((value + "\n").utf8)) }
func required<T>(_ value: T?, _ stage: String) -> T {
    guard let value else { note("Baseline unavailable at: " + stage); exit(3) }
    return value
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
note("Creating Core Image context with production options")
let context = CIContext(options: [.cacheIntermediates: false])
let width = 1080, height = 1920

func generated(_ pattern: String, amplitude: Double = 0.8, level: Double = 0.5) -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    var seed: UInt64 = 0x5eed1234
    for y in 0..<height { for x in 0..<width {
        let value: Double
        switch pattern {
        case "fine": value = (x / 12 + y / 12).isMultiple(of: 2) ? 1 : -1
        case "coarse": value = (x / 96 + y / 96).isMultiple(of: 2) ? 1 : -1
        case "noise":
            seed = seed &* 6364136223846793005 &+ 1
            value = Double((seed >> 32) & 255) / 127.5 - 1
        case "edge-only":
            value = abs(x - width / 2) < 250 && abs(y - height / 2) < 250 ? 0 : ((x / 12 + y / 12).isMultiple(of: 2) ? 1 : -1)
        default: value = 0
        }
        let pixel = UInt8(max(0, min(255, (level + amplitude * value / 2) * 255)).rounded())
        let offset = (y * width + x) * 4
        bytes[offset] = pixel; bytes[offset + 1] = pixel; bytes[offset + 2] = pixel
    } }
    let data = Data(bytes) as CFData
    return required(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: required(CGDataProvider(data: data), "generated data provider"), decode: nil, shouldInterpolate: false, intent: .defaultIntent), "generated CGImage")
}

func png(_ image: CGImage, _ name: String) {
    let file = destination.appendingPathComponent(name + ".png")
    let writer = required(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil), "PNG destination")
    CGImageDestinationAddImage(writer, image, nil)
    if !CGImageDestinationFinalize(writer) { note("PNG finalization failed"); exit(3) }
}

struct Spec {
    let name: String
    let pattern: String
    let blur: Double
    var amplitude = 0.8
    var level = 0.5
}
var samples: [Spec] = []
for pattern in ["fine", "coarse"] {
    for blur in [0.0, 2.0, 6.0, 12.0, 24.0] {
        samples.append(Spec(name: "\(pattern)-blur-\(Int(blur))", pattern: pattern, blur: blur))
    }
}
samples += [Spec(name: "flat", pattern: "flat", blur: 0),
            Spec(name: "low-contrast", pattern: "fine", blur: 0, amplitude: 0.04),
            Spec(name: "dark", pattern: "coarse", blur: 0, amplitude: 0.04, level: 0.025),
            Spec(name: "noise", pattern: "noise", blur: 0),
            Spec(name: "textured-edge-flat-center", pattern: "edge-only", blur: 0)]
var records: [[String: Any]] = []
for sample in samples {
    note("Generating " + sample.name)
    let source = CIImage(cgImage: generated(sample.pattern, amplitude: sample.amplitude, level: sample.level))
    let perturbed = sample.blur == 0 ? source : source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sample.blur]).cropped(to: source.extent)
    let image = required(context.createCGImage(perturbed, from: source.extent), "source render")
    png(image, sample.name + "-source")
    // Call the unchanged production crop and quality, not a rewritten approximation.
    let crop = required(ProductionCapture.centralImage(CIImage(cgImage: image), context: context), "production central crop")
    png(crop, sample.name + "-crop")
    let fingerprint = required(ProductionCapture.fingerprint(crop, side: 128), "production quality sample")
    let quality = SceneQuality(fingerprint)
    let mean = fingerprint.rgb.reduce(0, +) / Float(fingerprint.rgb.count)
    records.append(["name": sample.name, "pattern": sample.pattern, "sourceGaussianRadius": sample.blur,
        "inputSize": [width, height], "cropSize": [crop.width, crop.height], "sampleSide": 128,
        "mean": mean, "contrast": quality.contrast, "edgeScore": quality.edgeScore, "usable": quality.usable,
        "sourceFile": sample.name + "-source.png", "cropFile": sample.name + "-crop.png"])
}
let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
try data.write(to: destination.appendingPathComponent("metrics.json"))
print("Saved \(records.count) generated targets and production crop/quality measurements.")
