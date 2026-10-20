import Foundation

public struct DiffPresentation:Sendable {
    public struct Row:Sendable {
        public let line:Int?
        public let side:DiffSide
        public let contentRange:NSRange
        public let kind:DiffLine.Kind
        public let wordRange:NSRange?
    }
    public let text:String
    public let rows:[Row]
    public init(file:DiffFile,side:DiffSide?,hideWhitespace:Bool) {
        self.init(lines:file.lines,side:side,hideWhitespace:hideWhitespace)
    }
    public init(lines:[DiffLine],side:DiffSide?,hideWhitespace:Bool) {
        let all=lines;var hidden=Set<Int>();var changes:[Int:NSRange]=[:]
        var index=0
        while index < all.count {
            guard all[index].kind == .removed else { index += 1;continue }
            let hunk=all[index].hunk,start=index
            while index < all.count,all[index].hunk == hunk,all[index].kind == .removed { index += 1 }
            let additions=index
            while index < all.count,all[index].hunk == hunk,all[index].kind == .added { index += 1 }
            // Unified patches group all deletions before insertions. Pair by position within the block.
            for (old,new) in zip(all[start..<additions],all[additions..<index]) {
                if hideWhitespace && DiffWords.onlyWhitespace(old:old.text,new:new.text) { hidden.insert(old.id);hidden.insert(new.id) }
                let words=DiffWords.changedRange(old:old.text,new:new.text);changes[old.id]=words.old;changes[new.id]=words.new
            }
        }
        var pieces:[String]=[],offset=0,rows:[Row]=[]
        for line in all where !hidden.contains(line.id) {
            let effective=side ?? (line.kind == .removed ? .left : .right)
            let number=effective == .left ? line.oldLine : line.newLine
            if number == nil { rows.append(.init(line:nil,side:effective,contentRange:NSRange(location:offset,length:0),kind:line.kind,wordRange:nil));let placeholder=line.oldLine == nil && line.newLine == nil ? line.text : "";pieces.append(placeholder+"\n");offset += placeholder.utf16.count+1;continue }
            let prefix="\(number!)\t\(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ") "
            pieces.append(prefix);offset += prefix.utf16.count
            let range=NSRange(location:offset,length:line.text.utf16.count)
            rows.append(.init(line:number,side:effective,contentRange:range,kind:line.kind,wordRange:changes[line.id].map { NSRange(location:range.location+$0.location,length:$0.length) }))
            pieces.append(line.text+"\n");offset += line.text.utf16.count+1
        }
        self.text=pieces.joined();self.rows=rows
    }
    public func lineRange(for selection:NSRange) -> ClosedRange<Int>? {
        guard selection.location >= 0,selection.length >= 0,selection.location <= text.utf16.count,selection.length <= text.utf16.count-selection.location else { return nil }
        let selected=rows.filter { $0.line != nil && (selection.length == 0 ? ($0.contentRange.length == 0 ? selection.location == $0.contentRange.location : NSLocationInRange(selection.location,$0.contentRange)) : NSIntersectionRange(selection,$0.contentRange).length > 0) }
        guard let first=selected.first?.line,let last=selected.last?.line,first <= last,Set(selected.map(\.side)).count == 1 else { return nil };return first...last
    }
}
