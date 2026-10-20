import SwiftUI
import CoreImage

@MainActor enum VisibleCropChecks {
    static func run() async -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let first = C7FactsProbe.image(C7FactsProbe.firstCode).cgImage!.cropping(to: CGRect(x: 0, y: 270, width: 768, height: 230))!
        let outside = C7FactsProbe.image(C7FactsProbe.secondCode).cgImage!.cropping(to: CGRect(x: 0, y: 270, width: 768, height: 230))!
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1080, height: 1920), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1080, height: 1920))
            UIImage(cgImage: first).draw(in: CGRect(x: 0, y: 650, width: 800, height: 260))
            UIImage(cgImage: outside).draw(in: CGRect(x: 90, y: 100, width: 900, height: 150))
            UIColor.blue.setFill(); context.fill(CGRect(x: 800, y: 1100, width: 200, height: 200))
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let image = CameraCapture.visibleImage(CIImage(cgImage: source.cgImage!), viewport: CGSize(width: 360, height: 360), context: context),
              let old = CameraCapture.centralImage(CIImage(cgImage: source.cgImage!), context: context) else { return ["render": false] }
        let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.82)!
        let scan = await SourceBarcodeDecoder.shared.scan(jpeg)
        let oldScan = await SourceBarcodeDecoder.shared.scan(UIImage(cgImage: old).jpegData(compressionQuality: 0.82)!)
        checks["full_visible_crop_is_768_square"] = image.width == 768 && image.height == 768
        checks["visible_edge_barcode_is_retained"] = scan.values.contains(C7FactsProbe.firstCode.value)
        checks["outside_preview_barcode_is_excluded"] = !scan.values.contains(C7FactsProbe.secondCode.value)
        checks["old_78_percent_crop_loses_edge_barcode"] = !oldScan.values.contains(C7FactsProbe.firstCode.value)
        let host = C2FixtureHost(name: "full-visible-crop", realBarcodes: true)
        try? FileManager.default.removeItem(at: host.root); await host.model.bootstrap()
        _ = host.model.beginAcquisition(); host.feed(source: UIImage(cgImage: image))
        await host.settle { host.waiter != nil }
        guard let record = host.model.records.first else { checks["archive_created"] = false; return checks }
        let archived = await host.model.image(for: record)
        checks["barcode_archive_provider_frozen_share_use_same_JPEG"] = host.lastJPEG == jpeg && archived == jpeg && host.model.submittedPreview?.jpeg == jpeg && host.model.submittedPreview?.id == record.id
        checks["edge_barcode_belongs_to_same_record"] = record.productBarcodes?.contains(C7FactsProbe.firstCode) == true
        await host.complete()
        checks["completion_does_not_change_source_or_resend"] = host.calls == 1 && host.model.records.first?.shareResult?.sourceImageID == record.id && host.model.submittedPreview == nil
        let evidence = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? source.pngData()?.write(to: evidence.appendingPathComponent("visible-crop-source.png"))
        try? jpeg.write(to: evidence.appendingPathComponent("visible-crop-sent.jpg"))
        host.model.closePreview()
        checks["no_real_network"] = C8NetworkProbe.shared.count == 0
        return checks
    }
}
struct VisibleCropChecksView: View {
    @State private var status = "running"
    var body: some View {
        Text(status).accessibilityIdentifier("visibleCropResult").task {
            let checks = await VisibleCropChecks.run()
            let passed = checks.values.allSatisfy { $0 }
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let report: [String: Any] = ["passed": passed, "checks": checks, "count": checks.count, "realNetworkRequests": 0, "cameraStarted": false]
            try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: root.appendingPathComponent("visible-crop-checks.json"))
            status = passed ? "passed \(checks.count)" : "FAILED " + checks.filter { !$0.value }.map(\.key).sorted().joined(separator: ",")
        }
    }
}
