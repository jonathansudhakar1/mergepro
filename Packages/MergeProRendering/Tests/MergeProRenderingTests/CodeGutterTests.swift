import AppKit
import XCTest
@testable import MergeProRendering
@MainActor final class CodeGutterTests:XCTestCase {
    func testOversizedDirtyRectCannotPaintOverAdjacentCodeOrControls() throws {
        let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:300,pixelsHigh:60,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        let context=try XCTUnwrap(NSGraphicsContext(bitmapImageRep:bitmap))
        NSGraphicsContext.saveGraphicsState();defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current=context
        NSColor.blue.setFill();NSRect(x:0,y:0,width:300,height:60).fill()
        let surface=NativeCodeSurface(frame:NSRect(x:0,y:0,width:300,height:60))
        let gutter=surface.reviewGutter
        gutter.frame=NSRect(x:0,y:0,width:96,height:60)
        gutter.drawHashMarksAndLabels(in:NSRect(x:0,y:0,width:300,height:60))
        let adjacent=try XCTUnwrap(bitmap.colorAt(x:200,y:20)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(adjacent.blueComponent,1,accuracy:0.05)
        XCTAssertEqual(adjacent.redComponent,0,accuracy:0.05)
    }
    func testNativeGutterPreservesCanonicalLabelsAndRejectsInvalidRanges() {
        let surface=NativeCodeSurface(frame:NSRect(x:0,y:0,width:700,height:300))
        let source="one 🐈\ntwo\nthree"
        let marks:[CodeGutterMark]=[
            .init(range:.init(location:0,length:6),kind:.lineNumber,label:"LEFT 4",identity:"base:old.swift:4"),
            .init(range:.init(location:7,length:3),kind:.comment,label:"Comment on head:a:5",identity:"head:a:5"),
            .init(range:.init(location:7,length:3),kind:.annotation,label:"Lint warning",identity:"head:a:5"),
            .init(range:.init(location:Int.max,length:2),kind:.added,label:"invalid",identity:"invalid")]
        surface.setDocument(source,tokens:[],wrap:false,gutterMarks:marks)
        XCTAssertTrue(surface.rulersVisible)
        XCTAssertEqual(surface.reviewGutter.marks.count,3)
        XCTAssertEqual(surface.reviewGutter.marks[1].identity,"head:a:5")
        XCTAssertNotNil(surface.codeView.textLayoutManager)
        surface.reviewGutter.activate(surface.reviewGutter.marks[1])
        XCTAssertEqual(surface.codeView.selectedRange(),NSRange(location:7,length:3))
        surface.setDocument(source,tokens:[],wrap:true,gutterMarks:marks)
        XCTAssertEqual(surface.codeView.selectedRange(),NSRange(location:7,length:3))
    }

    func testCommentOnlyGutterStaysCompactBesideInlineLineNumbers() throws {
        let surface=NativeCodeSurface(frame:NSRect(x:0,y:0,width:700,height:300))
        let source="1\t  one\n2\t+ two\n"
        surface.setDocument(source,tokens:[],wrap:false,gutterMarks:[.init(range:.init(location:13,length:3),kind:.comment,label:"Comment",identity:"head:a:2"),.init(range:.init(location:13,length:3),kind:.annotation,label:"Lint",identity:"head:a:2")])
        XCTAssertTrue(surface.rulersVisible)
        XCTAssertLessThanOrEqual(surface.reviewGutter.ruleThickness,40,"diff text already carries line numbers")
        surface.codeView.frame=NSRect(x:0,y:0,width:600,height:300)
        let manager=try XCTUnwrap(surface.codeView.textLayoutManager)
        manager.ensureLayout(for:try XCTUnwrap(manager.textContentManager).documentRange)
        XCTAssertEqual(surface.reviewGutter.visibleMarkerFrames().map(\.mark.kind),[.comment,.annotation])
        XCTAssertTrue(surface.reviewGutter.visibleMarkerFrames().allSatisfy { $0.frame.width == surface.reviewGutter.ruleThickness })
        surface.setDocument(source,tokens:[],wrap:false,gutterMarks:[.init(range:.init(location:4,length:3),kind:.lineNumber,label:"1",identity:"head:a:1")])
        XCTAssertEqual(surface.reviewGutter.ruleThickness,96)
    }
    func testWrappedUnicodeViewportPlacesMarkersOnActualTextLines() throws {
        let surface=NativeCodeSurface(frame:NSRect(x:0,y:0,width:260,height:220))
        let first=String(repeating:"🐈 café ",count:10)
        let source=first+"\nsecond\nthird"
        let second=first.utf16.count+1
        surface.setDocument(source,tokens:[],wrap:true,gutterMarks:[
            .init(range:.init(location:0,length:2),kind:.removed,label:"LEFT 4",identity:"base:old.swift:LEFT:4"),
            .init(range:.init(location:second,length:6),kind:.comment,label:"RIGHT comment",identity:"head:new.swift:RIGHT:5")])
        surface.codeView.frame=NSRect(x:0,y:0,width:surface.contentSize.width,height:600)
        let manager=try XCTUnwrap(surface.codeView.textLayoutManager)
        manager.ensureLayout(for:try XCTUnwrap(manager.textContentManager).documentRange)
        let positions=surface.reviewGutter.visibleMarkerFrames()
        XCTAssertEqual(positions.map { $0.mark.identity },["base:old.swift:LEFT:4","head:new.swift:RIGHT:5"])
        XCTAssertGreaterThan(try XCTUnwrap(positions.last).frame.minY,try XCTUnwrap(positions.first).frame.minY+30,"wrapped Unicode occupies multiple actual layout lines")
        surface.reviewGutter.activate(positions[1].mark)
        XCTAssertEqual((source as NSString).substring(with:surface.codeView.selectedRange()),"second")
    }
}
