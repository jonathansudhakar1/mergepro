import AppKit
import XCTest
@testable import MergeProRendering

/// Line rects and inline room (review threads inside the diff) for unified, wrapped and split panes.
@MainActor final class CodeLineGeometryTests:XCTestCase {
    private func diffRows(_ count:Int,long:Set<Int> = []) -> String {
        (1...count).map { "\($0)\t+ "+(long.contains($0) ? String(repeating:"wide 🐈 ",count:60) : "line \($0)")+"\n" }.joined()
    }
    private func surface(_ text:String,wrap:Bool,width:CGFloat = 600,height:CGFloat = 400) throws -> NativeCodeSurface {
        let surface=NativeCodeSurface(frame:NSRect(x:0,y:0,width:width,height:height))
        surface.setDocument(text,tokens:[],wrap:wrap,firstTabColumn:6);surface.layoutSubtreeIfNeeded()
        let manager=try XCTUnwrap(surface.codeView.textLayoutManager)
        manager.ensureLayout(for:try XCTUnwrap(manager.textContentManager).documentRange)
        surface.codeView.sizeToFit();surface.layoutSubtreeIfNeeded()
        return surface
    }
    private func offset(_ text:String,of needle:String) -> Int { (text as NSString).range(of:needle).location }

    func testLineRectsAreRowsInDocumentOrderAndRejectInvalidOffsets() throws {
        let text=diffRows(40),view=try surface(text,wrap:false)
        let first=try XCTUnwrap(view.lineRect(containing:offset(text,of:"line 1\n")))
        let second=try XCTUnwrap(view.lineRect(containing:offset(text,of:"line 2\n")))
        let third=try XCTUnwrap(view.lineRect(containing:offset(text,of:"line 3\n")))
        let tenth=try XCTUnwrap(view.lineRect(containing:offset(text,of:"line 10\n")))
        XCTAssertEqual(second.height,third.height,accuracy:0.5)
        XCTAssertLessThanOrEqual(first.height,second.height,"the first row has no leading line spacing")
        XCTAssertEqual(second.minY,first.maxY,accuracy:0.5,"rows tile without gaps or overlap")
        XCTAssertEqual(third.minY,second.maxY,accuracy:0.5)
        XCTAssertEqual(tenth.minY-second.minY,(third.minY-second.minY)*8,accuracy:1,"unwrapped rows share one pitch")
        XCTAssertGreaterThanOrEqual(first.width,view.codeView.bounds.width,"a row spans the text view")
        // Any offset in the row (number, sign, content, line end) maps to the same row.
        let row=offset(text,of:"7\t+ line 7")
        XCTAssertEqual(view.lineRect(containing:row),view.lineRect(containing:row+5))
        XCTAssertNil(view.lineRect(containing:-1))
        XCTAssertNil(view.lineRect(containing:text.utf16.count+1))
        XCTAssertNil(view.lineRect(containing:text.utf16.count),"the empty line after the final newline is not a row")
    }
    func testWrappedLineRectCoversEveryVisualLine() throws {
        let text=diffRows(6,long:[3]),view=try surface(text,wrap:true,width:320)
        let short=try XCTUnwrap(view.lineRect(containing:offset(text,of:"line 2\n")))
        let wrapped=try XCTUnwrap(view.lineRect(containing:offset(text,of:"3\t+ wide")))
        let next=try XCTUnwrap(view.lineRect(containing:offset(text,of:"line 4\n")))
        XCTAssertGreaterThan(wrapped.height,short.height*3,"one diff row wraps onto several visual lines")
        XCTAssertGreaterThanOrEqual(next.minY,wrapped.maxY-0.5,"the following row starts below the last wrapped line")
        // An offset deep inside the wrapped row reports the whole row, not its own visual line.
        XCTAssertEqual(view.lineRect(containing:offset(text,of:"3\t+ wide")+200),wrapped)
    }
    func testSurfaceSpaceLineRectsFollowScrollingWhileDocumentRectsStayPut() throws {
        let text=diffRows(400),view=try surface(text,wrap:false)
        let location=offset(text,of:"line 50\n")
        let document=try XCTUnwrap(view.lineRect(containing:location))
        let before=try XCTUnwrap(view.lineRect(containing:location,in:.surface))
        view.contentView.scroll(to:NSPoint(x:0,y:700));view.reflectScrolledClipView(view.contentView);view.layoutSubtreeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(view.lineRect(containing:location)),document,"document space ignores scrolling")
        let after=try XCTUnwrap(view.lineRect(containing:location,in:.surface))
        XCTAssertEqual(before.minY-after.minY,700,accuracy:1,"surface space moves with the clip view")
        XCTAssertTrue(view.bounds.intersects(after),"the scrolled-to row is on screen")
    }
    func testInlineRoomSitsBelowItsLineWithoutChangingTextOrOffsets() throws {
        let text=diffRows(30),view=try surface(text,wrap:false)
        let anchor=offset(text,of:"line 5\n"),below=offset(text,of:"line 6\n"),far=offset(text,of:"line 20\n")
        let line=try XCTUnwrap(view.lineRect(containing:anchor)),next=try XCTUnwrap(view.lineRect(containing:below)),farBefore=try XCTUnwrap(view.lineRect(containing:far))
        let bubble=NSButton(title:"Reply",target:nil,action:nil)
        view.setInlineAccessories([.init(identity:"thread",location:anchor,height:120,view:bubble)])
        view.layoutSubtreeIfNeeded()
        let room=try XCTUnwrap(view.inlineAccessoryRect("thread"))
        XCTAssertEqual(room.minY,line.maxY,accuracy:0.5,"room starts right below its line")
        XCTAssertEqual(room.height,120)
        XCTAssertEqual(try XCTUnwrap(view.lineRect(containing:anchor)),line,"the commented line itself doesn't move")
        XCTAssertEqual(try XCTUnwrap(view.lineRect(containing:below)).minY-next.minY,120,accuracy:0.5,"later rows move down by the room")
        XCTAssertEqual(try XCTUnwrap(view.lineRect(containing:far)).minY-farBefore.minY,120,accuracy:0.5)
        XCTAssertEqual(bubble.frame,room,"the view fills its room")
        XCTAssertFalse(bubble.isHidden)
        XCTAssertEqual(view.codeView.string,text,"no characters are inserted")
        // Clicks in the room reach the accessory; clicks on code still reach the text view.
        let clip=view.contentView
        let hit=view.codeView.hitTest(clip.convert(NSPoint(x:room.midX,y:room.midY),from:view.codeView))
        XCTAssertTrue(hit === bubble || hit?.isDescendant(of:bubble) == true,"\(String(describing:hit))")
        XCTAssertTrue(view.codeView.hitTest(clip.convert(NSPoint(x:line.minX+40,y:line.midY),from:view.codeView)) === view.codeView)
        XCTAssertTrue((view.codeView.accessibilityChildren() ?? []).contains { ($0 as AnyObject) === bubble },"VoiceOver reaches the accessory")
        // Removing the accessory gives the room back.
        view.setInlineAccessories([]);view.layoutSubtreeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(view.lineRect(containing:below)).minY,next.minY,accuracy:0.5)
        XCTAssertNil(bubble.superview)
    }
    func testAccessoriesOnOneLineStackAndRepeatedUpdatesLeaveStorageAlone() throws {
        let text=diffRows(20),view=try surface(text,wrap:false)
        let anchor=offset(text,of:"line 3\n"),first=NSView(),second=NSView()
        let values:[CodeInlineAccessory]=[.init(identity:"a",location:anchor,height:40,view:first),.init(identity:"b",location:anchor+2,height:60,view:second)]
        view.setInlineAccessories(values);view.layoutSubtreeIfNeeded()
        let line=try XCTUnwrap(view.lineRect(containing:anchor))
        XCTAssertEqual(first.frame.minY,line.maxY,accuracy:0.5)
        XCTAssertEqual(second.frame.minY,first.frame.maxY,accuracy:0.5,"accessories on one line stack in order")
        XCTAssertEqual(try XCTUnwrap(view.lineRect(containing:offset(text,of:"line 4\n"))).minY,second.frame.maxY,accuracy:2.5)
        var edits=0
        let observer=NotificationCenter.default.addObserver(forName:NSTextStorage.didProcessEditingNotification,object:view.codeView.textStorage,queue:nil) { _ in MainActor.assumeIsolated { edits += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        for _ in 0..<5 { view.setInlineAccessories(values);view.setDocument(text,tokens:[],wrap:false,firstTabColumn:6) }
        XCTAssertEqual(edits,0,"SwiftUI re-renders with the same accessories must not touch text storage")
        view.setInlineAccessories([values[0]])
        XCTAssertEqual(edits,1,"a changed room is one local edit")
    }
    func testWrappedRoomFollowsTheLastVisualLineOfItsRow() throws {
        let text=diffRows(8,long:[2]),view=try surface(text,wrap:true,width:320)
        let anchor=offset(text,of:"2\t+ wide"),row=try XCTUnwrap(view.lineRect(containing:anchor))
        let bubble=NSView()
        view.setInlineAccessories([.init(identity:"thread",location:anchor,height:80,view:bubble)]);view.layoutSubtreeIfNeeded()
        XCTAssertEqual(bubble.frame.minY,row.maxY,accuracy:0.5,"room follows every wrapped line of the row")
        XCTAssertLessThanOrEqual(bubble.frame.maxX,view.codeView.bounds.maxX+0.5,"wrapped text keeps accessories inside the text width")
        XCTAssertEqual(try XCTUnwrap(view.lineRect(containing:offset(text,of:"line 3\n"))).minY,bubble.frame.maxY,accuracy:2.5)
    }
    func testSplitPanesReserveMirroredRoomAndKeepRowsAndScrollAligned() throws {
        // Split panes carry one row per diff line; the thread's pane holds the view, the other pane mirrors its room.
        let left=(1...300).map { $0 == 40 ? "\n" : "\($0)\t− old \($0)\n" }.joined(),right=(1...300).map { "\($0)\t+ new \($0)\n" }.joined()
        let panes=[try surface(left,wrap:false,width:400),try surface(right,wrap:false,width:400)]
        let sync=CodeScrollSync();panes.forEach(sync.add)
        func rowStart(_ text:String,_ row:Int) -> Int { text.split(separator:"\n",omittingEmptySubsequences:false).prefix(row).reduce(0) { $0+$1.utf16.count+1 } }
        let row=39,bubble=NSView()
        panes[1].setInlineAccessories([.init(identity:"row:39",location:rowStart(right,row),height:150,view:bubble)])
        panes[0].setInlineAccessories([.init(identity:"row:39",location:rowStart(left,row),height:150)])
        for pane in panes { pane.codeView.sizeToFit();pane.layoutSubtreeIfNeeded() }
        for probe in [10,39,40,41,200] {
            let l=try XCTUnwrap(panes[0].lineRect(containing:rowStart(left,probe))),r=try XCTUnwrap(panes[1].lineRect(containing:rowStart(right,probe)))
            XCTAssertEqual(l.minY,r.minY,accuracy:0.5,"row \(probe) stays aligned across panes")
        }
        XCTAssertEqual(try XCTUnwrap(panes[0].inlineAccessoryRect("row:39")).minY,try XCTUnwrap(panes[1].inlineAccessoryRect("row:39")).minY,accuracy:0.5,"mirrored room has the same place")
        panes[0].contentView.scroll(to:NSPoint(x:0,y:900));panes[0].reflectScrolledClipView(panes[0].contentView)
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        XCTAssertEqual(panes[1].contentView.bounds.origin.y,900,accuracy:1,"scroll sync still maps offsets across panes")
        let shown=try XCTUnwrap(panes[1].lineRect(containing:rowStart(right,80),in:.surface)),mirror=try XCTUnwrap(panes[0].lineRect(containing:rowStart(left,80),in:.surface))
        XCTAssertEqual(shown.minY,mirror.minY,accuracy:0.5,"the same row is at the same height on screen in both panes")
    }
    func testUnwrappedAccessoriesStayAcrossTheVisibleWidthWhenScrollingSideways() throws {
        let text=(1...20).map { "\($0)\t+ "+String(repeating:"x",count:$0 == 3 ? 900 : 10)+"\n" }.joined(),view=try surface(text,wrap:false)
        let bubble=NSView()
        view.setInlineAccessories([.init(identity:"t",location:offset(text,of:"3\t+"),height:50,view:bubble)]);view.layoutSubtreeIfNeeded()
        let start=bubble.frame
        view.contentView.scroll(to:NSPoint(x:500,y:0));view.reflectScrolledClipView(view.contentView)
        XCTAssertEqual(bubble.frame.minX-start.minX,500,accuracy:0.5,"the accessory follows the visible area sideways")
        XCTAssertEqual(bubble.frame.minY,start.minY)
        XCTAssertLessThanOrEqual(bubble.frame.width,view.contentView.bounds.width)
    }
    func testGutterMarkClicksAreForwardedAfterSelectingTheirRange() throws {
        let text=diffRows(10),view=try surface(text,wrap:false)
        let range=NSRange(location:offset(text,of:"line 4"),length:6)
        view.setDocument(text,tokens:[],wrap:false,gutterMarks:[.init(range:range,kind:.comment,label:"Comment",identity:"head:a.swift:RIGHT:4")],firstTabColumn:6)
        var forwarded:[CodeGutterMark]=[]
        view.gutterMarkActivated={ forwarded.append($0) }
        view.reviewGutter.activate(view.reviewGutter.marks[0])
        XCTAssertEqual(forwarded.map(\.identity),["head:a.swift:RIGHT:4"])
        XCTAssertEqual(view.codeView.selectedRange(),range)
    }
    func testScrollTicksWithInlineAccessoriesLeaveStorageAndRoomAlone() throws {
        let text=diffRows(3000),view=try surface(text,wrap:false,width:900,height:600)
        let views=(0..<12).map { _ in NSView() }
        view.setInlineAccessories(views.enumerated().map { index,bubble in .init(identity:"t\(index)",location:offset(text,of:"line \(index*200+5)\n"),height:90,view:bubble) })
        view.layoutSubtreeIfNeeded()
        var edits=0
        let observer=NotificationCenter.default.addObserver(forName:NSTextStorage.didProcessEditingNotification,object:view.codeView.textStorage,queue:nil) { _ in MainActor.assumeIsolated { edits += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        let ticks=300
        for tick in 1...ticks { view.contentView.scroll(to:NSPoint(x:0,y:CGFloat(tick)*40));view.reflectScrolledClipView(view.contentView);view.layoutSubtreeIfNeeded() }
        XCTAssertLessThanOrEqual(edits,ticks/10,"accessories add no storage edits to scroll ticks")
        // Once scrolled into view, an accessory sits exactly below its line.
        let target=offset(text,of:"line 1005\n")
        view.codeView.scrollRangeToVisible(NSRange(location:target,length:1));view.layoutSubtreeIfNeeded()
        XCTAssertEqual(views[5].frame.minY,try XCTUnwrap(view.lineRect(containing:target)).maxY,accuracy:0.5)
    }
    func testRoomChangingAboveTheViewportKeepsTheVisibleLineInPlace() throws {
        let text=diffRows(400),view=try surface(text,wrap:false)
        let above=offset(text,of:"line 20\n"),target=offset(text,of:"line 120\n")
        view.setInlineAccessories([.init(identity:"t",location:above,height:60,view:NSView())]);view.layoutSubtreeIfNeeded()
        // Jump to a line well below the thread, as "Show comment location" does.
        view.codeView.scrollRangeToVisible(NSRange(location:target,length:1));view.layoutSubtreeIfNeeded()
        let before=try XCTUnwrap(view.lineRect(containing:target,in:.surface))
        // The thread above is measured taller than its estimate.
        view.setInlineAccessories([.init(identity:"t",location:above,height:260,view:NSView())]);view.layoutSubtreeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(view.lineRect(containing:target,in:.surface)).minY,before.minY,accuracy:0.5,"the reviewer's line stays put")
        // At the top of the document the text simply grows downward.
        view.contentView.scroll(to:.zero);view.reflectScrolledClipView(view.contentView);view.layoutSubtreeIfNeeded()
        let first=try XCTUnwrap(view.lineRect(containing:0,in:.surface))
        view.setInlineAccessories([.init(identity:"t",location:above,height:90,view:NSView())]);view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.contentView.bounds.minY,0)
        XCTAssertEqual(try XCTUnwrap(view.lineRect(containing:0,in:.surface)),first)
    }
    func testSplitPanesAnchorTogetherWithoutDoubleScrolling() throws {
        let left=(1...300).map { "\($0)\t− old \($0)\n" }.joined(),right=(1...300).map { "\($0)\t+ new \($0)\n" }.joined()
        let panes=[try surface(left,wrap:false,width:400),try surface(right,wrap:false,width:400)]
        let sync=CodeScrollSync();panes.forEach(sync.add)
        func rowStart(_ text:String,_ row:Int) -> Int { text.split(separator:"\n",omittingEmptySubsequences:false).prefix(row).reduce(0) { $0+$1.utf16.count+1 } }
        let texts=[left,right]
        for (index,pane) in panes.enumerated() { pane.setInlineAccessories([.init(identity:"r10",location:rowStart(texts[index],10),height:50,view:index == 1 ? NSView() : nil)]) }
        panes[0].contentView.scroll(to:NSPoint(x:0,y:1200));panes[0].reflectScrolledClipView(panes[0].contentView)
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        XCTAssertEqual(panes[1].contentView.bounds.minY,1200,accuracy:1)
        let before=try XCTUnwrap(panes[1].lineRect(containing:rowStart(right,90),in:.surface))
        // The same SwiftUI update grows the mirrored room in both panes, one after the other.
        for (index,pane) in panes.enumerated() { pane.setInlineAccessories([.init(identity:"r10",location:rowStart(texts[index],10),height:230,view:index == 1 ? NSView() : nil)]) }
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
        XCTAssertEqual(panes[0].contentView.bounds.minY,panes[1].contentView.bounds.minY,accuracy:0.5,"panes stay on the same offset")
        XCTAssertEqual(try XCTUnwrap(panes[1].lineRect(containing:rowStart(right,90),in:.surface)).minY,before.minY,accuracy:0.5,"the visible rows don't jump")
        XCTAssertEqual(try XCTUnwrap(panes[0].lineRect(containing:rowStart(left,90),in:.surface)).minY,before.minY,accuracy:0.5)
    }
}
