import AppKit
import SwiftUI
import MergeProCore

/// Native segmented merge-method choice in GitHub's merge/squash/rebase order. Disallowed methods stay
/// visible but disabled; each explains itself in its segment tooltip and in the caption below.
struct MergeMethodSelector:View {
    let options:[MergeMethodOption]
    /// Nil shows no selected segment (e.g. a batch whose items use different methods).
    let selection:MergeMethod?
    let onSelect:@MainActor (MergeMethod) -> Void
    var compact=false
    var savedDefault:MergeMethod?=nil
    var repository:String?=nil
    var showsCaption=true
    init(options:[MergeMethodOption],method:Binding<MergeMethod>,compact:Bool=false,savedDefault:MergeMethod?=nil,repository:String?=nil,showsCaption:Bool=true) {
        self.options=options;selection=method.wrappedValue;onSelect={ method.wrappedValue=$0 }
        self.compact=compact;self.savedDefault=savedDefault;self.repository=repository;self.showsCaption=showsCaption
    }
    init(options:[MergeMethodOption],selection:MergeMethod?,compact:Bool=false,showsCaption:Bool=true,onSelect:@escaping @MainActor (MergeMethod) -> Void) {
        self.options=options;self.selection=selection;self.onSelect=onSelect;self.compact=compact;self.showsCaption=showsCaption
    }
    static func shortName(_ method:MergeMethod) -> String { switch method { case .merge:"Merge";case .squash:"Squash";case .rebase:"Rebase" } }
    var body:some View {
        VStack(alignment:.leading,spacing:compact ? 3 : 6) {
            MergeMethodSegments(options:options,selection:selection,compact:compact,onSelect:onSelect)
                .accessibilityLabel("Merge method")
            if showsCaption,!captions.isEmpty {
                VStack(alignment:.leading,spacing:2) {
                    ForEach(captions,id:\.text) { caption in
                        Label(caption.text,systemImage:caption.symbol).labelStyle(MergeCaptionLabelStyle())
                    }
                }.font(compact ? .caption2 : .caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }
    }
    private struct Caption { let text:String;let symbol:String }
    /// The saved default (or why it no longer applies), then each distinct disabled reason with the methods it covers.
    private var captions:[Caption] {
        var result:[Caption]=[]
        if let savedDefault,let repository {
            if options.contains(where:{ $0.method == savedDefault && $0.enabled }) { result.append(.init(text:"Default for \(repository): \(Self.shortName(savedDefault))",symbol:"star")) }
            else if options.contains(where:\.enabled) { result.append(.init(text:"Saved default \(Self.shortName(savedDefault)) is not allowed here.",symbol:"star.slash")) }
        }
        var reasons:[(reason:String,methods:[MergeMethod])]=[]
        for option in options where !option.enabled {
            let reason=option.reason ?? "Not allowed for this pull request."
            if let index=reasons.firstIndex(where:{ $0.reason == reason }) { reasons[index].methods.append(option.method) } else { reasons.append((reason,[option.method])) }
        }
        if reasons.count == 1,reasons[0].methods.count == options.count { return result+[.init(text:reasons[0].reason,symbol:"nosign")] }
        return result+reasons.map { .init(text:$0.methods.map(Self.shortName).joined(separator:", ")+": "+$0.reason,symbol:"nosign") }
    }
}
private struct MergeCaptionLabelStyle:LabelStyle {
    func makeBody(configuration:Configuration) -> some View { HStack(alignment:.firstTextBaseline,spacing:4) { configuration.icon.imageScale(.small);configuration.title } }
}
/// NSSegmentedControl keeps per-segment enablement and tooltips, which SwiftUI's segmented Picker cannot express.
private struct MergeMethodSegments:NSViewRepresentable {
    let options:[MergeMethodOption]
    let selection:MergeMethod?
    let compact:Bool
    let onSelect:@MainActor (MergeMethod) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context:Context) -> NSSegmentedControl {
        let control=NSSegmentedControl(labels:[],trackingMode:.selectOne,target:context.coordinator,action:#selector(Coordinator.changed(_:)))
        control.setAccessibilityIdentifier("mergeMethodSelector")
        control.setContentHuggingPriority(.defaultHigh,for:.vertical)
        return control
    }
    func updateNSView(_ control:NSSegmentedControl,context:Context) {
        context.coordinator.options=options;context.coordinator.onSelect=onSelect
        control.controlSize=compact ? .small : .regular
        control.segmentDistribution=compact ? .fit : .fillEqually
        control.segmentCount=options.count
        for (index,option) in options.enumerated() {
            control.setLabel(compact ? MergeMethodSelector.shortName(option.method) : option.label,forSegment:index)
            control.setEnabled(option.enabled,forSegment:index)
            control.setToolTip(option.enabled ? (compact ? option.label : nil) : option.reason ?? "Not allowed for this pull request.",forSegment:index)
        }
        control.selectedSegment=selection.flatMap { method in options.firstIndex { $0.method == method } } ?? -1
        control.isEnabled=context.environment.isEnabled
        control.invalidateIntrinsicContentSize()
    }
    /// Full-width in the sheet (equal segments); natural width when compact.
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:NSSegmentedControl,context:Context) -> CGSize? {
        let natural=nsView.intrinsicContentSize
        guard !compact,let width=proposal.width,width.isFinite else { return natural }
        return CGSize(width:max(natural.width,width),height:natural.height)
    }
    @MainActor final class Coordinator:NSObject {
        var options:[MergeMethodOption]=[]
        var onSelect:(@MainActor (MergeMethod) -> Void)?
        @objc func changed(_ sender:NSSegmentedControl) {
            guard options.indices.contains(sender.selectedSegment),options[sender.selectedSegment].enabled else { return }
            onSelect?(options[sender.selectedSegment].method)
        }
    }
}
