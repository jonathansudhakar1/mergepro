import Foundation

/// Lightweight lexical support for web source where no Tree-sitter grammar is bundled.
/// One ordered scanner prevents strings/comments from being colored as declarations.
/// This changes only attributes; source formatting and line offsets are never rewritten.
enum WebSourceTokenizer {
    static func tokenize(_ source:String,language:String) -> [CodeToken] {
        let patterns:[(String,String)]
        if language == "css" {
            patterns=[
                (#"/\*[\s\S]*?(?:\*/|$)"#,"comment.block"),
                (#""(?:\\(?:[\s\S]|$)|[^"\\])*(?:"|$)|'(?:\\(?:[\s\S]|$)|[^'\\])*(?:'|$)"#,"string.quoted"),
                (#"@[\w-]+"#,"keyword"),
                (#"--[\w-]+|(?<![\w-])[\w-]+(?=\s*:)"#,"entity.property"),
                (#"#[\da-fA-F]{3,8}\b|\b\d+(?:\.\d+)?(?:%|[a-zA-Z]+)?"#,"constant.numeric"),
                (#"[.#][\w-]+|(?<![\w-])[\w-]+(?=\s*\{)"#,"entity.selector")
            ]
        } else {
            patterns=[
                (#"<!--[\s\S]*?(?:-->|$)"#,"comment.block"),
                (#"<![^>]*(?:>|$)|</?[\w:-]+|/?>"#,"keyword.tag"),
                (#""[^"]*"|'[^']*'"#,"string.quoted"),
                (#"(?<![\w:-])[\w:-]+(?=\s*=)"#,"entity.attribute"),
                (#"&(?:#[\dxXa-fA-F]+|[a-zA-Z]+);"#,"constant.character")
            ]
        }
        // Identifier-start guards and EOF alternatives prevent ICU from retrying a
        // failed long identifier/string/declaration at every suffix of the source.
        guard let expression=try? NSRegularExpression(pattern:patterns.map { "("+$0.0+")" }.joined(separator:"|")) else { return [] }
        var tokens:[CodeToken]=[]
        expression.enumerateMatches(in:source,range:NSRange(location:0,length:source.utf16.count)) { match,_,stop in
            guard !Task.isCancelled,tokens.count < 100000 else { stop.pointee=true;return }
            guard let match else { return }
            for index in patterns.indices where match.range(at:index+1).location != NSNotFound {
                tokens.append(.init(range:match.range,scopes:[patterns[index].1]));break
            }
        }
        return tokens
    }
}
