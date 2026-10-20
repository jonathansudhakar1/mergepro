import AppKit

/// Room below one line for a caller's view, such as a review thread, or empty room mirroring a split diff's other
/// pane. The room is paragraph spacing after the line, so no characters are inserted: selection, copy, token ranges
/// and gutter marks keep their offsets. A document's final line has room only when the text ends with a newline.
public struct CodeInlineAccessory {
    public let identity:String
    /// Any UTF-16 offset in the line the room follows. Accessories on one line stack in the given order.
    public let location:Int
    public let height:CGFloat
    /// Placed in the room across the visible text width and scrolled with the text; nil reserves the room only.
    public let view:NSView?
    public init(identity:String,location:Int,height:CGFloat,view:NSView? = nil) { self.identity=identity;self.location=location;self.height=height;self.view=view }
}
/// `.document` is the text view's flipped space, unchanged by scrolling; `.surface` is the scroll view's own space,
/// so the same line moves up as the reviewer scrolls down.
public enum CodeGeometrySpace:Sendable { case document,surface }

/// TextKit 2 owns viewport layout, selection, copy and accessibility. Token colors are
/// applied only around its current viewport, not by constructing one view per line.
@MainActor public final class NativeCodeSurface:NSScrollView,NSTextViewDelegate {
    /// Characters styled past each viewport edge, and how near the viewport may come to the styled window's
    /// edge before the window grows. Scroll ticks inside the window leave text storage, and so layout, alone.
    static let styleOverscan=4000,styleMargin=1500
    public let codeView:NSTextView=ViewportReportingTextView(usingTextLayoutManager:true)
    public private(set) lazy var reviewGutter=CodeReviewGutter(scroll:self,text:codeView)
    private var tokens:[CodeToken]=[]
    private var observation: NSObjectProtocol?
    /// Last installed text; comparing Swift storage avoids re-reading the bridged text view string on every update.
    private var documentText=""
    private var documentLength=0
    private var tokenIndex=CodeTokenIndex([],length:0)
    /// One contiguous range whose colors match the installed tokens, theme and appearance; nil after any of them change.
    private var styledViewport:NSRange?
    private struct Appearance:Equatable {
        let wrap:Bool;let fontSize:CGFloat;let fontName:String;let ligatures:Bool;let theme:String;let tabColumns:Int;let firstTabColumn:Int?
    }
    private var installedAppearance:Appearance?
    private var appliedLigatures:Bool?
    /// Whether lines wrap; split-pane scroll sync only applies to unwrapped panes.
    public private(set) var wraps=false
    private var replacingDocument=false
    public var selectionChanged:((NSRange)->Void)?
    /// Called after the clip view scrolls (used to keep split diff panes aligned).
    public var scrolled:(() -> Void)?
    /// A click on a gutter mark (comment, annotation, line number), after the gutter selects and reveals its range.
    public var gutterMarkActivated:((CodeGutterMark) -> Void)? {
        get { reviewGutter.activated }
        set { reviewGutter.activated=newValue }
    }
    public var theme="system"
    /// Installed inline accessories, in the caller's order; see `setInlineAccessories`.
    public private(set) var inlineAccessories:[CodeInlineAccessory]=[]
    /// Paragraph start offset → extra paragraph spacing currently in text storage for inline accessories.
    private var installedRoom:[Int:CGFloat]=[:]
    private let accessoryLayer=InlineAccessoryLayer()
    /// Last horizontal origin accessories were pinned to, so vertical scroll ticks move nothing.
    private var accessoryOriginX:CGFloat?
    /// Set while the surface scrolls itself to keep its top line in place; that isn't a reviewer scroll to mirror.
    private var anchoringScroll=false
    /// Earliest line whose room changed since TextKit last laid out what follows it: later lines may still sit at their
    /// old positions until a viewport pass reaches them, so geometry queries lay out from here first.
    private var staleFrom:Int?
    public override init(frame:NSRect) {
        super.init(frame:frame)
        hasVerticalScroller=true;hasHorizontalScroller=true;autohidesScrollers=true
        codeView.isEditable=false;codeView.isSelectable=true;codeView.isRichText=false;codeView.allowsUndo=false
        codeView.isAutomaticLinkDetectionEnabled=false;codeView.isAutomaticDataDetectionEnabled=false
        codeView.textContainerInset=NSSize(width:12,height:10);codeView.delegate=self
        codeView.setAccessibilityIdentifier("codeText");codeView.setAccessibilityLabel("Source code")
        codeView.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        documentView=codeView
        verticalRulerView=reviewGutter;hasVerticalRuler=true
        contentView.postsBoundsChangedNotifications=true
        observation=NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:contentView,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyViewportAttributes();self.pinAccessoriesHorizontally()
                // A split pane anchors itself to the same room change as its partner, so the offset isn't mirrored.
                if !self.anchoringScroll { self.scrolled?() }
            }
        }
        // The viewport range is only current after the text view's own layout pass; a jump (Home, Jump to Line,
        // scroller drag) would otherwise stay uncolored until the next scroll tick. Inline accessories follow
        // the fragments TextKit just laid out (estimated offscreen heights become exact as they scroll in).
        (codeView as? ViewportReportingTextView)?.didLayout={ [weak self] in self?.applyViewportAttributes();self?.layoutInlineAccessories(ensuringLayout:false) }
        accessoryLayer.autoresizingMask=[.width,.height]
        (codeView as? ViewportReportingTextView)?.accessoryLayer=accessoryLayer
    }
    public required init?(coder:NSCoder) { nil }
    isolated deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    /// `firstTabColumn` places the leading tab stop for diff rows shaped "<number>\t<sign> ". Source tabs after the
    /// sign stay on a `tabColumns` grid measured from the content column, and wrapped rows indent past the sign.
    public func setDocument(_ text:String,tokens:[CodeToken],wrap:Bool,fontSize:CGFloat = 12,fontName:String = "",ligatures:Bool = false,theme:String = "system",gutterMarks:[CodeGutterMark] = [],tabColumns:Int = 4,firstTabColumn:Int? = nil) {
        let changed=documentText != text || codeView.textStorage?.length != documentLength
        if changed { documentLength=text.utf16.count }
        let appearance=Appearance(wrap:wrap,fontSize:fontSize,fontName:fontName,ligatures:ligatures,theme:theme,tabColumns:tabColumns,firstTabColumn:firstTabColumn)
        let styleChanged=installedAppearance != appearance
        let tokensChanged=self.tokens != tokens
        reviewGutter.setMarks(gutterMarks,length:documentLength);rulersVisible = !gutterMarks.isEmpty
        guard changed || styleChanged || tokensChanged else { return }
        installedAppearance=appearance;self.theme=theme
        if changed || tokensChanged { self.tokens=tokens;tokenIndex=CodeTokenIndex(tokens,length:documentLength) }
        styledViewport=nil
        hasHorizontalScroller = !wrap;wraps=wrap
        codeView.isHorizontallyResizable = !wrap;codeView.isVerticallyResizable=true
        codeView.autoresizingMask = wrap ? [.width] : []
        codeView.textContainer?.widthTracksTextView=wrap
        resizeCodeViewport()
        codeView.textContainer?.containerSize=NSSize(width:wrap ? max(contentSize.width,1) : 1_000_000,height:CGFloat.greatestFiniteMagnitude)
        let selectedFont=NSFont(name:fontName,size:min(28,max(9,fontSize))) ?? .monospacedSystemFont(ofSize:min(28,max(9,fontSize)),weight:.regular)
        if codeView.font != selectedFont { codeView.font=selectedFont }
        codeView.textColor = .textColor;codeView.backgroundColor = .textBackgroundColor
        // Installing text moves the caret; that is not a reviewer selection, so it is not reported.
        if changed { replacingDocument=true;codeView.string=text;documentText=text;replacingDocument=false }
        let font=codeView.font ?? .monospacedSystemFont(ofSize:12,weight:.regular),space=(" " as NSString).size(withAttributes:[.font:font]).width
        let paragraph=NSMutableParagraphStyle();paragraph.lineSpacing=2
        // Default stops continue from the last explicit stop, so one stop on the content grid anchors the rest.
        let columns=max(1,tabColumns),content=firstTabColumn.map { max(1,$0)+2 }
        paragraph.tabStops=content.map { [NSTextTab(textAlignment:.left,location:space*CGFloat($0-2)),NSTextTab(textAlignment:.left,location:space*CGFloat($0+columns))] } ?? []
        paragraph.defaultTabInterval=space*CGFloat(columns)
        if let content { paragraph.headIndent=space*CGFloat(content) }
        if changed || codeView.defaultParagraphStyle != paragraph {
            codeView.defaultParagraphStyle=paragraph
            codeView.textStorage?.addAttribute(.paragraphStyle,value:paragraph,range:NSRange(location:0,length:documentLength))
            // The whole-document style replaced any inline room. Same text: the installed accessories get it back;
            // new text: their offsets belong to the old text, so they wait for the caller's next `setInlineAccessories`.
            installedRoom=[:];staleFrom=nil
            if !changed { applyInlineRoom() }
        }
        if changed || appliedLigatures != ligatures {
            appliedLigatures=ligatures
            codeView.textStorage?.addAttribute(.ligature,value:ligatures ? 1 : 0,range:NSRange(location:0,length:documentLength))
        }
        applyViewportAttributes()
    }
    public func applyViewportAttributes() {
        guard let storage=codeView.textStorage else { return }
        let length=storage.length
        // Before the first layout there is no viewport; the opening screenful is styled directly.
        var window=NSRange(location:0,length:min(length,24000)),needed=window
        if let manager=codeView.textLayoutManager,let viewport=manager.textViewportLayoutController.viewportRange,let content=manager.textContentManager {
            let start=content.offset(from:content.documentRange.location,to:viewport.location)
            let end=content.offset(from:content.documentRange.location,to:viewport.endLocation)
            if start >= 0,end >= start,end <= length {
                window=NSRange(location:max(0,start-Self.styleOverscan),length:min(length,end+Self.styleOverscan)-max(0,start-Self.styleOverscan))
                needed=NSRange(location:max(0,start-Self.styleMargin),length:min(length,end+Self.styleMargin)-max(0,start-Self.styleMargin))
            }
        }
        reviewGutter.needsDisplay=true
        guard window.location >= 0,window.length >= 0,NSMaxRange(window) <= length else { return }
        // Hysteresis: restyle only once the viewport nears the styled window's edge, and then only the newly exposed text.
        if let styled=styledViewport,styled.location <= needed.location,NSMaxRange(styled) >= NSMaxRange(needed) { return }
        var pieces=[window]
        if let styled=styledViewport,styled.location <= NSMaxRange(window),window.location <= NSMaxRange(styled) {
            pieces=[NSRange(location:window.location,length:max(0,styled.location-window.location)),
                    NSRange(location:NSMaxRange(styled),length:max(0,NSMaxRange(window)-NSMaxRange(styled)))]
            styledViewport=NSUnionRange(styled,window)
        } else { styledViewport=window }
        let dark=effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua
        // Separate edits keep TextKit 2 from invalidating the on-screen text between two offscreen pieces.
        for piece in pieces where piece.length > 0 { style(piece,in:storage,dark:dark) }
    }
    private func style(_ visible:NSRange,in storage:NSTextStorage,dark:Bool) {
        storage.beginEditing()
        storage.addAttribute(.foregroundColor,value:NSColor.textColor,range:visible)
        storage.removeAttribute(.backgroundColor,range:visible)
        for token in tokenIndex.intersecting(visible) {
            let scope=token.scopes.last ?? ""
            if scope == "diff.lineNumber" || scope.hasPrefix("diff.sign.") || scope == "diff.hunk" || scope == "diff.meta" {
                let color:NSColor=switch scope { case "diff.sign.added": .systemGreen;case "diff.sign.removed": .systemRed;case "diff.hunk": .systemCyan;case "diff.meta": .secondaryLabelColor;default: .tertiaryLabelColor }
                storage.addAttribute(.foregroundColor,value:color,range:NSIntersectionRange(token.range,visible));continue
            }
            if scope.hasPrefix("diff.") {
                let color:NSColor=scope == "diff.added" ? .systemGreen : scope == "diff.removed" ? .systemRed : .systemYellow
                storage.addAttribute(.backgroundColor,value:color.withAlphaComponent(scope == "diff.word" ? 0.35 : 0.12),range:NSIntersectionRange(token.range,visible));continue
            }
            let color:NSColor
            if scope.contains("comment") { color = .secondaryLabelColor }
            else if scope.contains("string") { color = syntaxColor(dark ? (theme == "dracula" ? 0xF1FA8C : 0xFF9A90) : (theme == "dracula" ? 0x7B5500 : 0xA31515)) }
            else if scope.contains("keyword") { color = syntaxColor(dark ? (theme == "github" ? 0xFF7B72 : 0xBD93F9) : (theme == "github" ? 0xA31515 : 0x7A2CBB)) }
            else if scope.contains("number") || scope.contains("numeric") || scope.contains("constant") { color = syntaxColor(dark ? 0x8AB4F8 : 0x1751A6) }
            else if scope.contains("type") || scope.contains("function") || scope.contains("entity") { color = syntaxColor(dark ? 0x8BE9FD : 0x086B70) }
            else { continue }
            storage.addAttribute(.foregroundColor,value:color,range:NSIntersectionRange(token.range,visible))
        }
        storage.endEditing()
    }
    // Saturated light-mode colors and brighter dark-mode colors keep 12pt source
    // readable against the system text background, including Dracula's yellow strings.
    private func syntaxColor(_ rgb:Int) -> NSColor {
        NSColor(srgbRed:CGFloat((rgb >> 16)&255)/255,green:CGFloat((rgb >> 8)&255)/255,blue:CGFloat(rgb&255)/255,alpha:1)
    }

    // MARK: Line geometry and inline accessories

    /// The full-width row of the line containing `location`, from its top (leading line spacing included) through every
    /// wrapped visual line, but never the inline room below it. Nil for offsets outside the document or a final empty
    /// line. Layout runs for that line (and from any changed room above it) if needed.
    public func lineRect(containing location:Int,in space:CodeGeometrySpace = .document) -> NSRect? {
        guard let geometry=lineGeometry(at:location,ensuringLayout:true) else { return nil }
        let row=NSRect(x:0,y:geometry.text.minY,width:max(codeView.bounds.width,geometry.text.maxX),height:geometry.text.height)
        return space == .document ? row : convert(row,from:codeView)
    }
    /// Where an installed accessory's room is (its view's frame when it has one).
    public func inlineAccessoryRect(_ identity:String,in space:CodeGeometrySpace = .document) -> NSRect? {
        guard let index=inlineAccessories.firstIndex(where:{ $0.identity == identity }),let rect=accessoryFrames(ensuringLayout:true)[index] else { return nil }
        return space == .document ? rect : convert(rect,from:codeView)
    }
    /// Replaces the inline accessories. Unchanged room leaves text storage (and so layout) alone; views are reused
    /// when the caller passes the same instances, so their state survives updates.
    public func setInlineAccessories(_ values:[CodeInlineAccessory]) {
        let valid=values.filter { $0.location >= 0 && $0.location <= documentLength && $0.height.isFinite && $0.height >= 0 }
        // SwiftUI updates repeat the same accessories; they must not re-run layout queries for every line.
        func same(_ a:CodeInlineAccessory,_ b:CodeInlineAccessory) -> Bool { a.identity == b.identity && a.location == b.location && a.height == b.height && a.view === b.view }
        if valid.count == inlineAccessories.count,zip(valid,inlineAccessories).allSatisfy(same),!installedRoom.isEmpty || valid.allSatisfy({ $0.height == 0 }) { return }
        inlineAccessories=valid
        let kept=Set(inlineAccessories.compactMap { $0.view.map(ObjectIdentifier.init) })
        for view in accessoryLayer.subviews where !kept.contains(ObjectIdentifier(view)) { view.removeFromSuperview() }
        for view in inlineAccessories.compactMap(\.view) where view.superview !== accessoryLayer { view.isHidden=true;accessoryLayer.addSubview(view) }
        if inlineAccessories.isEmpty { accessoryLayer.removeFromSuperview() }
        else if codeView.subviews.last !== accessoryLayer { accessoryLayer.frame=codeView.bounds;codeView.addSubview(accessoryLayer,positioned:.above,relativeTo:nil) }
        applyInlineRoom()
        accessoryOriginX=nil
        layoutInlineAccessories(ensuringLayout:true)
    }
    /// Paragraph spacing after each accessory's line; one storage edit per changed line keeps relayout local. Room that
    /// changes above the top visible line (a thread measured or expanded offscreen) doesn't move what the reviewer sees.
    private func applyInlineRoom() {
        guard let storage=codeView.textStorage else { return }
        let text=storage.string as NSString,length=text.length
        var wanted:[Int:CGFloat]=[:]
        for value in inlineAccessories where value.height > 0 {
            wanted[text.paragraphRange(for:NSRange(location:min(value.location,length),length:0)).location,default:0] += value.height.rounded(.up)
        }
        guard wanted != installedRoom else { return }
        let anchor=topVisibleLine()
        let base=codeView.defaultParagraphStyle ?? .default
        func set(_ style:NSParagraphStyle,at start:Int) {
            guard start < length || length == 0 else { return }
            let range=text.paragraphRange(for:NSRange(location:min(start,length),length:0))
            guard range.length > 0 else { return }
            storage.beginEditing();storage.addAttribute(.paragraphStyle,value:style,range:range);storage.endEditing()
        }
        let edited=Set(installedRoom.keys).symmetricDifference(wanted.keys).union(wanted.keys.filter { installedRoom[$0] != wanted[$0] })
        if let first=edited.min() { staleFrom=min(staleFrom ?? first,first) }
        for start in installedRoom.keys where wanted[start] == nil { set(base,at:start) }
        for (start,height) in wanted where installedRoom[start] != height {
            let style=(base.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.paragraphSpacing=base.paragraphSpacing+height
            set(style,at:start)
        }
        installedRoom=wanted
        if let anchor { keepInPlace(anchor) }
    }
    /// The line at the top of the visible text and where it is, when the text is scrolled away from its start.
    private func topVisibleLine() -> (location:Int,y:CGFloat)? {
        let visible=contentView.documentVisibleRect
        guard visible.minY > 0.5,let manager=codeView.textLayoutManager,let content=manager.textContentManager,
              let fragment=manager.textLayoutFragment(for:CGPoint(x:0,y:max(0,visible.minY-codeView.textContainerOrigin.y))) else { return nil }
        let location=content.offset(from:content.documentRange.location,to:fragment.rangeInElement.location)
        guard let line=lineGeometry(at:location,ensuringLayout:true) else { return nil }
        return (location,line.text.minY)
    }
    private func keepInPlace(_ anchor:(location:Int,y:CGFloat)) {
        layoutSubtreeIfNeeded()
        guard let moved=lineGeometry(at:anchor.location,ensuringLayout:true)?.text.minY,abs(moved-anchor.y) > 0.5 else { return }
        let clip=contentView,origin=NSPoint(x:clip.bounds.minX,y:max(0,clip.bounds.minY+moved-anchor.y))
        anchoringScroll=true;defer { anchoringScroll=false }
        clip.scroll(to:clip.constrainBoundsRect(NSRect(origin:origin,size:clip.bounds.size)).origin);reflectScrolledClipView(clip)
    }
    /// Text extent (all visual lines) and full fragment frame (including any room) of the line at `location`, in document space.
    private func lineGeometry(at location:Int,ensuringLayout:Bool) -> (text:NSRect,fragment:NSRect,paragraph:Int)? {
        guard location >= 0,location <= documentLength,let manager=codeView.textLayoutManager,let content=manager.textContentManager,
              let textLocation=content.location(content.documentRange.location,offsetBy:location),
              var fragment=manager.textLayoutFragment(for:textLocation) else { return nil }
        if ensuringLayout {
            if let stale=staleFrom,stale <= location,let from=content.location(content.documentRange.location,offsetBy:stale),
               let range=NSTextRange(location:from,end:fragment.rangeInElement.endLocation) {
                // Lines after an edited room move only once TextKit lays out from that room down to them.
                manager.ensureLayout(for:range)
                let end=content.offset(from:content.documentRange.location,to:fragment.rangeInElement.endLocation)
                staleFrom=end < documentLength ? end : nil
            } else if fragment.state != .layoutAvailable { manager.ensureLayout(for:fragment.rangeInElement) }
            // An edited line gets a new fragment when it is laid out again.
            if let current=manager.textLayoutFragment(for:textLocation) { fragment=current }
        }
        let lines=fragment.textLineFragments
        // The empty line after a final newline has no row of its own to report.
        guard !lines.isEmpty,location < documentLength || !(documentLength == 0 || documentText.hasSuffix("\n")) else { return nil }
        let frame=fragment.layoutFragmentFrame,origin=codeView.textContainerOrigin
        // From the fragment's top (leading line spacing included, so empty placeholder rows match their neighbours)
        // to the last visual line's bottom, where any inline room begins.
        let bounds=lines.reduce(NSRect.null) { $0.union($1.typographicBounds) }
        let text=NSRect(x:frame.minX+origin.x+bounds.minX,y:frame.minY+origin.y,width:bounds.width,height:bounds.maxY)
        let paragraph=content.offset(from:content.documentRange.location,to:fragment.rangeInElement.location)
        return (text,frame.offsetBy(dx:origin.x,dy:origin.y),paragraph)
    }
    /// Each accessory's room in document space, stacked in order below its line and spanning the visible text width.
    private func accessoryFrames(ensuringLayout:Bool) -> [NSRect?] {
        let visible=contentView.documentVisibleRect,inset=codeView.textContainerInset.width
        let x=(wraps ? 0 : visible.minX)+inset,width=max(120,(wraps ? codeView.bounds.width : visible.width)-inset*2)
        var used:[Int:CGFloat]=[:]
        return inlineAccessories.map { value in
            guard let line=lineGeometry(at:value.location,ensuringLayout:ensuringLayout) else { return nil }
            let offset=used[line.paragraph,default:0];used[line.paragraph]=offset+value.height.rounded(.up)
            return NSRect(x:x,y:line.text.maxY+offset,width:width,height:value.height)
        }
    }
    /// Positions accessory views in their rooms. Lines without layout keep their view's last frame (hidden until first placed).
    private func layoutInlineAccessories(ensuringLayout:Bool) {
        guard !inlineAccessories.isEmpty else { return }
        if accessoryLayer.frame != codeView.bounds { accessoryLayer.frame=codeView.bounds }
        for (value,frame) in zip(inlineAccessories,accessoryFrames(ensuringLayout:ensuringLayout)) {
            guard let view=value.view,let frame else { continue }
            if view.frame != frame { view.frame=frame }
            if view.isHidden { view.isHidden=false }
        }
        accessoryOriginX=contentView.documentVisibleRect.minX
    }
    /// Unwrapped text scrolls sideways under its accessories; they stay across the visible width instead.
    private func pinAccessoriesHorizontally() {
        guard !inlineAccessories.isEmpty,!wraps,accessoryOriginX != contentView.documentVisibleRect.minX else { return }
        let x=contentView.documentVisibleRect.minX+codeView.textContainerInset.width
        for view in inlineAccessories.compactMap(\.view) where view.frame.minX != x { view.setFrameOrigin(NSPoint(x:x,y:view.frame.minY)) }
        accessoryOriginX=contentView.documentVisibleRect.minX
    }
    public func textViewDidChangeSelection(_ notification:Notification) { guard !replacingDocument else { return };selectionChanged?(codeView.selectedRange()) }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance();styledViewport=nil;applyViewportAttributes() }
    public override func layout() { super.layout();resizeCodeViewport();accessoryOriginX=nil;layoutInlineAccessories(ensuringLayout:false) }
    private func resizeCodeViewport() {
        let size=contentSize
        codeView.minSize=NSSize(width:max(1,size.width),height:max(1,size.height))
        var frame=codeView.frame
        frame.size.width=wraps ? max(1,size.width) : max(frame.width,size.width)
        frame.size.height=max(frame.height,size.height)
        if codeView.frame != frame { codeView.frame=frame }
    }
}

/// Reports the end of its layout pass, when TextKit 2's viewport range describes what is on screen.
@MainActor final class ViewportReportingTextView:NSTextView {
    var didLayout:(() -> Void)?
    weak var accessoryLayer:NSView?
    override func layout() { super.layout();didLayout?() }
    /// Inline accessories (e.g. review threads) are reachable by VoiceOver after the text they follow.
    override func accessibilityChildren() -> [Any]? {
        let own=super.accessibilityChildren() ?? []
        guard let accessoryLayer,accessoryLayer.superview === self else { return own }
        let known=Set(own.compactMap { ($0 as AnyObject?).map(ObjectIdentifier.init) })
        return own+accessoryLayer.subviews.filter { !$0.isHidden && !known.contains(ObjectIdentifier($0)) }
    }
}
/// Holds inline accessory views above TextKit's own subviews; clicks outside an accessory reach the text.
@MainActor final class InlineAccessoryLayer:NSView {
    override var isFlipped:Bool { true }
    override func hitTest(_ point:NSPoint) -> NSView? {
        let hit=super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Split diff panes carry one row per diff line (placeholders included), so a vertical offset maps directly across sides.
@MainActor public final class CodeScrollSync {
    private let surfaces=NSHashTable<NativeCodeSurface>.weakObjects()
    private var following=false
    public init() {}
    public func add(_ surface:NativeCodeSurface) {
        surfaces.add(surface)
        surface.scrolled={ [weak self,weak surface] in if let surface { self?.follow(surface) } }
    }
    private func follow(_ source:NativeCodeSurface) {
        // Wrapped rows differ in height across sides, so a raw offset no longer maps to the same diff line.
        guard !following,!source.wraps else { return };following=true;defer { following=false }
        let y=source.contentView.bounds.origin.y
        for other in surfaces.allObjects where other !== source && !other.wraps {
            let clip=other.contentView
            let target=clip.constrainBoundsRect(NSRect(origin:NSPoint(x:clip.bounds.origin.x,y:y),size:clip.bounds.size)).origin
            guard abs(clip.bounds.origin.y-target.y) > 0.5 else { continue }
            clip.scroll(to:target);other.reflectScrolledClipView(clip)
        }
    }
}
