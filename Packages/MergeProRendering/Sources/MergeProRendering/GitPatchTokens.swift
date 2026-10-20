import Foundation

/// Git-style overlays for raw unified diff text: tinted added and removed lines with colored
/// signs, cyan hunk ranges, and dimmed file headers. Append them after syntax tokens so the
/// sign and header colors win.
public enum GitPatchTokens {
    public static func tokens(in patch:String) -> [CodeToken] {
        var tokens:[CodeToken]=[],location=0,inFileHeader=false
        let total=patch.utf16.count
        for line in patch.split(separator:"\n",omittingEmptySubsequences:false) {
            let length=line.utf16.count
            // The newline joins the tint so a line's background runs past its last glyph.
            let tinted=NSRange(location:location,length:min(length+1,total-location))
            if line.hasPrefix("diff ") { inFileHeader=true;tokens.append(.init(range:tinted,scopes:["diff.meta"])) }
            else if line.hasPrefix("@@") {
                inFileHeader=false
                let rest=line.dropFirst(2)
                let end=rest.range(of:"@@").map { line.utf16.distance(from:line.startIndex,to:$0.upperBound) } ?? length
                tokens.append(.init(range:NSRange(location:location,length:end),scopes:["diff.hunk"]))
            }
            else if inFileHeader || line.hasPrefix("\\") { tokens.append(.init(range:tinted,scopes:["diff.meta"])) }
            else if let sign=line.first,sign == "+" || sign == "-" {
                let added=sign == "+"
                tokens.append(.init(range:tinted,scopes:[added ? "diff.added" : "diff.removed"]))
                tokens.append(.init(range:NSRange(location:location,length:1),scopes:[added ? "diff.sign.added" : "diff.sign.removed"]))
            }
            location += length+1
        }
        return tokens
    }
}
