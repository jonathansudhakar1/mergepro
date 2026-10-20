import AppKit

public struct CodeGutterMark:Sendable,Equatable {
    public enum Kind:Sendable { case lineNumber,added,removed,comment,annotation }
    public let range:NSRange
    public let kind:Kind
    public let label:String
    /// Opaque immutable content identity supplied by the canonical diff mapper, never inferred from pixels.
    public let identity:String
    public init(range:NSRange,kind:Kind,label:String,identity:String) { self.range=range;self.kind=kind;self.label=label;self.identity=identity }
}

/// One native ruler for a text surface, using TextKit 2 viewport fragments rather than per-line views.
@MainActor public final class CodeReviewGutter:NSRulerView {
    public private(set) var marks:[CodeGutterMark]=[]
    private weak var text:NSTextView?
    private var hits:[(CodeGutterMark,NSRect)]=[]
    /// Comment/annotation-only marks (diff text already shows numbers and signs) need just two narrow columns.
    private var compact=false
    private var installedMarks:[CodeGutterMark]=[]
    private var installedLength:Int?
    public var activated:((CodeGutterMark)->Void)?
    public init(scroll:NSScrollView,text:NSTextView) {
        self.text=text
        super.init(scrollView:scroll,orientation:.verticalRuler)
        clipsToBounds=true
        clientView=text;ruleThickness=96
        setAccessibilityLabel("Revision-bound code review gutter")
    }
    public required init(coder:NSCoder) { fatalError("CodeReviewGutter is programmatic") }
    public override var isFlipped:Bool { true }
    public func setMarks(_ values:[CodeGutterMark],length:Int) {
        guard values != installedMarks || length != installedLength else { return }
        installedMarks=values;installedLength=length
        marks=values.filter { $0.range.location >= 0 && $0.range.length >= 0 && $0.range.location <= length && $0.range.length <= length-$0.range.location }.sorted { $0.range.location < $1.range.location }
        compact = !marks.contains { [.lineNumber,.added,.removed].contains($0.kind) }
        let sourceLines = !marks.isEmpty && marks.allSatisfy { $0.kind == .lineNumber && $0.identity.hasPrefix("source:") }
        setAccessibilityLabel(sourceLines ? "Source line numbers" : "Revision-bound code review gutter")
        let thickness:CGFloat=sourceLines ? max(48,CGFloat(marks.last?.label.count ?? 1)*7+20) : compact ? 36 : 96
        if ruleThickness != thickness { ruleThickness=thickness;scrollView?.tile() }
        needsDisplay=true
    }
    public func activate(_ mark:CodeGutterMark) {
        guard marks.contains(mark),let text else { return }
        text.setSelectedRange(mark.range);text.scrollRangeToVisible(mark.range);activated?(mark)
    }
    public override func mouseDown(with event:NSEvent) {
        let point=convert(event.locationInWindow,from:nil)
        if let hit=hits.last(where:{ $0.1.contains(point) }) { activate(hit.0) }
    }
    public override func drawHashMarksAndLabels(in rect:NSRect) {
        NSGraphicsContext.saveGraphicsState();defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect:bounds).addClip()
        NSColor.windowBackgroundColor.setFill();rect.intersection(bounds).fill();hits=[]
        for value in visibleMarkerFrames() { draw(value.mark,in:value.frame) }
        setAccessibilityValue(hits.map { $0.0.label }.joined(separator:"; "))
    }
    public func visibleMarkerFrames() -> [(mark:CodeGutterMark,frame:NSRect)] {
        guard let text,let manager=text.textLayoutManager,let content=manager.textContentManager else { return [] }
        var result:[(mark:CodeGutterMark,frame:NSRect)]=[]
        let visible=text.visibleRect
        let start=manager.textViewportLayoutController.viewportRange?.location ?? content.documentRange.location
        var rendered=Set<Int>()
        manager.enumerateTextLayoutFragments(from:start,options:[]) { fragment in
            if fragment.layoutFragmentFrame.minY > visible.maxY { return false }
            let element=fragment.textElement?.elementRange?.location ?? fragment.rangeInElement.location
            let offset=content.offset(from:content.documentRange.location,to:element)
            for line in fragment.textLineFragments {
                let range=NSRange(location:offset+line.characterRange.location,length:line.characterRange.length)
                // Binary-search the sorted marker list; a marker draws only on its first visual line.
                var lo=0,hi=self.marks.count
                while lo < hi { let mid=(lo+hi)/2;if self.marks[mid].range.location < range.location { lo=mid+1 } else { hi=mid } }
                var index=lo
                while index < self.marks.count,(self.marks[index].range.location < NSMaxRange(range) || (range.length == 0 && self.marks[index].range.location == range.location)) {
                    if rendered.insert(index).inserted {
                        let mark=self.marks[index]
                        let y=self.convert(NSPoint(x:0,y:fragment.layoutFragmentFrame.minY+line.typographicBounds.minY+text.textContainerOrigin.y),from:text).y
                        let frame=NSRect(x:0,y:y,width:self.ruleThickness,height:max(16,line.typographicBounds.height))
                        result.append((mark,frame))
                    }
                    index += 1
                }
            }
            return true
        }
        return result
    }
    private func draw(_ mark:CodeGutterMark,in frame:NSRect) {
        let label:String,color:NSColor,x:CGFloat,width:CGFloat
        switch mark.kind {
        case .lineNumber:label=mark.label;color = .secondaryLabelColor;x=7;width=min(49,ruleThickness-14)
        case .added:label="+";color = .systemGreen;x=1;width=8
        case .removed:label="−";color = .systemRed;x=1;width=8
        case .comment:label="●";color = .systemBlue;x=compact ? 3 : 61;width=15
        case .annotation:label="▲";color = .systemOrange;x=compact ? 19 : 79;width=15
        }
        let rectangle=NSRect(x:x,y:frame.minY,width:width,height:frame.height)
        let paragraph=NSMutableParagraphStyle();paragraph.alignment=mark.kind == .lineNumber ? .right : .center
        (label as NSString).draw(in:rectangle,withAttributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:10,weight:.regular),.foregroundColor:color,.paragraphStyle:paragraph])
        hits.append((mark,rectangle))
    }
}
