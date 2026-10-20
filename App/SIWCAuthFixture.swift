import SwiftUI

/// Explicit, entirely synthetic diagnostic/UI fixture. Does not load account storage.
struct SIWCAuthFixtureView: View {
    @State private var status = "正在驗證登入診斷 D2（無登入／相機／網路）"
    var body: some View { Text(status).padding().task {
        status = await SIWCAuthFixture.runOnce() ? "登入診斷 D2 合成檢查通過" : "登入診斷 D2 合成檢查未通過"
    } }
}

@MainActor enum SIWCAuthFixture {
    private static var task: Task<Bool, Never>?
    static func runOnce() async -> Bool {
        // Own the run independently of transient SwiftUI task/view cancellation.
        if let task { return await task.value }
        let started = Task { await run() }; task = started
        return await started.value
    }
    private static func run() async -> Bool {
        let progress = SIWCAuthFixtureProgress.shared
        guard ProcessInfo.processInfo.arguments.contains("--siwc-auth-fixture") else { return false }
        guard progress.mark("view-task-entered") else { return false }
        defer { progress.failIfUnfinished("returned-before-completion") }
        guard let folder = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else {
            progress.failIfUnfinished("documents-unavailable"); return false
        }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            progress.failIfUnfinished("window-scene-unavailable"); return false
        }
        guard progress.mark("controller-start") else { return false }
        let controller = SIWCController()
        let result = controller.runAuthDiagnosticFixture()
        guard progress.mark("controller-complete", detail:["controllerChecks":result.checks,"exampleCount":result.examples.count]) else { return false }
        var rows: [[String: Any]] = []
        var bootstrap: UIWindow? = UIWindow(windowScene:scene)
        bootstrap?.rootViewController = PortraitFixtureHost(rootView:Color.clear)
        guard progress.mark("bootstrap-window-start") else { return false }
        bootstrap?.makeKeyAndVisible()
        bootstrap?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations:.portrait))
        await SummaryReadingUIChecks.settle(); await SummaryReadingUIChecks.settle()
        bootstrap?.isHidden = true; bootstrap?.rootViewController = nil; bootstrap = nil
        let names = ["success", "token-404", "transport", "cancelled", "browser-error", "identity", "workspace-denied", "repeated-return"]
        for (index,example) in result.examples.enumerated() {
            for (size,width,height,type) in [("normal",CGFloat(375),CGFloat(812),DynamicTypeSize.large),("maximum",CGFloat(320),CGFloat(568),DynamicTypeSize.accessibility5)] {
                guard progress.mark("ui-case-start", detail:["case":names[index]+"-"+size,"completedCases":rows.count]) else { return false }
                let host = PortraitFixtureHost(rootView:Form {
                    Section("登入診斷 · D2") { SIWCAuthDiagnosticView(diagnostic:example) }
                }.environment(\.dynamicTypeSize,type))
                let window = UIWindow(windowScene:scene);window.frame=CGRect(x:0,y:0,width:width,height:height)
                window.rootViewController=host;window.makeKeyAndVisible()
                await SummaryReadingUIChecks.settle()
                window.frame=CGRect(x:0,y:0,width:width,height:height);window.bounds=CGRect(x:0,y:0,width:width,height:height)
                host.view.setNeedsLayout();host.view.layoutIfNeeded();await SummaryReadingUIChecks.settle()
                guard progress.mark("ui-layout-complete") else { window.isHidden=true; return false }
                let scrolls=SummaryReadingUIChecks.descendants(host.view).compactMap { $0 as? UIScrollView }.filter { $0.bounds.height>80 && $0.contentSize.height>0 }
                let scroll=scrolls.max { $0.contentSize.height < $1.contentSize.height }
                var checks:[String:Bool]=["actualWindowSize":abs(host.view.bounds.width-width)<1 && abs(host.view.bounds.height-height)<1,
                    "hasReadableScroll":scroll != nil,"hasDiagnosticEvents":!example.events.isEmpty,
                    "D2ComponentUsesCorrectRevision":SIWCAuthDiagnostic.revision == "D2",
                    "callbackFixRevision":SIWCProtocol.callbackRevision == "C1"]
                var metrics:[String:Double]=[:]
                if let scroll {
                    checks["noHorizontalOverflow"] = scroll.contentSize.width<=scroll.bounds.width+1
                    checks["viewportUsable"] = scroll.bounds.height>=100
                    let bottom=max(-scroll.adjustedContentInset.top,scroll.contentSize.height-scroll.bounds.height+scroll.adjustedContentInset.bottom)
                    scroll.setContentOffset(CGPoint(x:0,y:bottom),animated:false);await SummaryReadingUIChecks.settle()
                    checks["lastRowsReachable"] = abs(scroll.contentOffset.y-bottom)<2
                    metrics=["viewportHeight":Double(scroll.bounds.height),"contentHeight":Double(scroll.contentSize.height),"bottomOffset":Double(scroll.contentOffset.y)]
                    scroll.setContentOffset(CGPoint(x:0,y:-scroll.adjustedContentInset.top),animated:false);await SummaryReadingUIChecks.settle()
                    if (index==1 && size=="normal") || (index==6 && size=="maximum") {
                        guard progress.mark("screenshot-start") else { window.isHidden=true; return false }
                        let format=UIGraphicsImageRendererFormat();format.scale=1
                        let image=UIGraphicsImageRenderer(bounds:host.view.bounds,format:format).image { _ in host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true) }
                        if let data=image.pngData() { try? data.write(to:folder.appendingPathComponent("siwc-D2-"+names[index]+"-"+size+".png"),options:.atomic) }
                    }
                }
                rows.append(["scenario":names[index]+"-"+size,"checks":checks,"metrics":metrics,"passed":checks.values.allSatisfy { $0 }])
                window.isHidden=true;window.rootViewController=nil
                guard progress.mark("ui-case-complete", detail:["completedCases":rows.count,"uiCases":rows]) else { return false }
            }
        }
        let passed=result.checks.values.allSatisfy { $0 } && rows.count==16 && rows.allSatisfy { $0["passed"] as? Bool == true }
        let report:[String:Any]=["revision":"D2","callbackRevision":SIWCProtocol.callbackRevision,"fixture":"auth-diagnostic-production-handlers-and-ui","complete":true,"passed":passed,
            "controllerChecks":result.checks,"uiCases":rows,"processID":ProcessInfo.processInfo.processIdentifier,
            "recordedAt":ISO8601DateFormatter().string(from:Date()),"cameraStarted":false,"networkRequests":0,"keychainLoaded":false,
            "scope":"Synthetic events through production diagnostic handlers and actual SwiftUI component. No real OAuth, callback network listener, account storage, camera, model or inference. Does not prove sign-in works." ]
        return progress.finish(report) && passed
    }
}

/// Synthetic-only progress. Synchronous atomic checkpoints also survive main-thread stalls.
/// No real auth data, launch arguments, errors, URLs, or credentials are accepted here.
final class SIWCAuthFixtureProgress: @unchecked Sendable {
    static let shared = SIWCAuthFixtureProgress()
    private let lock = NSLock()
    private var started = false
    private var terminal = false
    private var startedAt = Date()
    private var heartbeatAt = Date()
    private var events: [[String:Any]] = []
    private var payload: [String:Any] = [:]
    private var url: URL?

    func boot() {
        guard ProcessInfo.processInfo.arguments.contains("--siwc-auth-fixture") else { return }
        lock.lock()
        guard !started else { lock.unlock(); return }
        started=true; startedAt=Date(); heartbeatAt=startedAt
        url=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first?.appendingPathComponent("siwc-auth-fixture.json")
        payload=["revision":"D2","fixtureRevision":2,"processID":ProcessInfo.processInfo.processIdentifier,
                 "complete":false,"passed":false,"state":"running","launchFlagRecognized":true,
                 "deadlineSeconds":65,"cameraStarted":false,"networkRequests":0,"keychainLoaded":false]
        appendLocked("app-initialized"); writeLocked(); lock.unlock()
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+65) { self.timeout() }
        beat()
    }
    private func beat() {
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
            self.lock.lock(); let active=self.started && !self.terminal
            if active { self.heartbeatAt=Date() }
            self.lock.unlock()
            if active { self.beat() }
        }
    }
    @discardableResult func mark(_ stage:String, detail:[String:Any]=[:]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard started && !terminal else { return false }
        for (key,value) in detail { payload[key]=value }
        appendLocked(stage); writeLocked(); return !terminal
    }
    func finish(_ report:[String:Any]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard started && !terminal else { return false }
        for (key,value) in report { payload[key]=value }
        payload["state"]="completed"; terminal=true; appendLocked("report-complete")
        return writeLocked()
    }
    func failIfUnfinished(_ reason:String) {
        lock.lock(); defer { lock.unlock() }
        guard started && !terminal else { return }
        terminal=true;payload["state"]="early-return";payload["failure"]=reason
        appendLocked("early-return");writeLocked()
    }
    private func timeout() {
        lock.lock(); defer { lock.unlock() }
        guard started && !terminal else { return }
        terminal=true;payload["state"]="timed-out";payload["failure"]="fixture-deadline"
        payload["mainHeartbeatAgeSeconds"]=Date().timeIntervalSince(heartbeatAt)
        appendLocked("deadline-expired");writeLocked()
    }
    private func appendLocked(_ stage:String) {
        payload["stage"]=stage;payload["recordedAt"]=ISO8601DateFormatter().string(from:Date())
        events.append(["stage":stage,"elapsedSeconds":Date().timeIntervalSince(startedAt)])
        if events.count>96 { events.removeFirst(events.count-96) }
        payload["events"]=events
        print("SIWC_FIXTURE_D2: \(stage)")
    }
    @discardableResult private func writeLocked() -> Bool {
        do {
            guard let url else { print("SIWC_FIXTURE_D2: report-write-failed-no-documents");terminal=true;return false }
            let data=try JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys])
            try data.write(to:url,options:.atomic); return true
        } catch {
            // Numeric code only; never an arbitrary NSError description or URL.
            print("SIWC_FIXTURE_D2: report-write-failed-code-\((error as NSError).code)")
            terminal=true;return false
        }
    }
}
