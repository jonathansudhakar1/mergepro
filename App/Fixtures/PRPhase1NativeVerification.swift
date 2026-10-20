import AppKit
import Foundation
import MergeProCore
import MergeProRendering
import SwiftUI

/// Fixture-only measurement/barrier state; product authorization remains in the session.
@MainActor @Observable final class PRPhase1NativeVerification {
    static let shared=PRPhase1NativeVerification()
    private let started=ContinuousClock.now
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    private var emitted=0
    var released=false
    private var inputMonitor:Any?
    private var inputSequence=0
    private var manualOpens:[ProviderKey:ContinuousClock.Instant]=[:]
    private var cachedPublications:[ProviderKey:ContinuousClock.Instant]=[:]
    private var observedGenerations:[Int:ContinuousClock.Instant]=[:]
    private var installed:[ObjectIdentifier:CodePresentationIdentity]=[:]
    static func mark(_ event:String,_ fields:[String:Any]=[:]) {
        guard PRPhase1Fixtures.enabled,shared.emitted < 500 else { return }
        shared.emitted += 1
        let duration=shared.started.duration(to:.now).components
        var record=fields
        record["event"]=event;record["offsetMs"]=Double(duration.seconds)*1000+Double(duration.attoseconds)/1e15
        record["pid"]=ProcessInfo.processInfo.processIdentifier
        record["bundle"]=Bundle.main.bundleIdentifier ?? ""
        if let data=try? JSONSerialization.data(withJSONObject:record,options:.sortedKeys) { FileHandle.standardOutput.write(data);FileHandle.standardOutput.write(Data("\n".utf8)) }
    }
    func waitForRelease() async {
        guard PRPhase1Fixtures.enabled,!released else { return }
        Self.mark("readiness-barrier-wait")
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        guard !released else { return };released=true
        Self.mark("readiness-barrier-release")
        let saved=waiters;waiters=[];saved.forEach { $0.resume() }
        inputMonitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.scrollWheel]) { event in
            MainActor.assumeIsolated {
                self.inputSequence += 1
                Self.mark("native-input",["input":self.inputSequence,"type":event.type == .scrollWheel ? "scroll" : "key","window":event.windowNumber])
            }
            return event
        }
    }
    func open(_ key:ProviderKey) { manualOpens[key] = .now;Self.mark("manual-open-handler",["account":key.accountID,"object":key.objectID]) }
    func route(_ key:ProviderKey) {
        Self.mark("detail-route-entry",["account":key.accountID,"object":key.objectID,"origin":manualOpens[key] == nil ? "restored-or-external-route" : "manual-handler"])
    }
    func cached(_ key:ProviderKey) { cachedPublications[key] = .now;Self.mark("cached-generation-publication",["account":key.accountID,"object":key.objectID]) }
    static func seconds(_ duration:Duration) -> Double { Double(duration.components.seconds)+Double(duration.components.attoseconds)/1e18 }
    @discardableResult static func screenRecord(_ view:NSView,tag:String) -> Bool {
        guard PRPhase1Fixtures.enabled,let window=view.window else { return false }
        let useful=window.convertToScreen(view.convert(view.bounds,to:nil))
        let title=NSRect(x:window.frame.minX,y:window.frame.maxY-28,width:window.frame.width,height:28)
        let screens=NSScreen.screens.enumerated().map { index,screen -> [String:Any] in
            let overlap=useful.intersection(screen.visibleFrame),titleOverlap=title.intersection(screen.visibleFrame)
            return ["index":index,"frame":NSStringFromRect(screen.frame),"visibleFrame":NSStringFromRect(screen.visibleFrame),"backingScale":screen.backingScaleFactor,"usefulIntersection":NSStringFromRect(overlap),"usefulArea":overlap.isNull ? 0 : overlap.width*overlap.height,"titleArea":titleOverlap.isNull ? 0 : titleOverlap.width*titleOverlap.height]
        }
        mark("screen-intersection",["tag":tag,"window":window.windowNumber,"identifier":window.identifier?.rawValue ?? "","title":window.title,"visible":window.isVisible,"miniaturized":window.isMiniaturized,"windowFrame":NSStringFromRect(window.frame),"usefulFrame":NSStringFromRect(useful),"screens":screens,"geometryOnly":"does not prove occlusion/capture/compositor"])
        return window.isVisible && !window.isMiniaturized && NSScreen.screens.contains { screen in
            let content=useful.intersection(screen.visibleFrame),chrome=title.intersection(screen.visibleFrame)
            return !content.isNull && content.width > 0 && content.height > 0 && !chrome.isNull && chrome.width > 0 && chrome.height > 0
        }
    }
    static func observe(_ surface:NativeCodeSurface,identity:CodePresentationIdentity?,installation:Duration) {
        guard PRPhase1Fixtures.enabled else { return }
        let surfaceID=ObjectIdentifier(surface)
        shared.installed[surfaceID]=identity
        guard let identity else { return }
        let key=identity.key
        mark("native-document-installed",identity.fields.merging(["characters":surface.codeView.string.utf16.count,"installationMs":seconds(installation)*1000],uniquingKeysWith:{ _,new in new }))
        Task { @MainActor [weak surface] in
            await Task.yield()
            guard shared.installed[surfaceID] == identity,let surface,!surface.codeView.string.isEmpty,let window=surface.window,surface.contentView.bounds.width > 0,surface.contentView.bounds.height > 0 else { return }
            surface.layoutSubtreeIfNeeded();surface.applyViewportAttributes();surface.displayIfNeeded()
            guard surface.codeView.textLayoutManager?.textViewportLayoutController.viewportRange != nil else { mark("viewport-range-unavailable");return }
            let generation=shared.cachedPublications[key] ?? shared.started
            if shared.observedGenerations[window.windowNumber] != generation {
                guard screenRecord(surface.contentView,tag:"code-viewport") else { mark("viewport-off-screen",identity.fields);return }
                shared.observedGenerations[window.windowNumber]=generation
                var record=identity.fields
                record.merge(["window":window.windowNumber,"lines":surface.codeView.string.components(separatedBy:"\n").count,"scope":"programmatic visible TextKit layout/display; input/compositor remains separate"],uniquingKeysWith:{ _,new in new })
                if let start=shared.manualOpens[key] { record["handlerToFirstViewportMs"]=seconds(start.duration(to:.now))*1000 }
                if let start=shared.cachedPublications[key] { record["cachedPublicationToFirstViewportMs"]=seconds(start.duration(to:.now))*1000 }
                mark("first-code-viewport-layout",record)
            }
        }
    }
    static func viewportChanged(_ surface:NativeCodeSurface) {
        guard PRPhase1Fixtures.enabled else { return }
        let start=ContinuousClock.now
        surface.layoutSubtreeIfNeeded();surface.applyViewportAttributes();surface.displayIfNeeded()
        mark("clip-bounds-to-layout",["input":shared.inputSequence,"window":surface.window?.windowNumber ?? -1,"bounds":NSStringFromRect(surface.contentView.bounds),"layoutMs":seconds(start.duration(to:.now))*1000,"scope":"bounds observer through programmatic layout/display, excluding prior event work/compositor"])
    }
}
extension CodePresentationIdentity {
    var fields:[String:Any] { ["host":key.host,"account":key.accountID,"repository":key.repositoryID,"object":key.objectID,"head":head,"origin":origin,"comparison":comparison,"path":path,"presentation":presentation.uuidString] }
}
struct PRPhase1WindowProbe:NSViewRepresentable {
    let tag:String
    var generation=0
    func makeNSView(context:Context) -> Probe { let view=Probe();view.metricTag=tag;return view }
    func updateNSView(_ view:Probe,context:Context) { view.metricTag=tag;if view.generation != generation { view.generation=generation;view.needsLayout=true } }
    final class Probe:NSView {
        var metricTag="",generation=0
        private var recorded:Int?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow();needsLayout=true }
        override func layout() {
            super.layout()
            guard window != nil,bounds.width > 0,bounds.height > 0,recorded != generation else { return }
            recorded=generation
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self,let window=self.window else { return }
                window.contentView?.layoutSubtreeIfNeeded();window.contentView?.displayIfNeeded()
                PRPhase1NativeVerification.screenRecord(self,tag:self.metricTag)
                if self.metricTag == "workspace" {
                    @MainActor func tables(_ view:NSView) -> [NSTableView] { (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables) }
                    let rows=window.contentView.map(tables)?.map(\.numberOfRows) ?? []
                    PRPhase1NativeVerification.mark("workspace-visible-layout",["generation":self.generation,"tableRows":rows,"scope":"native content layout/display and table row count; no AX enumeration"])
                }
            }
        }
    }
}
struct PRPhase1FixtureControls:View {
    let model:SetupModel
    @Environment(\.openWindow) private var openWindow
    var body:some View {
        HStack {
            Text("Offline Phase 1 · 20 scoped PRs").font(.caption)
            Button("Release readiness") { PRPhase1NativeVerification.shared.release() }.disabled(PRPhase1NativeVerification.shared.released)
            Button("Open cached A") {
                if let pr=model.prs.rows.first(where:{ $0.key.account == PRPhase1Fixtures.accounts[0] && $0.metadata?.number == 1 }) {
                    PRPhase1NativeVerification.shared.open(pr.key);model.prs.recordOpen(pr.key);openWindow(id:"pr-detail",value:pr.key)
                }
            }.disabled(model.prs.rows.isEmpty)
            Button("Release refresh") { Task { await model.prs.storage.releasePhase1Refresh() } }
            Button("Confirm pending merge") { Task { await model.prs.storage.confirmPhase1Merge() } }
            Button("Move #4 head") { Task { await model.prs.storage.movePhase1Revision() } }
            Button("Deny B · failed cleanup") { Task { try? await model.prs.storage.denyPhase1B() } }
        }.padding(8).background(.bar)
    }
}
