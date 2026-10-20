import Foundation

/// Physical source lines and native selections use UTF-16 offsets. The original bytes'
/// indentation and line endings are retained, so line links still name the same code.
public struct CodeDocument:Sendable {
    public let source:String
    public let lineRanges:[NSRange]
    public let lineNumberMarks:[CodeGutterMark]
    public init(_ source:String) {
        self.source=source
        let units=Array(source.utf16)
        var ranges:[NSRange]=[],start=0
        for index in units.indices where units[index] == 10 {
            let end=index > start && units[index-1] == 13 ? index-1 : index
            ranges.append(NSRange(location:start,length:end-start));start=index+1
        }
        ranges.append(NSRange(location:start,length:units.count-start))
        lineRanges=ranges
        lineNumberMarks=ranges.enumerated().map { index,range in
            .init(range:range,kind:.lineNumber,label:String(index+1),identity:"source:\(index+1)")
        }
    }
    public func range(forLine line:Int) -> NSRange? {
        guard line > 0,line <= lineRanges.count else { return nil };return lineRanges[line-1]
    }
    public func lineNumber(at offset:Int) -> Int? {
        guard offset >= 0,offset <= source.utf16.count else { return nil }
        var lo=0,hi=lineRanges.count
        while lo < hi { let mid=(lo+hi)/2;if lineRanges[mid].location <= offset { lo=mid+1 } else { hi=mid } }
        return max(1,lo)
    }
    /// Literal, case-insensitive search. A limit bounds navigation state for very repetitive files.
    public func find(_ query:String,limit:Int = 10000) -> CodeSearchResult {
        guard !query.isEmpty,limit > 0 else { return .init(ranges:[],truncated:false) }
        let ns=source as NSString
        var ranges:[NSRange]=[],offset=0
        while offset < ns.length {
            if Task.isCancelled { return .init(ranges:[],truncated:false) }
            let range=ns.range(of:query,options:.caseInsensitive,range:NSRange(location:offset,length:ns.length-offset))
            guard range.location != NSNotFound,range.length > 0 else { break }
            if ranges.count == limit { return .init(ranges:ranges,truncated:true) }
            ranges.append(range);offset=NSMaxRange(range)
        }
        return .init(ranges:ranges,truncated:false)
    }
}

public struct CodeSearchResult:Sendable,Equatable {
    public let ranges:[NSRange]
    public let truncated:Bool
    public func nextIndex(after index:Int?,backwards:Bool) -> Int? {
        guard !ranges.isEmpty else { return nil }
        guard let index,index >= 0,index < ranges.count else { return backwards ? ranges.count-1 : 0 }
        return (index+(backwards ? ranges.count-1 : 1)) % ranges.count
    }
}

/// Keep source values separate instead of concatenating large strings into SwiftUI task IDs.
public struct CodeDocumentIdentity:Hashable,Sendable {
    public let source:String
    public let path:String
    public let languageOverride:String?
    public init(source:String,path:String,languageOverride:String? = nil) { self.source=source;self.path=path;self.languageOverride=languageOverride }
}

public struct CodeHighlightSnapshot:Sendable {
    public let identity:CodeDocumentIdentity
    public let result:HighlightResult
    public init(identity:CodeDocumentIdentity,result:HighlightResult) { self.identity=identity;self.result=result }
    public func tokens(for identity:CodeDocumentIdentity) -> [CodeToken] { self.identity == identity ? result.tokens : [] }
}
