import Foundation
import MergeProCore
import MergeProRendering

struct DiffTokenMapping {
    let byLine:[Int:[CodeToken]]
    init(source:String,tokens:[CodeToken]) {
        let length=source.utf16.count
        let lines=source.components(separatedBy:"\n");var starts=[0]
        for line in lines { starts.append(starts.last!+line.utf16.count+1) }
        var mapped:[Int:[CodeToken]]=[:]
        for token in tokens {
            guard token.range.location >= 0,NSMaxRange(token.range) <= length else { continue }
            var lo=0,hi=lines.count
            while lo < hi { let mid=(lo+hi)/2;if starts[mid+1] <= token.range.location { lo=mid+1 } else { hi=mid } }
            var index=lo
            while index < lines.count,starts[index] < NSMaxRange(token.range) {
                let part=NSIntersectionRange(token.range,NSRange(location:starts[index],length:lines[index].utf16.count))
                if part.length > 0 { mapped[index+1,default:[]].append(.init(range:NSRange(location:part.location-starts[index],length:part.length),scopes:token.scopes)) }
                index += 1
            }
        }
        byLine=mapped
    }
    static func tokens(for presentation:DiffPresentation,left:Self?,right:Self?) -> [CodeToken] {
        presentation.rows.flatMap { row -> [CodeToken] in
            guard let number=row.line else { return [] }
            var values=((row.side == .left ? left : right)?.byLine[number] ?? []).compactMap { token -> CodeToken? in
                guard NSMaxRange(token.range) <= row.contentRange.length else { return nil }
                return .init(range:NSRange(location:row.contentRange.location+token.range.location,length:token.range.length),scopes:token.scopes)
            }
            // Presentation prefix is "<number>\t<sign> "; dim the number and color the sign.
            let digits=String(number).utf16.count,prefixStart=row.contentRange.location-digits-3
            if prefixStart >= 0 {
                values.append(.init(range:NSRange(location:prefixStart,length:digits),scopes:["diff.lineNumber"]))
                if row.kind != .context { values.append(.init(range:NSRange(location:row.contentRange.location-2,length:1),scopes:[row.kind == .added ? "diff.sign.added" : "diff.sign.removed"])) }
            }
            if row.kind != .context { values.append(.init(range:prefixStart >= 0 ? NSRange(location:prefixStart,length:NSMaxRange(row.contentRange)-prefixStart) : row.contentRange,scopes:[row.kind == .added ? "diff.added" : "diff.removed"])) }
            if let range=row.wordRange { values.append(.init(range:range,scopes:["diff.word"])) }
            return values
        }
    }
}
