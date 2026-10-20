import CryptoKit
import Foundation
import Synchronization
import SwiftTreeSitter
import TreeSitterSwift
import TreeSitterJavaScript
import TreeSitterTypeScript
import TreeSitterTSX
import TreeSitterPython
import TreeSitterJSON
import TreeSitterYAML
import TreeSitterBash
import TreeSitterMarkdown
import TreeSitterMarkdownInline

public struct CodeToken: Sendable, Equatable {
    public let range:NSRange;public let scopes:[String]
    public init(range:NSRange,scopes:[String]) { self.range=range;self.scopes=scopes }
}
public struct CodeSymbol: Sendable, Equatable { public let name:String;public let range:NSRange }
public struct HighlightResult:Sendable {
    public enum Engine:String,Sendable { case treeSitter,textMate,lexical,plainText }
    public let engine:Engine
    public let tokens:[CodeToken]
    public let symbols:[CodeSymbol]
    public let fallbackReason:String?
}
/// Tokenizes off the caller's actor. Each call owns its parser, cursor, JavaScriptCore context and native
/// scanners, so up to `maximumConcurrentParses` Tree-sitter parses run at once (both sides of a diff, for
/// example); TextMate work stays one at a time. Only values leave a call: compiled highlight queries are
/// immutable and shared per language, and recent results are reused by content hash and language.
public actor CodeTokenizer {
    public static let shared=CodeTokenizer()
    nonisolated let parses:ParseGate
    nonisolated let textMateTurns=ParseGate(limit:1)
    nonisolated let queries=HighlightQueryCache()
    nonisolated let results:HighlightResultCache
    public init(maximumConcurrentParses:Int = max(2,min(4,ProcessInfo.processInfo.activeProcessorCount/2)),cachedResults:Int = 16,cachedTokens:Int = 250_000) {
        parses=ParseGate(limit:max(2,maximumConcurrentParses))
        results=HighlightResultCache(maximumEntries:cachedResults,maximumTokens:cachedTokens)
    }
    @concurrent public nonisolated func tokenize(_ source:String,path:String,languageOverride:String? = nil) async -> HighlightResult {
        guard !Task.isCancelled,source.utf8.count <= 2_000_000,source.components(separatedBy:"\n").allSatisfy({ $0.utf16.count <= 32768 }) else { return Self.plain("Highlighting size or cancellation limit") }
        guard let language=Self.language(path:path,source:source,override:languageOverride) else { return Self.plain("No bundled grammar available; plain text retained") }
        let key=HighlightResultCache.Key(source:source,language:language)
        if let cached=results.value(for:key) { return cached }
        let gate=language == "ini" ? textMateTurns : parses
        await gate.acquire();defer { gate.release() }
        guard !Task.isCancelled else { return Self.plain("Highlighting size or cancellation limit") }
        let result=highlight(source,language:language)
        // Cancelled or over-budget work is not a stable answer for this content, so it is never reused.
        if !Task.isCancelled,result.engine != .plainText { results.insert(result,for:key) }
        return result
    }
    private nonisolated func highlight(_ source:String,language:String) -> HighlightResult {
        if ["css","html"].contains(language) {
            return .init(engine:.lexical,tokens:WebSourceTokenizer.tokenize(source,language:language),symbols:[],fallbackReason:nil)
        }
        if language != "ini" {
            do { return try treeSitter(source,language:language) }
            catch TokenizerFailure.budget { return Self.plain("Highlighting time limit; plain text retained") }
            catch {}
        }
        if language == "ini" {
            do {
                guard let url=Bundle.module.url(forResource:"ini.tmLanguage",withExtension:"json",subdirectory:"Resources") else { throw TokenizerFailure.grammar }
                return .init(engine:.textMate,tokens:try TextMateTokenizer().tokenize(source,grammar:Data(contentsOf:url)),symbols:[],fallbackReason:nil)
            } catch { return Self.plain("TextMate grammar or execution limit; plain text retained") }
        }
        return Self.plain("No bundled grammar available; plain text retained")
    }
    func scan(patterns:[String],text:String,start:Int,flags:Int = 0) throws -> ScannerMatch? { try NativeScanner(patterns:patterns).search(text,start:start,flags:flags) }
    func textMate(_ source:String,grammar:Data,dependencies:[Data] = []) throws -> [CodeToken] { try TextMateTokenizer().tokenize(source,grammar:grammar,dependencies:dependencies) }
    private static func plain(_ reason:String) -> HighlightResult { .init(engine:.plainText,tokens:[],symbols:[],fallbackReason:reason) }
    public static func language(path:String,source:String,override:String?) -> String? {
        let known=["swift","javascript","typescript","tsx","python","json","yaml","bash","markdown","ini","css","html"]
        if let override,known.contains(override.lowercased()) { return override.lowercased() }
        let ext=URL(fileURLWithPath:path).pathExtension.lowercased()
        let extensions=["swift":"swift","js":"javascript","jsx":"javascript","mjs":"javascript","cjs":"javascript","ts":"typescript","mts":"typescript","cts":"typescript","tsx":"tsx","py":"python","json":"json","yaml":"yaml","yml":"yaml","sh":"bash","bash":"bash","zsh":"bash","md":"markdown","markdown":"markdown","ini":"ini","cfg":"ini","css":"css","html":"html","htm":"html"]
        if let language=extensions[ext] { return language }
        let first=source.prefix(200).components(separatedBy:"\n").first ?? ""
        if first.hasPrefix("#!") { if first.contains("python") { return "python" };if first.contains("bash") || first.contains("zsh") || first.hasSuffix("/sh") || first.hasSuffix(" sh") { return "bash" };if first.contains("node") { return "javascript" } }
        return nil
    }
    static func grammar(_ name:String) throws -> Language {
        let pointer:OpaquePointer?
        switch name {
        case "swift":pointer=tree_sitter_swift()
        case "javascript":pointer=tree_sitter_javascript()
        case "typescript":pointer=tree_sitter_typescript()
        case "tsx":pointer=tree_sitter_tsx()
        case "python":pointer=tree_sitter_python()
        case "json":pointer=tree_sitter_json()
        case "yaml":pointer=tree_sitter_yaml()
        case "bash":pointer=tree_sitter_bash()
        case "markdown":pointer=tree_sitter_markdown()
        default:throw TokenizerFailure.grammar
        }
        guard let pointer else { throw TokenizerFailure.grammar }
        return Language(language:pointer)
    }
    /// Reads and compiles one language's bundled highlight query; `HighlightQueryCache` keeps the result.
    static func compileHighlightQuery(_ name:String) throws -> Query {
        let folder=name == "tsx" ? "typescript" : name
        var relative="\(folder)/queries/highlights.scm"
        if name == "markdown" { relative="markdown/tree-sitter-markdown/queries/highlights.scm" }
        guard let url=Bundle.module.url(forResource:relative,withExtension:nil,subdirectory:"Resources/Queries") else { throw TokenizerFailure.grammar }
        var querySource=try String(contentsOf:url,encoding:.utf8)
        if ["typescript","tsx"].contains(name),let js=Bundle.module.url(forResource:"javascript/queries/highlights.scm",withExtension:nil,subdirectory:"Resources/Queries") { querySource=try String(contentsOf:js,encoding:.utf8)+"\n"+querySource }
        return try Query(language:grammar(name),data:Data(querySource.utf8))
    }
    private nonisolated func treeSitter(_ source:String,language name:String) throws -> HighlightResult {
        let ns=source as NSString,length=ns.length
        let language=try Self.grammar(name),parser=Parser();try parser.setLanguage(language);parser.timeout=0.2
        guard let tree=parser.parse(source),let root=tree.rootNode else { throw TokenizerFailure.budget }
        let query=try queries.query(name),cursor=query.execute(in:tree)
        cursor.matchLimit=10000
        let context=Predicate.Context(textProvider:{ range,_ in
            guard NSMaxRange(range) <= length else { return nil };return ns.substring(with:range)
        },groupMembershipProvider:{ _,_,_ in false })
        var tokens:[CodeToken]=[]
        let deadline=ContinuousClock.now.advanced(by:.milliseconds(400))
        for match in cursor.resolve(with:context) {
            guard !Task.isCancelled,ContinuousClock.now < deadline,tokens.count < 100000 else { throw TokenizerFailure.budget }
            for capture in match.captures {
                guard let scope=capture.name,NSMaxRange(capture.range) <= length else { continue }
                tokens.append(.init(range:capture.range,scopes:[scope]))
            }
        }
        var symbols:[CodeSymbol]=[],stack=[root],visited=0
        while let node=stack.popLast() {
            visited += 1;guard visited <= 200000,!Task.isCancelled,ContinuousClock.now < deadline else { throw TokenizerFailure.budget }
            if let type=node.nodeType,["function_declaration","class_declaration","struct_declaration","function_definition","class_definition","method_declaration"].contains(type) {
                let named=node.child(byFieldName:"name") ?? node
                if NSMaxRange(named.range) <= length { symbols.append(.init(name:String(ns.substring(with:named.range).prefix(120)),range:node.range)) }
            }
            for index in 0..<node.childCount { if let child=node.child(at:index) { stack.append(child) } }
        }
        return .init(engine:.treeSitter,tokens:tokens,symbols:symbols.sorted { $0.range.location < $1.range.location },fallbackReason:nil)
    }
}

/// Bounds concurrent parses; waiters take freed slots in arrival order.
final class ParseGate:Sendable {
    private struct State { var available:Int;var waiters:[CheckedContinuation<Void,Never>]=[];var active=0;var peak=0 }
    private let state:Mutex<State>
    let limit:Int
    init(limit:Int) { self.limit=max(1,limit);state=Mutex(State(available:max(1,limit))) }
    /// Most slots held at once since creation.
    var peak:Int { state.withLock { $0.peak } }
    func acquire() async {
        if state.withLock({ Self.take(&$0) }) { return }
        await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in
            let now=state.withLock { state -> Bool in
                if Self.take(&state) { return true }
                state.waiters.append(continuation);return false
            }
            if now { continuation.resume() }
        }
    }
    func release() {
        // A waiter inherits the slot directly, so a newcomer cannot overtake it.
        let next=state.withLock { state -> CheckedContinuation<Void,Never>? in
            guard !state.waiters.isEmpty else { state.available += 1;state.active -= 1;return nil }
            return state.waiters.removeFirst()
        }
        next?.resume()
    }
    private static func take(_ state:inout State) -> Bool {
        guard state.available > 0 else { return false }
        state.available -= 1;state.active += 1;state.peak=max(state.peak,state.active);return true
    }
}

/// Compiled queries are immutable after creation, so one per language serves every concurrent cursor.
final class HighlightQueryCache:Sendable {
    private struct State { var queries:[String:Query]=[:];var compiles=0 }
    private let state=Mutex(State())
    var compileCount:Int { state.withLock { $0.compiles } }
    func query(_ language:String) throws -> Query {
        if let cached=state.withLock({ $0.queries[language] }) { return cached }
        // Compiling outside the lock lets other languages proceed; a concurrent duplicate keeps the first query.
        let compiled=try CodeTokenizer.compileHighlightQuery(language)
        return state.withLock { state in
            state.compiles += 1
            if let existing=state.queries[language] { return existing }
            state.queries[language]=compiled;return compiled
        }
    }
}

/// A small least-recently-used cache of finished results, keyed by a SHA-256 of the source plus its language,
/// so reopening a file or diff side at the same content skips parsing. Bounded by entries and total tokens.
final class HighlightResultCache:Sendable {
    struct Key:Hashable,Sendable {
        let digest:[UInt8];let utf16Count:Int;let language:String
        init(source:String,language:String) {
            digest=source.utf8.withContiguousStorageIfAvailable { Array(SHA256.hash(data:UnsafeRawBufferPointer($0))) } ?? Array(SHA256.hash(data:Data(source.utf8)))
            utf16Count=source.utf16.count;self.language=language
        }
    }
    private struct State { var entries:[(key:Key,result:HighlightResult)]=[];var hits=0 }
    private let state=Mutex(State())
    let maximumEntries:Int,maximumTokens:Int
    init(maximumEntries:Int,maximumTokens:Int) { self.maximumEntries=max(0,maximumEntries);self.maximumTokens=max(0,maximumTokens) }
    var hitCount:Int { state.withLock { $0.hits } }
    var count:Int { state.withLock { $0.entries.count } }
    func value(for key:Key) -> HighlightResult? {
        state.withLock { state in
            guard let index=state.entries.firstIndex(where:{ $0.key == key }) else { return nil }
            let entry=state.entries.remove(at:index);state.entries.append(entry);state.hits += 1;return entry.result
        }
    }
    func insert(_ result:HighlightResult,for key:Key) {
        guard maximumEntries > 0,result.tokens.count <= maximumTokens else { return }
        state.withLock { state in
            state.entries.removeAll { $0.key == key };state.entries.append((key,result))
            var tokens=state.entries.reduce(0) { $0+$1.result.tokens.count }
            while state.entries.count > maximumEntries || tokens > maximumTokens { tokens -= state.entries.removeFirst().result.tokens.count }
        }
    }
}
