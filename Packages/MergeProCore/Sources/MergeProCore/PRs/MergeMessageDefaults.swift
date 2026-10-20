import Foundation

/// Repository commit-message settings, using GitHub's GraphQL enum names. Unknown future
/// values decode to GitHub's documented defaults (COMMIT_OR_PR_TITLE/COMMIT_MESSAGES and MERGE_MESSAGE/PR_TITLE).
public struct MergeMessageSettings:Sendable,Equatable,Codable {
    public enum SquashTitle:String,Sendable,Codable,CaseIterable { case prTitle="PR_TITLE",commitOrPRTitle="COMMIT_OR_PR_TITLE" }
    public enum SquashBody:String,Sendable,Codable,CaseIterable { case prBody="PR_BODY",commitMessages="COMMIT_MESSAGES",blank="BLANK" }
    public enum MergeTitle:String,Sendable,Codable,CaseIterable { case mergeMessage="MERGE_MESSAGE",prTitle="PR_TITLE" }
    public enum MergeBody:String,Sendable,Codable,CaseIterable { case prTitle="PR_TITLE",prBody="PR_BODY",blank="BLANK" }
    public var squashTitle:SquashTitle
    public var squashBody:SquashBody
    public var mergeTitle:MergeTitle
    public var mergeBody:MergeBody
    public init(squashTitle:SquashTitle = .commitOrPRTitle,squashBody:SquashBody = .commitMessages,mergeTitle:MergeTitle = .mergeMessage,mergeBody:MergeBody = .prTitle) {
        self.squashTitle=squashTitle;self.squashBody=squashBody;self.mergeTitle=mergeTitle;self.mergeBody=mergeBody
    }
}
public struct MergeMessageAuthor:Sendable,Equatable {
    public var name:String
    public var email:String
    public var login:String?
    public init(name:String,email:String,login:String?=nil) { self.name=name;self.email=email;self.login=login }
}
public struct MergeMessageCommit:Sendable,Equatable {
    public var headline:String
    public var body:String
    public var authors:[MergeMessageAuthor]
    public init(headline:String,body:String="",authors:[MergeMessageAuthor]=[]) { self.headline=headline;self.body=body;self.authors=authors }
}
/// Read-only prefill for one PR head. Deliberately not part of `MergeEvidence`: a PR body edit
/// must not change merge admission (`sameAdmission`). Rebase has no title/body entry.
public struct MergeMessageDefaults:Sendable,Equatable {
    public let head:String
    public var titles:[MergeMethod:String]
    public var bodies:[MergeMethod:String]
    /// Normalized `Co-authored-by: Name <email>` lines, deduplicated, excluding the PR author.
    public var coAuthorTrailers:[String]
    public var settings:MergeMessageSettings
    /// False when the PR has more commits than the single bounded page that was read.
    public var commitsComplete:Bool
    /// True when at least one value came from GitHub's viewer prefill rather than `MergeMessageComposer.fallback`.
    public var providerPrefill:Bool
    public init(head:String,titles:[MergeMethod:String],bodies:[MergeMethod:String],coAuthorTrailers:[String]=[],settings:MergeMessageSettings = .init(),commitsComplete:Bool=true,providerPrefill:Bool=false) {
        self.head=head;self.titles=titles;self.bodies=bodies;self.coAuthorTrailers=coAuthorTrailers;self.settings=settings;self.commitsComplete=commitsComplete;self.providerPrefill=providerPrefill
    }
}
public enum MergeMessageComposer {
    /// GitHub's documented defaults. Use only when GitHub's own prefill is absent (e.g. fixtures).
    /// Titles carry ` (#n)` like GitHub's web prefill; a squash body (unless BLANK) keeps co-author trailers.
    public static func fallback(settings:MergeMessageSettings,prTitle:String,prBody:String,number:Int,headLabel:String,commits:[MergeMessageCommit],prAuthor:String?) -> (titles:[MergeMethod:String],bodies:[MergeMethod:String]) {
        let numbered=prTitle+" (#\(number))"
        let squashTitle=settings.squashTitle == .commitOrPRTitle && commits.count == 1 ? commits[0].headline+" (#\(number))" : numbered
        let squashBody:String
        switch settings.squashBody {
        case .prBody:squashBody=prBody
        case .commitMessages:squashBody=commits.map { "* "+$0.headline }.joined(separator:"\n\n")
        case .blank:squashBody=""
        }
        let mergeTitle=settings.mergeTitle == .mergeMessage ? "Merge pull request #\(number) from \(headLabel)" : numbered
        let mergeBody=settings.mergeBody == .prTitle ? prTitle : settings.mergeBody == .prBody ? prBody : ""
        let trailers=settings.squashBody == .blank ? [] : coAuthors(commits:commits,prAuthor:prAuthor)
        return ([.squash:squashTitle,.merge:mergeTitle],[.squash:ensuring(trailers:trailers,in:squashBody),.merge:mergeBody])
    }
    /// Commit authors plus existing body trailers, deduplicated by login/email, excluding the PR author.
    public static func coAuthors(commits:[MergeMessageCommit],prAuthor:String?) -> [String] {
        let author=prAuthor?.lowercased()
        let authorEmails=Set(commits.flatMap(\.authors).filter { author != nil && $0.login?.lowercased() == author }.map { $0.email.lowercased() })
        func isAuthor(_ email:String) -> Bool {
            guard let author else { return false }
            let email=email.lowercased()
            return authorEmails.contains(email) || email == author+"@users.noreply.github.com" || email.hasSuffix("+"+author+"@users.noreply.github.com")
        }
        var seen:Set<String>=[],result:[String]=[]
        func add(_ line:String,email:String,login:String?) {
            let keys=["email:"+email.lowercased()]+(login.map { ["login:"+$0.lowercased()] } ?? [])
            guard !email.isEmpty,!isAuthor(email),seen.isDisjoint(with:keys) else { return }
            seen.formUnion(keys);result.append(line)
        }
        for commit in commits {
            for a in commit.authors where author == nil || a.login?.lowercased() != author { add("Co-authored-by: \(a.name) <\(a.email)>",email:a.email,login:a.login) }
            for line in trailers(in:commit.body) { add(line,email:email(of:line) ?? line,login:nil) }
        }
        return result
    }
    /// Normalized `Co-authored-by` lines in `text`, deduplicated by email.
    public static func trailers(in text:String) -> [String] {
        var seen:Set<String>=[]
        return text.components(separatedBy:.newlines).compactMap(parse).filter { seen.insert(identity($0)).inserted }
    }
    /// Appends only missing trailers; idempotent and byte-identical when nothing is missing.
    public static func ensuring(trailers wanted:[String],in text:String) -> String {
        var present=Set(trailers(in:text).map(identity))
        let missing=wanted.compactMap(parse).filter { present.insert(identity($0)).inserted }
        guard !missing.isEmpty else { return text }
        var trimmed=text
        while let last=trimmed.last,last.isWhitespace { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return missing.joined(separator:"\n") }
        let lastLine=trimmed.components(separatedBy:.newlines).last ?? ""
        return trimmed+(parse(lastLine) == nil ? "\n\n" : "\n")+missing.joined(separator:"\n")
    }
    private static func parse(_ line:String) -> String? {
        let line=line.trimmingCharacters(in:.whitespaces),key="co-authored-by:"
        guard line.lowercased().hasPrefix(key) else { return nil }
        let value=line.dropFirst(key.count).trimmingCharacters(in:.whitespaces)
        guard let open=value.lastIndex(of:"<"),value.hasSuffix(">"),value.index(after:open)<value.index(before:value.endIndex) else { return nil }
        let name=value[..<open].trimmingCharacters(in:.whitespaces),email=value[value.index(after:open)..<value.index(before:value.endIndex)]
        return "Co-authored-by: \(name) <\(email)>"
    }
    private static func email(of line:String) -> String? {
        guard let open=line.lastIndex(of:"<"),line.hasSuffix(">") else { return nil }
        return String(line[line.index(after:open)..<line.index(before:line.endIndex)])
    }
    private static func identity(_ line:String) -> String { (email(of:line) ?? line).lowercased() }
}
/// Editable commit text for one PR presentation. Unedited fields follow the current method's default;
/// setters record an edit only when the value differs from that default. Edits are sticky: switching
/// method or refreshing defaults never clears one, even when it equals a later default; only
/// `resetToDefault()` (or typing the current default) does.
public struct MergeCommitText:Sendable,Equatable {
    public private(set) var method:MergeMethod
    public private(set) var defaults:MergeMessageDefaults?
    private var editedTitle:String?
    private var editedMessage:String?
    public init(method:MergeMethod = .squash,defaults:MergeMessageDefaults?=nil) { self.method=method;self.defaults=defaults }
    public var defaultTitle:String { defaults?.titles[method] ?? "" }
    public var defaultMessage:String { defaults?.bodies[method] ?? "" }
    public var title:String { get { editedTitle ?? defaultTitle } set { editedTitle=newValue == defaultTitle ? nil : newValue } }
    public var message:String { get { editedMessage ?? defaultMessage } set { editedMessage=newValue == defaultMessage ? nil : newValue } }
    public var titleEdited:Bool { editedTitle != nil }
    public var messageEdited:Bool { editedMessage != nil }
    /// True when nothing is sent for the title AND no prefill is shown: the field is blank only as a
    /// placeholder (missing prefill, or a blank headline that is never an override), so GitHub applies its default.
    public var titleUsesProviderDefault:Bool { acceptsText && (editedTitle.map { $0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty } ?? (defaults?.titles[method] == nil)) }
    /// True when the message is unedited and no prefill is known for this method; a deliberately blank edit is sent.
    public var messageUsesProviderDefault:Bool { acceptsText && editedMessage == nil && defaults?.bodies[method] == nil }
    /// Rebase merges have no commit text.
    public var acceptsText:Bool { method != .rebase }
    /// Switches method and/or replaces defaults. Only unedited fields change; an edit that happens to
    /// equal a (possibly temporary) default stays an edit, e.g. a blank squash body across a rebase detour.
    public mutating func applyDefaults(_ defaults:MergeMessageDefaults?,method:MergeMethod) { self.defaults=defaults;self.method=method }
    public mutating func resetToDefault() { editedTitle=nil;editedMessage=nil }
    /// Values to send. Nil means "let GitHub apply its own default", and is always nil for rebase and
    /// for actions other than direct merge/enable auto-merge. A blank title is never an override.
    public func overrides(keepTrailers:Bool=true,action:MergeAction = .direct) -> (title:String?,message:String?) {
        guard method != .rebase,[.direct,.enableAutoMerge].contains(action) else { return (nil,nil) }
        let title=editedTitle.flatMap { $0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil : $0 }
        let message=editedMessage.map { keepTrailers && method == .squash ? MergeMessageComposer.ensuring(trailers:defaults?.coAuthorTrailers ?? [],in:$0) : $0 }
        return (title,message)
    }
}
