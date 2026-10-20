// The production controller is compiled unchanged. Only unavailable, unreachable
// UIKit UI APIs are supplied here. Browser/window/camera paths are never invoked.
import AppKit
@MainActor final class UIApplication {
    static let shared=UIApplication()
    var connectedScenes:[NSObject]=[]
    var isIdleTimerDisabled=false
}
@MainActor final class UIWindowScene: NSObject { var windows:[NSWindow]=[] }
typealias UIColor=NSColor
typealias UIFont=NSFont
final class UIGraphicsImageRenderer {
    init(size:CGSize) { fatalError("Image path is excluded from auth contract fixture") }
    final class Context { func fill(_ rect:CGRect) { fatalError("Excluded UI path") } }
    func pngData(actions:(Context)->Void)->Data { fatalError("Excluded UI path") }
}
