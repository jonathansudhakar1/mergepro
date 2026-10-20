import AppKit
import MergeProCore
import MergeProRendering
import SwiftUI

struct PRDetailFixtureLauncher:ViewModifier {
    let model:SetupModel
    @Environment(\.openWindow) private var openWindow
    @State private var started=false
    func body(content:Content) -> some View {
        content.task(id:model.prs.rows.count) {
            guard !started,PRDetailFixtureMetrics.enabled,!model.prs.rows.isEmpty else { return };started=true
            for number in [1,2] {
                guard let pr=model.prs.rows.first(where:{ $0.metadata?.number == number }) else { continue }
                PRDetailFixtureMetrics.started[number == 1 ? 5000 : 10000] = .now
                openWindow(id:"pr-detail",value:pr.key)
                try? await Task.sleep(for:.seconds(5))
            }
        }
    }
}
@MainActor enum PRDetailFixtureMetrics {
    static var enabled:Bool { PRNativeFixtures.enabled && ProcessInfo.processInfo.environment["MERGEPRO_DETAIL_VERIFY"] == "1" }
    static var started:[Int:ContinuousClock.Instant]=[:]
    static var recorded=Set<Int>()
    static func observe(_ surface:NativeCodeSurface,setDocumentDuration:Duration) {
        guard enabled else { return }
        let lines=surface.codeView.string.components(separatedBy:"\n").count-1
        guard [5000,10000].contains(lines),recorded.insert(lines).inserted else { return }
        Task { @MainActor [weak surface] in
            try? await Task.sleep(for:.milliseconds(250))
            guard let surface,let window=surface.window,window.isVisible else { return }
            surface.layoutSubtreeIfNeeded();surface.displayIfNeeded()
            let open=started[lines]?.duration(to:.now)
            var samples:[String:Double]=[:]
            func seconds(_ duration:Duration) -> Double { Double(duration.components.seconds)+Double(duration.components.attoseconds)/1e18 }
            for (name,fraction) in [("top",0.0),("middle",0.5),("end",0.99)] {
                let start=ContinuousClock.now
                surface.codeView.scrollRangeToVisible(NSRange(location:Int(Double(surface.codeView.string.utf16.count)*fraction),length:1))
                surface.layoutSubtreeIfNeeded();surface.displayIfNeeded();surface.applyViewportAttributes()
                samples[name]=seconds(start.duration(to:.now))
            }
            let ns=surface.codeView.string as NSString,cat=ns.range(of:"🐈")
            surface.codeView.setSelectedRange(cat)
            let selected=(surface.codeView.string as NSString).substring(with:surface.codeView.selectedRange())
            window.appearance=NSAppearance(named:lines == 5000 ? .aqua : .darkAqua)
            surface.codeView.scrollRangeToVisible(NSRange(location:0,length:1))
            let record:[String:Any]=["lines":lines,"bundle":Bundle.main.bundleIdentifier ?? "","windowVisible":window.isVisible,"windowFrame":NSStringFromRect(window.frame),"surfaceFrame":NSStringFromRect(surface.frame),"textKit2":surface.codeView.textLayoutManager != nil,"fixtureSource":"offline fixture values; no provider request","openToVisibleSecondsIncluding250msSettling":open.map(seconds) ?? -1,"setDocumentSeconds":seconds(setDocumentDuration),"scrollLayoutSeconds":samples,"unicodeSelectionVerified":selected == "🐈","appearance":lines == 5000 ? "light" : "dark","scope":"in-app layout/display calls; not physical input or compositor latency"]
            do {
                let directory=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("MergeProUIFixtures/"+ProcessInfo.processInfo.environment["MERGEPRO_UI_TEST_NAMESPACE"]!)
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("detail-\(lines).json"))
                FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]))
                FileHandle.standardOutput.write(Data("\n".utf8))
                FileHandle.standardError.write(Data("TASK6 DETAIL METRICS \(lines) \(directory.path)\n".utf8))
            } catch { FileHandle.standardError.write(Data("TASK6 detail metrics write failed\n".utf8)) }
        }
    }
}
