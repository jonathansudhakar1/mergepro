import Foundation

public struct DiffGutterMarker:Sendable {
    public enum Kind:Sendable { case lineNumber,added,removed,comment,annotation }
    public let range:NSRange
    public let kind:Kind
    public let label:String
    public let anchor:ReviewAnchor
}
public extension DiffPresentation {
    func markers(document:DiffDocument,file:DiffFile,events:[PRDetailEvent],context:DiffContext?,displayed:[DiffLine]) -> [DiffGutterMarker] {
        guard document.files.contains(file),file.patchState == .available,context == nil || context?.matches(document:document,file:file) == true else { return [] }
        let visible=DiffLineIndex(displayed)
        var left:[Int:[PRDetailEvent]]=[:],right:[Int:[PRDetailEvent]]=[:]
        for event in events {
            guard let location=event.renderingAnchor(in:document),location.path == (location.side == "LEFT" ? file.previousPath ?? file.path : file.path),location.startLine > 0,location.endLine >= location.startLine,location.endLine-location.startLine < 10000 else { continue }
            for line in location.startLine...location.endLine {
                if location.side == "LEFT" { left[line,default:[]].append(event) } else { right[line,default:[]].append(event) }
            }
        }
        return rows.flatMap { row -> [DiffGutterMarker] in
            guard let number=row.line else { return [] }
            let anchor:ReviewAnchor
            if let context { guard let value=try? context.anchor(side:row.side,start:number,end:number,visible:visible) else { return [] };anchor=value }
            else {
                guard file.lineIndex.contains(side:row.side,start:number,end:number) else { return [] }
                anchor = .init(commitSHA:row.side == .left ? document.baseSHA : document.headSHA,path:row.side == .left ? file.previousPath ?? file.path : file.path,side:row.side.rawValue,startLine:number,endLine:number)
            }
            var values=[DiffGutterMarker(range:row.contentRange,kind:.lineNumber,label:String(number),anchor:anchor)]
            if row.kind != .context { values.append(.init(range:row.contentRange,kind:row.kind == .added ? .added : .removed,label:row.kind.rawValue.capitalized+" line \(number)",anchor:anchor)) }
            for event in (row.side == .left ? left[number] : right[number]) ?? [] {
                values.append(.init(range:row.contentRange,kind:event.providerComment == nil ? .annotation : .comment,label:event.title+": "+event.body,anchor:anchor))
            }
            return values
        }
    }
    /// Full-file presentation uses immutable source rows while retaining original change kinds.
    static func fullSource(_ source:String,side:DiffSide,file:DiffFile) -> Self {
        var sourceLines=source.components(separatedBy:"\n");if source.hasSuffix("\n") { sourceLines.removeLast() }
        if source.isEmpty { sourceLines=[] }
        let changed=Dictionary(file.lines.compactMap { line -> (Int,DiffLine.Kind)? in
            guard let number=side == .left ? line.oldLine : line.newLine else { return nil };return (number,line.kind)
        },uniquingKeysWith:{ first,_ in first })
        let lines=sourceLines.enumerated().map { index,text in DiffLine(id:index,hunk:0,kind:changed[index+1] ?? .context,text:text,oldLine:side == .left ? index+1 : nil,newLine:side == .right ? index+1 : nil) }
        return .init(source:source,lines:lines,side:side)
    }
    private init(source:String,lines:[DiffLine],side:DiffSide) {
        self.text=source
        var offset=0
        self.rows=lines.map { line in
            let range=NSRange(location:offset,length:line.text.utf16.count);offset += range.length+1
            return .init(line:side == .left ? line.oldLine : line.newLine,side:side,contentRange:range,kind:line.kind,wordRange:nil)
        }
    }
}

public extension DiffDocument {
    /// Convert content coordinates to canonical PR changed-file coordinates for a future review.
    /// This is local mapping, not provider eligibility or an atomic current-head/base guarantee.
    func providerCommentLocation(for anchor:ReviewAnchor) -> PRProviderCommentLocation? {
        guard comparison == .pullRequest,let side=DiffSide(rawValue:anchor.side),anchor.commitSHA == (side == .left ? baseSHA : headSHA),
              let file=files.first(where:{ (side == .left ? $0.previousPath ?? $0.path : $0.path) == anchor.path }),
              let validated=try? self.anchor(file:file,side:side,start:anchor.startLine,end:anchor.endLine),validated == anchor else { return nil }
        return .init(reviewedHeadSHA:headSHA,path:file.path,side:side.rawValue,startLine:anchor.startLine,endLine:anchor.endLine)
    }
}

public struct PreparedDiffPresentation:Sendable {
    public let presentations:[String:DiffPresentation]
    public let markers:[String:[DiffGutterMarker]]
    public let displayed:[DiffLine]
    public let visible:DiffLineIndex
}
/// Parsing/indexing and reusable marker construction never execute in a SwiftUI body.
public actor DiffPresentationWorker {
    public static let shared=DiffPresentationWorker()
    public func prepare(document:DiffDocument,file:DiffFile,context:DiffContext?,expansion:[Int:DiffContext.Expansion],events:[PRDetailEvent],hideWhitespace:Bool,fullSource:String?,fullSide:DiffSide) throws -> PreparedDiffPresentation {
        try Task.checkCancellation()
        let displayed=context?.lines(expansion:expansion) ?? file.lines
        var presentations:[String:DiffPresentation]=[:],markers:[String:[DiffGutterMarker]]=[:]
        for side:DiffSide? in [nil,.left,.right] {
            let key=side?.rawValue ?? "unified",value=DiffPresentation(lines:displayed,side:side,hideWhitespace:hideWhitespace)
            presentations[key]=value;markers[key]=value.markers(document:document,file:file,events:events,context:context,displayed:displayed)
        }
        if let fullSource {
            let all=context.map { $0.lines(expansion:Dictionary(uniqueKeysWithValues:$0.gaps.map { ($0.id,.init(fromStart:$0.count)) })) } ?? file.lines
            markers["full"]=DiffPresentation.fullSource(fullSource,side:fullSide,file:file).markers(document:document,file:file,events:events,context:context,displayed:all)
        }
        try Task.checkCancellation()
        return .init(presentations:presentations,markers:markers,displayed:displayed,visible:DiffLineIndex(displayed))
    }
}
