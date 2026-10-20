import Foundation

/// A viewport query includes enclosing multiline tokens and preserves the tokenizer's
/// original attribute ordering, including overlapping diff overlays.
struct CodeTokenIndex {
    private struct Entry { let token:CodeToken;let order:Int;let maximumEnd:Int }
    private let entries:[Entry]
    init(_ tokens:[CodeToken],length:Int) {
        let sorted=tokens.enumerated().filter { _,token in
            token.range.location >= 0 && token.range.length > 0 && token.range.location <= length && token.range.length <= length-token.range.location
        }.sorted { $0.element.range.location < $1.element.range.location }
        var maximumEnd=0
        entries=sorted.map { order,token in
            maximumEnd=max(maximumEnd,NSMaxRange(token.range));return Entry(token:token,order:order,maximumEnd:maximumEnd)
        }
    }
    func intersecting(_ range:NSRange) -> [CodeToken] {
        guard range.location >= 0,range.length > 0,range.location <= Int.max-range.length else { return [] }
        let end=NSMaxRange(range)
        var lo=0,hi=entries.count
        while lo < hi { let mid=(lo+hi)/2;if entries[mid].maximumEnd <= range.location { lo=mid+1 } else { hi=mid } }
        var matches:[Entry]=[],index=lo
        while index < entries.count,entries[index].token.range.location < end {
            let entry=entries[index]
            if NSMaxRange(entry.token.range) > range.location { matches.append(entry) };index += 1
        }
        return matches.sorted { $0.order < $1.order }.map(\.token)
    }
}
