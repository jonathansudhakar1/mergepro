import AppKit
import XCTest
@testable import MergeProRendering
@MainActor final class NativeCodeSurfaceTests:XCTestCase {
    func testNativeSelectionAndWrapRetainTextKit2() {
        let surface=NativeCodeSurface(frame:NSRect(x:0,y:0,width:800,height:500))
        surface.setDocument("one 🐈\ntwo\n",tokens:[],wrap:false)
        XCTAssertNotNil(surface.codeView.textLayoutManager)
        XCTAssertFalse(surface.codeView.isEditable)
        XCTAssertTrue(surface.codeView.isSelectable)
        surface.codeView.setSelectedRange(NSRange(location:4,length:2))
        surface.setDocument("one 🐈\ntwo\n",tokens:[],wrap:true)
        XCTAssertEqual(surface.codeView.selectedRange(),NSRange(location:4,length:2))
        XCTAssertEqual((surface.codeView.string as NSString).substring(with:surface.codeView.selectedRange()),"🐈")
    }
    func testSelectedFontUsesNativeFamilyAndMissingFamilyFallsBack() {
        let surface=NativeCodeSurface(frame:.zero)
        surface.setDocument("hello",tokens:[],wrap:false,fontName:"Menlo")
        XCTAssertEqual(surface.codeView.font?.familyName,"Menlo")
        surface.setDocument("hello",tokens:[],wrap:false,fontName:"no-such-font-mergepro")
        XCTAssertNotNil(surface.codeView.font)
    }
    func testInvalidTokensCannotEscapeStringAndDiffColorKeepsSelection() {
        let surface=NativeCodeSurface(frame:NSRect(x:0,y:0,width:800,height:500))
        surface.setDocument("hello",tokens:[.init(range:NSRange(location:99,length:1),scopes:["string"]),.init(range:NSRange(location:0,length:5),scopes:["keyword"])],wrap:true)
        surface.applyViewportAttributes()
        XCTAssertEqual(surface.codeView.string,"hello")
        XCTAssertNotNil(surface.codeView.textStorage?.attribute(.foregroundColor,at:0,effectiveRange:nil))
    }
    func testReplacingDocumentTextDoesNotReportProgrammaticSelection() {
        let surface=NativeCodeSurface(frame:NSRect(x:0,y:0,width:800,height:500))
        var reported:[NSRange]=[]
        surface.selectionChanged={ reported.append($0) }
        surface.setDocument("1\t  alpha\n",tokens:[],wrap:false)
        surface.setDocument("1\t  alpha\n2\t+ beta",tokens:[],wrap:false)
        XCTAssertEqual(reported,[],"installing or replacing text is not a reviewer selection")
        surface.codeView.setSelectedRange(NSRange(location:4,length:5))
        XCTAssertEqual(reported,[NSRange(location:4,length:5)])
    }
    func testRepeatedIdenticalLargeDocumentUpdatesStayCheap() {
        let source=(1...10000).map { "\($0)\t+ let value\($0) = \($0) // 🐈" }.joined(separator:"\n")
        let surface=NativeCodeSurface(frame:NSRect(x:0,y:0,width:900,height:600))
        let open=ContinuousClock().measure { surface.setDocument(source,tokens:[],wrap:false);surface.layoutSubtreeIfNeeded() }
        var edits=0
        let observer=NotificationCenter.default.addObserver(forName:NSTextStorage.didProcessEditingNotification,object:surface.codeView.textStorage,queue:nil) { _ in
            MainActor.assumeIsolated { edits += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let start=ContinuousClock.now
        for _ in 0..<20 { surface.setDocument(source,tokens:[],wrap:false) }
        let average=start.duration(to:.now)/20
        print("COMPONENT_NATIVE identical update lines=10000 average=\(average) open=\(open)")
        XCTAssertEqual(edits,0,"SwiftUI re-renders must not re-compare or restyle the whole document")
        XCTAssertLessThan(average,open/10,"An identical update costs a small fraction of opening the document")
        XCTAssertWithinPerformanceBudget(average,.milliseconds(5),"SwiftUI re-renders must not re-compare or restyle the whole document")
        XCTAssertEqual(surface.codeView.string,source)
    }
    func testDiffPrefixTabStopKeepsContentTabsOnTheSourceGrid() throws {
        let surface=NativeCodeSurface(frame:NSRect(x:0,y:0,width:900,height:300))
        let source="7\t+ \tA\n12345\t− \t\tB\n9\t  C\n"
        surface.setDocument(source,tokens:[],wrap:false,tabColumns:4,firstTabColumn:6)
        surface.codeView.frame=NSRect(x:0,y:0,width:900,height:300)
        let manager=try XCTUnwrap(surface.codeView.textLayoutManager),content=try XCTUnwrap(manager.textContentManager)
        manager.ensureLayout(for:content.documentRange)
        func x(_ offset:Int) throws -> CGFloat {
            let location=try XCTUnwrap(content.location(content.documentRange.location,offsetBy:offset))
            let fragment=try XCTUnwrap(manager.textLayoutFragment(for:location))
            let local=offset-content.offset(from:content.documentRange.location,to:fragment.rangeInElement.location)
            let line=try XCTUnwrap(fragment.textLineFragments.first { NSLocationInRange(local,$0.characterRange) })
            return line.locationForCharacter(at:local).x
        }
        let ns=source as NSString,space=(" " as NSString).size(withAttributes:[.font:try XCTUnwrap(surface.codeView.font)]).width
        func column(_ needle:String,from start:String) throws -> CGFloat { (try x(ns.range(of:needle).location)-x(ns.range(of:start).location))/space }
        XCTAssertEqual(try column("C",from:"9"),8,accuracy:0.1,"content starts after '<number><tab><sign> '")
        XCTAssertEqual(try column("A",from:"7"),12,accuracy:0.1,"one source tab is tabColumns wide")
        XCTAssertEqual(try column("B",from:"12345"),16,accuracy:0.1,"nested source tabs stay on the same grid")
        surface.setDocument("3\t+ "+String(repeating:"x",count:300),tokens:[],wrap:true,tabColumns:4,firstTabColumn:6)
        surface.codeView.frame=NSRect(x:0,y:0,width:surface.contentSize.width,height:300)
        manager.ensureLayout(for:content.documentRange)
        let lines=try XCTUnwrap(manager.textLayoutFragment(for:content.documentRange.location)?.textLineFragments)
        XCTAssertGreaterThan(lines.count,1)
        func start(_ line:NSTextLineFragment) -> CGFloat { line.typographicBounds.minX+line.locationForCharacter(at:line.characterRange.location).x }
        XCTAssertEqual((start(lines[1])-start(lines[0]))/space,8,accuracy:0.1,"wrapped diff rows continue under the content, not the line number")
    }
    func testSplitScrollSyncKeepsPanesOnTheSameRow() throws {
        let source=(1...400).map { "\($0)\t  line \($0)" }.joined(separator:"\n")
        let left=NativeCodeSurface(frame:NSRect(x:0,y:0,width:400,height:300)),right=NativeCodeSurface(frame:NSRect(x:0,y:0,width:400,height:300))
        for surface in [left,right] {
            surface.setDocument(source,tokens:[],wrap:false);surface.layoutSubtreeIfNeeded()
            let manager=try XCTUnwrap(surface.codeView.textLayoutManager);manager.ensureLayout(for:try XCTUnwrap(manager.textContentManager).documentRange)
            surface.codeView.sizeToFit();surface.layoutSubtreeIfNeeded()
        }
        let sync=CodeScrollSync();sync.add(left);sync.add(right)
        left.contentView.scroll(to:NSPoint(x:0,y:500));left.reflectScrolledClipView(left.contentView)
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        XCTAssertEqual(right.contentView.bounds.origin.y,500,accuracy:1)
        right.contentView.scroll(to:NSPoint(x:0,y:120));right.reflectScrolledClipView(right.contentView)
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        XCTAssertEqual(left.contentView.bounds.origin.y,120,accuracy:1)
    }
    func testSplitScrollSyncSkipsWrappedPanes() throws {
        let source=(1...400).map { "\($0)\t  line \($0)" }.joined(separator:"\n")
        let left=NativeCodeSurface(frame:NSRect(x:0,y:0,width:400,height:300)),right=NativeCodeSurface(frame:NSRect(x:0,y:0,width:400,height:300))
        for surface in [left,right] {
            surface.setDocument(source,tokens:[],wrap:true);surface.layoutSubtreeIfNeeded()
            let manager=try XCTUnwrap(surface.codeView.textLayoutManager);manager.ensureLayout(for:try XCTUnwrap(manager.textContentManager).documentRange)
            surface.codeView.sizeToFit();surface.layoutSubtreeIfNeeded()
        }
        let sync=CodeScrollSync();sync.add(left);sync.add(right)
        left.contentView.scroll(to:NSPoint(x:0,y:500));left.reflectScrolledClipView(left.contentView)
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        // Wrapped rows can differ in height per side, so a raw offset would land on another diff line.
        XCTAssertEqual(right.contentView.bounds.origin.y,0,accuracy:1)
    }
    func testCachedLargeDocumentComponentOpenAndScrollEvidence() {
        for count in [5000,10000] {
            let source=(1...count).map { "let value\($0) = \($0) // 🐈" }.joined(separator:"\n")
            let surface=NativeCodeSurface(frame:NSRect(x:0,y:0,width:900,height:600))
            let start=ContinuousClock.now
            surface.setDocument(source,tokens:[],wrap:false)
            surface.layoutSubtreeIfNeeded()
            let open=start.duration(to:.now)
            let scrollStart=ContinuousClock.now
            surface.codeView.scrollRangeToVisible(NSRange(location:source.utf16.count-20,length:10))
            surface.layoutSubtreeIfNeeded();surface.applyViewportAttributes()
            print("COMPONENT_NATIVE lines=\(count) open=\(open) scroll=\(scrollStart.duration(to:.now))")
            XCTAssertEqual(surface.codeView.string,source)
            XCTAssertNotNil(surface.codeView.textLayoutManager)
        }
    }
}


extension NativeCodeSurfaceTests {
    func testInitialDocumentFillsItsViewportWithoutCallerSizingTextView() {
        let surface=NativeCodeSurface(frame:NSRect(x:0,y:0,width:700,height:300))
        surface.setDocument("func greet() {\n    print(\"Hello\")\n}",tokens:[],wrap:false)
        surface.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(surface.codeView.frame.width,surface.contentSize.width)
        XCTAssertGreaterThanOrEqual(surface.codeView.frame.height,surface.contentSize.height)
    }
    func testIdenticalUpdatesDoNotInvalidateTextStorageOrViewport() {
        let surface=NativeCodeSurface(frame:NSRect(x:0,y:0,width:700,height:300))
        let token=CodeToken(range:NSRange(location:0,length:3),scopes:["keyword"])
        surface.setDocument("let value = 1",tokens:[token],wrap:false)
        var edits=0
        let observer=NotificationCenter.default.addObserver(forName:NSTextStorage.didProcessEditingNotification,object:surface.codeView.textStorage,queue:nil) { _ in MainActor.assumeIsolated { edits += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        surface.setDocument("let value = 1",tokens:[token],wrap:false)
        surface.applyViewportAttributes()
        XCTAssertEqual(edits,0,"an unchanged SwiftUI update or scroll within the same viewport must not restyle text")
    }
}

extension NativeCodeSurfaceTests {
    func testSyntaxColorsStayReadableInLightAndDarkThemes() throws {
        for mode in [NSAppearance.Name.aqua,.darkAqua] {
            let appearance=try XCTUnwrap(NSAppearance(named:mode))
            for theme in ["system","github","dracula"] {
                let surface=NativeCodeSurface(frame:NSRect(x:0,y:0,width:600,height:200));surface.appearance=appearance
                let scopes=["keyword","string","constant.numeric","entity.property"]
                let tokens=scopes.enumerated().map { CodeToken(range:NSRange(location:$0.offset,length:1),scopes:[$0.element]) }
                surface.setDocument("abcd",tokens:tokens,wrap:false,theme:theme)
                appearance.performAsCurrentDrawingAppearance {
                    do {
                    func luminance(_ color:NSColor) throws -> Double {
                        let rgb=try XCTUnwrap(color.usingColorSpace(.deviceRGB))
                        let values=[rgb.redComponent,rgb.greenComponent,rgb.blueComponent].map { value in
                            let c=Double(value);return c <= 0.04045 ? c/12.92 : pow((c+0.055)/1.055,2.4)
                        }
                        return values[0]*0.2126+values[1]*0.7152+values[2]*0.0722
                    }
                    let background=try luminance(surface.codeView.backgroundColor)
                    for index in scopes.indices {
                        let color=try XCTUnwrap(surface.codeView.textStorage?.attribute(.foregroundColor,at:index,effectiveRange:nil) as? NSColor)
                        let foreground=try luminance(color)
                        let contrast=(max(background,foreground)+0.05)/(min(background,foreground)+0.05)
                        XCTAssertGreaterThanOrEqual(contrast,4.5,"\(mode.rawValue)/\(theme)/\(scopes[index]) must remain readable")
                    }
                    } catch { XCTFail("Could not inspect native colors: \(error)") }
                }
            }
        }
    }
}

extension NativeCodeSurfaceTests {
    /// Counts text-storage edits (each one makes TextKit 2 re-lay out the edited range) while scrolling in small ticks.
    private func scrollRestyleEvidence(lines:Int,ticks:Int,step:CGFloat,split:Bool) throws -> (passes:Int,characters:Int,seconds:Double,surfaces:[NativeCodeSurface],source:NSString,tokens:[CodeToken]) {
        let source=(1...lines).map { "\($0)\t+ let value\($0) = \($0) // note" }.joined(separator:"\n") as NSString
        var tokens:[CodeToken]=[],search=NSRange(location:0,length:source.length)
        while case let found=source.range(of:"let",options:[],range:search),found.location != NSNotFound {
            tokens.append(.init(range:found,scopes:["keyword"]));search=NSRange(location:NSMaxRange(found),length:source.length-NSMaxRange(found))
        }
        let surfaces=(0..<(split ? 2 : 1)).map { _ in NativeCodeSurface(frame:NSRect(x:0,y:0,width:900,height:600)) }
        let sync=CodeScrollSync()
        for surface in surfaces {
            surface.setDocument(source as String,tokens:tokens,wrap:false);surface.layoutSubtreeIfNeeded()
            let manager=try XCTUnwrap(surface.codeView.textLayoutManager);manager.ensureLayout(for:try XCTUnwrap(manager.textContentManager).documentRange)
            surface.codeView.sizeToFit();surface.layoutSubtreeIfNeeded()
            if split { sync.add(surface) }
        }
        var passes=0,characters=0
        let observers=surfaces.map { surface in
            NotificationCenter.default.addObserver(forName:NSTextStorage.didProcessEditingNotification,object:surface.codeView.textStorage,queue:nil) { note in
                let edited=(note.object as? NSTextStorage)?.editedRange.length ?? 0
                MainActor.assumeIsolated { passes += 1;characters += edited }
            }
        }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        let lead=surfaces[0],start=ContinuousClock.now
        for tick in 1...ticks {
            lead.contentView.scroll(to:NSPoint(x:0,y:CGFloat(tick)*step));lead.reflectScrolledClipView(lead.contentView)
            for surface in surfaces { surface.layoutSubtreeIfNeeded() }
        }
        let elapsed=start.duration(to:.now)
        return (passes,characters,Double(elapsed.components.seconds)+Double(elapsed.components.attoseconds)/1e18,surfaces,source,tokens)
    }
    private func visibleColorsMatchStyledTokens(_ surface:NativeCodeSurface,tokens:[CodeToken],scope:String,file:StaticString = #filePath,line:UInt = #line) throws {
        let manager=try XCTUnwrap(surface.codeView.textLayoutManager),content=try XCTUnwrap(manager.textContentManager)
        let viewport=try XCTUnwrap(manager.textViewportLayoutController.viewportRange)
        let start=content.offset(from:content.documentRange.location,to:viewport.location),end=content.offset(from:content.documentRange.location,to:viewport.endLocation)
        let reference=NativeCodeSurface(frame:NSRect(x:0,y:0,width:200,height:100));reference.appearance=surface.appearance
        reference.setDocument("abc",tokens:[.init(range:NSRange(location:0,length:3),scopes:[scope])],wrap:false)
        let expected=try XCTUnwrap(reference.codeView.textStorage?.attribute(.foregroundColor,at:0,effectiveRange:nil) as? NSColor)
        let visible=tokens.filter { $0.range.location >= start && NSMaxRange($0.range) <= end }
        XCTAssertFalse(visible.isEmpty,file:file,line:line)
        for token in visible {
            XCTAssertEqual(surface.codeView.textStorage?.attribute(.foregroundColor,at:token.range.location,effectiveRange:nil) as? NSColor,expected,"token at \(token.range.location) in viewport \(start)..<\(end)",file:file,line:line)
        }
    }
    func testScrollTicksRestyleOnlyNearTheStyledWindowEdge() throws {
        for split in [false,true] {
            // 600 ticks of 40pt scroll past the opening 24,000 styled characters (about 2,300 lines).
            let ticks=600,evidence=try scrollRestyleEvidence(lines:4000,ticks:ticks,step:40,split:split)
            print("COMPONENT_NATIVE scroll restyle split=\(split) ticks=\(ticks) storageEdits=\(evidence.passes) restyledCharacters=\(evidence.characters) tickLoopSeconds=\(evidence.seconds)")
            for surface in evidence.surfaces { try visibleColorsMatchStyledTokens(surface,tokens:evidence.tokens,scope:"keyword") }
            XCTAssertLessThanOrEqual(evidence.passes,ticks*evidence.surfaces.count/10,"scroll ticks inside the styled window must not edit text storage")
        }
    }
    func testScrolledAwayRegionsRestyleAfterTokensChange() throws {
        let evidence=try scrollRestyleEvidence(lines:4000,ticks:200,step:30,split:false)
        let surface=evidence.surfaces[0]
        let strings=evidence.tokens.map { CodeToken(range:$0.range,scopes:["string"]) }
        surface.setDocument(evidence.source as String,tokens:strings,wrap:false);surface.layoutSubtreeIfNeeded()
        try visibleColorsMatchStyledTokens(surface,tokens:strings,scope:"string")
        surface.contentView.scroll(to:.zero);surface.reflectScrolledClipView(surface.contentView);surface.layoutSubtreeIfNeeded()
        try visibleColorsMatchStyledTokens(surface,tokens:strings,scope:"string")
    }
}
