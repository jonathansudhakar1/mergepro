import Foundation

public struct FileAttributeRules:Sendable {
    public struct Attributes:Sendable { public var language:String?;public var generated=false;public var vendored=false;public init() {} }
    private struct Rule:Sendable { let pattern:String;let attributes:[String] }
    private let rules:[Rule]
    /// Bounded common gitattributes patterns. Macros and quoted/escaped pattern forms are ignored.
    public init(_ source:String) {
        rules=source.prefix(100000).components(separatedBy:"\n").prefix(2000).compactMap { line in
            let fields=line.split(whereSeparator:\.isWhitespace).map(String.init)
            guard fields.count > 1,!fields[0].hasPrefix("#"),!fields[0].hasPrefix("!"),!fields[0].contains("\\"),!fields[0].contains("\"") else { return nil }
            return Rule(pattern:fields[0],attributes:Array(fields.dropFirst()))
        }
    }
    public func attributes(for path:String) -> Attributes {
        guard GitHubPRDetailFetcher.validPath(path) else { return Attributes() }
        var result=Attributes()
        for rule in rules where Self.matches(rule.pattern,path:path) {
            for attribute in rule.attributes {
                if attribute.hasPrefix("linguist-language=") { result.language=String(attribute.dropFirst(18)).lowercased() }
                if ["linguist-generated","linguist-generated=true"].contains(attribute) { result.generated=true }
                if ["-linguist-generated","linguist-generated=false"].contains(attribute) { result.generated=false }
                if ["linguist-vendored","linguist-vendored=true"].contains(attribute) { result.vendored=true }
                if ["-linguist-vendored","linguist-vendored=false"].contains(attribute) { result.vendored=false }
            }
        }
        return result
    }
    private static func matches(_ pattern:String,path:String) -> Bool {
        let pattern=pattern.hasPrefix("/") ? String(pattern.dropFirst()) : pattern
        let target=pattern.contains("/") ? path : URL(fileURLWithPath:path).lastPathComponent
        var regex="^";var i=pattern.startIndex
        while i < pattern.endIndex {
            let c=pattern[i],next=pattern.index(after:i)
            if c == "*",next < pattern.endIndex,pattern[next] == "*" {
                // `**/` also matches zero directories (`**/gen/x` matches `gen/x`; `a/**/b` matches `a/b`).
                let after=pattern.index(after:next)
                if after < pattern.endIndex,pattern[after] == "/" { regex += "(.*/)?";i=pattern.index(after:after) } else { regex += ".*";i=after }
                continue
            }
            if c == "*" { regex += "[^/]*" } else if c == "?" { regex += "[^/]" } else { regex += NSRegularExpression.escapedPattern(for:String(c)) }
            i=next
        }
        return target.range(of:regex+"$",options:.regularExpression) != nil
    }
}
