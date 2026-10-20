import Foundation

/// Verified immutable full-source context. Hidden gaps never invent changes or provider anchors.
public struct DiffContext:Sendable {
    public struct Source:Sendable { public let sha:String;public let text:String;public init(sha:String,text:String) { self.sha=sha;self.text=text } }
    public struct Expansion:Sendable,Equatable { public var fromStart:Int;public var fromEnd:Int;public init(fromStart:Int=0,fromEnd:Int=0) { self.fromStart=fromStart;self.fromEnd=fromEnd } }
    public struct Gap:Sendable,Identifiable { public let id:Int;public let count:Int }
    public enum Failure:Error { case unavailable,sourceMismatch }
    private enum Chunk:Sendable { case gap(Int,[DiffLine]),hunk([DiffLine]) }
    public let gaps:[Gap]
    public let hunkCount:Int
    private let chunks:[Chunk]
    private let document:DiffDocument
    private let file:DiffFile
    private let valid:DiffLineIndex
    public init(document:DiffDocument,file:DiffFile,before:Source?,after:Source?) throws {
        guard document.files.contains(file),file.patchState == .available,
              (file.status == .added && before == nil || before?.sha == document.baseSHA),
              (file.status == .removed && after == nil || after?.sha == document.headSHA) else { throw Failure.unavailable }
        func sourceLines(_ source:Source?) throws -> [String] {
            guard let source else { return [] }
            guard source.text.utf8.count <= 2_000_000 else { throw Failure.unavailable }
            if source.text.isEmpty { return [] }
            var lines=source.text.components(separatedBy:"\n");if source.text.hasSuffix("\n") { lines.removeLast() }
            guard lines.count <= 100_000 else { throw Failure.unavailable };return lines
        }
        let old=try sourceLines(before),new=try sourceLines(after),parsed=file.lines
        var chunks:[Chunk]=[],gaps:[Gap]=[],oldNext=1,newNext=1,hunk=0
        func appendGap(oldEnd:Int,newEnd:Int) throws {
            guard oldEnd >= oldNext,newEnd >= newNext,oldEnd <= old.count+1,newEnd <= new.count+1,oldEnd-oldNext == newEnd-newNext else { throw Failure.sourceMismatch }
            var lines:[DiffLine]=[]
            for delta in 0..<(oldEnd-oldNext) {
                guard old[oldNext+delta-1] == new[newNext+delta-1] else { throw Failure.sourceMismatch }
                lines.append(.init(id:0,hunk: -hunk-1,kind:.context,text:old[oldNext+delta-1],oldLine:oldNext+delta,newLine:newNext+delta))
            }
            gaps.append(.init(id:hunk,count:lines.count));chunks.append(.gap(hunk,lines))
        }
        let hunks=Dictionary(grouping:parsed,by: \.hunk)
        for header in (file.patch ?? "").components(separatedBy:"\n") where header.hasPrefix("@@ ") {
            let parts=header.split(separator:" ")
            func range(_ raw:Substring) -> (Int,Int) { let values=raw.dropFirst().split(separator:",");return (Int(values[0])!,values.count == 2 ? Int(values[1])! : 1) }
            let a=range(parts[1]),b=range(parts[2]),oldStart=a.0+(a.1 == 0 ? 1 : 0),newStart=b.0+(b.1 == 0 ? 1 : 0)
            try appendGap(oldEnd:oldStart,newEnd:newStart)
            let lines=hunks[hunk] ?? []
            for line in lines {
                if let n=line.oldLine { guard n > 0,n <= old.count,old[n-1] == line.text else { throw Failure.sourceMismatch } }
                if let n=line.newLine { guard n > 0,n <= new.count,new[n-1] == line.text else { throw Failure.sourceMismatch } }
            }
            chunks.append(.hunk(lines));oldNext=oldStart+a.1;newNext=newStart+b.1;hunk += 1
        }
        try appendGap(oldEnd:old.count+1,newEnd:new.count+1)
        self.gaps=gaps;self.chunks=chunks;self.hunkCount=hunk;self.document=document;self.file=file
        self.valid=DiffLineIndex(chunks.flatMap { switch $0 { case .gap(_,let lines),.hunk(let lines):return lines } })
    }
    public func matches(document:DiffDocument,file:DiffFile) -> Bool { self.document.baseSHA == document.baseSHA && self.document.headSHA == document.headSHA && self.file == file }
    public func lines(expansion:[Int:Expansion]) -> [DiffLine] {
        var result:[DiffLine]=[]
        for chunk in chunks {
            switch chunk {
            case .hunk(let lines):result += lines
            case .gap(let id,let lines):
                let amount=expansion[id] ?? .init(),head=min(lines.count,max(0,amount.fromStart)),tail=min(lines.count-head,max(0,amount.fromEnd))
                result += lines.prefix(head)
                if head+tail < lines.count { result.append(.init(id:0,hunk: -id-1,kind:.context,text:"⋯ \(lines.count-head-tail) unchanged lines ⋯",oldLine:nil,newLine:nil)) }
                result += lines.suffix(tail)
            }
        }
        return result.enumerated().map { index,line in .init(id:index,hunk:line.hunk,kind:line.kind,text:line.text,oldLine:line.oldLine,newLine:line.newLine) }
    }
    /// Rendering coordinates for selected visible context; provider comment eligibility stays separate.
    public func anchor(side:DiffSide,start:Int,end:Int,displayed:[DiffLine]) throws -> ReviewAnchor {
        try anchor(side:side,start:start,end:end,visible:DiffLineIndex(displayed))
    }
    public func anchor(side:DiffSide,start:Int,end:Int,visible:DiffLineIndex) throws -> ReviewAnchor {
        guard visible.contains(side:side,start:start,end:end),valid.contains(side:side,start:start,end:end) else { throw Failure.unavailable }
        return .init(commitSHA:side == .left ? document.baseSHA : document.headSHA,path:side == .left ? file.previousPath ?? file.path : file.path,side:side.rawValue,startLine:start,endLine:end)
    }
}

public actor DiffContextWorker {
    public static let shared=DiffContextWorker()
    public func build(document:DiffDocument,file:DiffFile,before:DiffContext.Source?,after:DiffContext.Source?) throws -> DiffContext {
        try Task.checkCancellation()
        return try DiffContext(document:document,file:file,before:before,after:after)
    }
}
