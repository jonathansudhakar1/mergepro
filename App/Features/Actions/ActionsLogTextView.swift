import AppKit
import SwiftUI
import MergeProCore
struct ActionsLogTextView:View {
    let text:String
    let search:String
    let webURL:URL?
    var stepNumber:Int=1
    @State private var line="1"
    @State private var targetLine=1
    /// Each Go is a new request, so returning to the same line after scrolling away still moves the log.
    @State private var jumpRequest=0
    var body:some View {
        VStack(spacing:10) {
            ViewThatFits(in:.horizontal) {
                HStack(spacing:10) { lineControls;copyLink;Spacer(minLength:0);lineCount }
                VStack(alignment:.leading,spacing:8) { lineControls;HStack { copyLink;Spacer(minLength:0);lineCount } }
            }.padding(10).workspacePanel(radius:12)
            ActionsNativeLog(text:text,search:search,targetLine:targetLine,jumpRequest:jumpRequest)
                .clipShape(RoundedRectangle(cornerRadius:12))
                .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(Color(nsColor:.separatorColor),lineWidth:1).allowsHitTesting(false))
        }
    }
    private var lineControls:some View {
        HStack(spacing:8) { Text("Line").font(.callout).foregroundStyle(.secondary);TextField("Line",text:$line).frame(width:58).onSubmit { go() };Button("Go") { go() } }
    }
    private func go() { targetLine=max(1,Int(line.trimmingCharacters(in:.whitespaces)) ?? 1);jumpRequest += 1 }
    private var copyLink:some View {
        Button("Copy job link",systemImage:"link") { guard let webURL,let link=ActionsLog.safeJobLink(webURL) else { return };NSPasteboard.general.clearContents();NSPasteboard.general.setString(link.absoluteString,forType:.string) }.disabled(webURL==nil)
    }
    private var lineCount:some View {
        Text("\(text.components(separatedBy:"\n").count) lines").font(.caption.monospacedDigit()).foregroundStyle(.secondary)

    }
}
private struct ActionsNativeLog:NSViewRepresentable {
    let text:String
    let search:String
    let targetLine:Int
    let jumpRequest:Int
    func makeNSView(context:Context) -> NSScrollView {
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true
        let view=NSTextView();view.isEditable=false;view.isSelectable=true;view.isRichText=true;view.font = .monospacedSystemFont(ofSize:12,weight:.regular);view.textContainerInset=NSSize(width:12,height:12);view.isHorizontallyResizable=true;view.isVerticallyResizable=true;view.textContainer?.widthTracksTextView=false;view.textContainer?.containerSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude);view.minSize = .zero;view.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude);scroll.documentView=view;return scroll
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var identity="";var jumpRequest = -1;var ranges:[NSRange]=[] }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard let view=scroll.documentView as? NSTextView else { return }
        let identity=text+"\u{0}"+search
        if context.coordinator.identity != identity {
            context.coordinator.identity=identity
            let output=NSMutableAttributedString(string:"");var ranges:[NSRange]=[]
            for line in ActionsLog.parse(text) {
                let start=output.length
                output.append(NSAttributedString(string:String(format:"%5d  ",line.number),attributes:[.foregroundColor:NSColor.secondaryLabelColor,.font:NSFont.monospacedSystemFont(ofSize:12,weight:.regular)]))
                for span in line.spans { output.append(NSAttributedString(string:span.text,attributes:[.foregroundColor:color(span.color),.font:NSFont.monospacedSystemFont(ofSize:12,weight:span.bold ? .bold:.regular)])) }
                output.append(NSAttributedString(string:"\n"));ranges.append(NSRange(location:start,length:output.length-start))
            }
            if !search.isEmpty { let string=output.string as NSString;var remaining=NSRange(location:0,length:string.length);while remaining.length>0 { let match=string.range(of:search,options:.caseInsensitive,range:remaining);guard match.location != NSNotFound else { break };output.addAttribute(.backgroundColor,value:NSColor.systemYellow.withAlphaComponent(0.35),range:match);remaining=NSRange(location:NSMaxRange(match),length:string.length-NSMaxRange(match)) } }
            context.coordinator.ranges=ranges;view.textStorage?.setAttributedString(output)
            let longest=output.string.components(separatedBy:"\n").map { $0.utf16.count }.max() ?? 0
            view.setFrameSize(NSSize(width:max(scroll.contentSize.width,CGFloat(longest)*7.3+24),height:max(scroll.contentSize.height,CGFloat(ranges.count)*16+24)))
            if !search.isEmpty { let match=(output.string as NSString).range(of:search,options:.caseInsensitive);if match.location != NSNotFound { view.scrollRangeToVisible(match) } }
        }
        if context.coordinator.jumpRequest != jumpRequest,context.coordinator.ranges.indices.contains(targetLine-1) { context.coordinator.jumpRequest=jumpRequest;view.scrollRangeToVisible(context.coordinator.ranges[targetLine-1]);view.setSelectedRange(context.coordinator.ranges[targetLine-1]) }
    }
    private func color(_ color:ActionsLog.Color?) -> NSColor {
        switch color { case .red:.systemRed;case .green:.systemGreen;case .yellow:.systemYellow;case .blue:.systemBlue;case .magenta:.systemPurple;case .cyan:.systemTeal;case .black,.white,nil:.labelColor }
    }
}
