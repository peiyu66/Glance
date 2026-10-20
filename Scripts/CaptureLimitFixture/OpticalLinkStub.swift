import Foundation
// Link-only stand-in for this lifecycle fixture. Every call is an error and counted.
enum CaptureFixtureOpticalCalls { nonisolated(unsafe) static var count = 0 }
final class GLOpenCVFeatures: NSObject { var metadata:[String:Any] { [:] } }
enum GLOpenCVBridge {
    static func focusMetrics(gray: Data, width: Int, height: Int) throws -> [String: Any] { CaptureFixtureOpticalCalls.count += 1; throw CocoaError(.featureUnsupported) }
    static func buildMetadata() -> [String:Any] { CaptureFixtureOpticalCalls.count += 1; return [:] }
    static func features(png:Data,mask:Data) throws -> GLOpenCVFeatures { CaptureFixtureOpticalCalls.count += 1; throw CocoaError(.featureUnsupported) }
    static func compare(_ a:GLOpenCVFeatures,_ b:GLOpenCVFeatures)->[String:Any] { CaptureFixtureOpticalCalls.count += 1;return [:] }
}
