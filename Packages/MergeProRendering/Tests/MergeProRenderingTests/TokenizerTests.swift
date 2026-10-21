import XCTest
@testable import MergeProRendering

final class TokenizerTests:XCTestCase {
    func testTextMatePreservesMultilineStateAndUTF16Ranges() async throws {
        let result=await CodeTokenizer.shared.tokenize("name = \"🐈\ncontinued\"\n",path:"settings.ini")
        XCTAssertEqual(result.engine,.textMate)
        XCTAssertTrue(result.tokens.contains { $0.scopes.contains("string.quoted.double.ini") && $0.range.location <= 11 && NSMaxRange($0.range) >= 11 })
        XCTAssertTrue(result.tokens.contains { $0.scopes.contains("string.quoted.double.ini") && $0.range.location >= 11 })
        XCTAssertTrue(result.tokens.allSatisfy { $0.range.location >= 0 && NSMaxRange($0.range) <= 24 })
    }
    func testTreeSitterSymbolsAndUnicodeRangesAreFromFullSource() async throws {
        let source="// 🐈\nfunc hello() { print(\"é\") }\n"
        let result=await CodeTokenizer.shared.tokenize(source,path:"a.swift")
        XCTAssertEqual(result.engine,.treeSitter)
        XCTAssertTrue(result.tokens.contains { $0.scopes.contains(where: { $0.hasPrefix("keyword") }) })
        XCTAssertTrue(result.symbols.contains { $0.name.contains("hello") })
        XCTAssertTrue(result.tokens.allSatisfy { NSMaxRange($0.range) <= source.utf16.count })
    }
    func testUnknownHugeAndCancelledInputsRetainPlainText() async throws {
        let unknown=await CodeTokenizer.shared.tokenize("hello",path:"a.unknown")
        XCTAssertEqual(unknown.engine,.plainText)
        let huge=await CodeTokenizer.shared.tokenize(String(repeating:"x",count:33000),path:"a.ini")
        XCTAssertEqual(huge.engine,.plainText)
        XCTAssertNotNil(huge.fallbackReason)
    }
    func testNativeScannerReturnsEarliestSourceOrderAndUnmatchedCaptures() async throws {
        let values=try await CodeTokenizer.shared.scan(patterns:["(🐈)(x)?","🐈"],text:"é🐈",start:0)
        XCTAssertEqual(values?.index,0)
        XCTAssertEqual(values?.captures.first,NSRange(location:2,length:2))
        XCTAssertEqual(values?.captures.last,NSRange(location:4,length:0))
    }
    func testInvalidRegexAndBudgetErrorsAreStructured() async throws {
        do { _ = try await CodeTokenizer.shared.scan(patterns:["["],text:"a",start:0);XCTFail() } catch {}
        do { _ = try await CodeTokenizer.shared.scan(patterns:["(a+)+$"],text:String(repeating:"a",count:200)+"!",start:0);XCTFail() } catch {}
    }
}

extension TokenizerTests {
    func testAllPinnedLanguageFamiliesLoadAndReturnBoundedRanges() async {
        let fixtures=[("a.js","const x = '🐈';"),("a.ts","interface User { name: string }"),("a.tsx","const x = <div>hi</div>;"),("a.py","def hello():\n    return '🐈'"),("a.json","{\"x\":1}"),("a.yaml","key: value\n"),("a.sh","echo \"$HOME\"\n"),("a.md","# Title\n\n**bold**\n")]
        for (path,source) in fixtures {
            let result=await CodeTokenizer.shared.tokenize(source,path:path)
            XCTAssertEqual(result.engine,.treeSitter,path+": "+(result.fallbackReason ?? ""))
            XCTAssertFalse(result.tokens.isEmpty,path)
            XCTAssertTrue(result.tokens.allSatisfy { NSMaxRange($0.range) <= source.utf16.count },path)
        }
    }
}


extension TokenizerTests {
    func testCSSAndHTMLHaveReadableSyntaxInsteadOfPlainFallback() async {
        for (path, source, comment, string) in [
            ("site.css", "/* note 🐈 */\nbody { color: red; content: \"hello\"; }", "/* note 🐈 */", "\"hello\""),
            ("index.html", "<!-- note 🐈 -->\n<div class=\"hello\">Hi</div>", "<!-- note 🐈 -->", "\"hello\"")
        ] {
            let result=await CodeTokenizer.shared.tokenize(source,path:path)
            XCTAssertNotEqual(result.engine,.plainText,path)
            let ns=source as NSString
            XCTAssertTrue(result.tokens.contains { $0.scopes.contains(where: { $0.contains("comment") }) && ns.substring(with:$0.range)==comment },path)
            XCTAssertTrue(result.tokens.contains { $0.scopes.contains(where: { $0.contains("string") }) && ns.substring(with:$0.range)==string },path)
            XCTAssertTrue(result.tokens.allSatisfy { $0.range.location>=0 && NSMaxRange($0.range)<=ns.length })
        }
    }
    func testCommonModuleExtensionsAndShellShebangsChooseTheirGrammar() {
        for (path, source, expected) in [("file.cjs", "", "javascript"), ("file.mts", "", "typescript"), ("file.cts", "", "typescript"), ("file.zsh", "", "bash"), ("script", "#!/usr/bin/env sh\necho hi", "bash"), ("script", "#!/bin/zsh\necho hi", "bash")] {
            XCTAssertEqual(CodeTokenizer.language(path:path,source:source,override:nil),expected,path)
        }
    }
}

extension TokenizerTests {
    /// Scanning once is linear: 4x the input costs about 4x, where rescanning every suffix would cost about 16x.
    /// (The 2 ms floor keeps sub-millisecond noise from deciding.) Absolute caps need MERGEPRO_PERF_TESTS=1.
    func testWebIdentifierNoMatchDoesNotRescanEverySuffix() {
        let source=String(repeating:"a",count:8192),quarter=String(repeating:"a",count:2048)
        XCTAssertTrue(WebSourceTokenizer.tokenize(source,language:"css").isEmpty)
        let full=fastestDuration { _ = WebSourceTokenizer.tokenize(source,language:"css") }
        let small=fastestDuration { _ = WebSourceTokenizer.tokenize(quarter,language:"css") }
        XCTAssertLessThan(full,max(small,.milliseconds(2))*10,"a long identifier without ':' or '{' must be scanned once, not once per suffix")
        XCTAssertWithinPerformanceBudget(full,.milliseconds(500),"a long identifier without ':' or '{' must be scanned once, not once per suffix")
    }
    func testWebScannerStaysBoundedAtLineLimitAndAcrossUnterminatedLexemes() {
        // Each input at full size (divisor 1) and a quarter of it (divisor 4).
        let inputs:[(String,(Int) -> String)]=[
            ("css",{ String(repeating:"a",count:32768/$0) }),
            ("html",{ String(repeating:"a",count:32768/$0) }),
            ("css",{ String(repeating:String(repeating:"a",count:8192/$0)+"\n",count:4) }),
            ("html",{ String(repeating:"<!",count:16384/$0) }),
            ("css",{ "\""+String(repeating:"\\\"",count:16380/$0)+"\\" })
        ]
        for (language,make) in inputs {
            let source=make(1),quarter=make(4)
            let result=WebSourceTokenizer.tokenize(source,language:language)
            XCTAssertTrue(result.allSatisfy { NSMaxRange($0.range)<=source.utf16.count })
            let full=fastestDuration { _ = WebSourceTokenizer.tokenize(source,language:language) }
            let small=fastestDuration { _ = WebSourceTokenizer.tokenize(quarter,language:language) }
            XCTAssertLessThan(full,max(small,.milliseconds(2))*10,"\(language) no-match and unterminated lexemes must have bounded scanner work")
            XCTAssertWithinPerformanceBudget(full,.seconds(1),"\(language) no-match and unterminated lexemes must have bounded scanner work")
        }
    }
}

extension TokenizerTests {
    static func typeScript(lines:Int,seed:Int) -> String {
        (0..<lines).map { "export function f\(seed)_\($0)(value: number): string { const label = `${value}`; return label + \"\($0)\" } // note" }.joined(separator:"\n")
    }
    static func seconds(_ duration:Duration) -> Double { Double(duration.components.seconds)+Double(duration.components.attoseconds)/1e18 }
    /// Tiny distinct sources isolate the fixed per-call cost (reading and compiling the highlight query);
    /// large distinct sources measure parse plus query execution, sequentially and as two concurrent diff sides.
    func testTokenizerCompileParseAndConcurrencyEvidence() async throws {
        // Large sources must finish inside the interactive highlighting budget, which shared CI runners can miss.
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "Timing evidence runs on developer Macs, not shared CI runners")
        let tokenizer=CodeTokenizer(),clock=ContinuousClock()
        var tiny:[Double]=[]
        for index in 0..<6 {
            let start=clock.now
            let result=await tokenizer.tokenize("const value\(index): number = \(index)",path:"a.ts")
            tiny.append(Self.seconds(start.duration(to:clock.now)));XCTAssertEqual(result.engine,.treeSitter)
        }
        let sources=(0..<4).map { Self.typeScript(lines:800,seed:$0) }
        var start=clock.now
        let first=await tokenizer.tokenize(sources[0],path:"a.ts"),second=await tokenizer.tokenize(sources[1],path:"a.ts")
        let sequential=Self.seconds(start.duration(to:clock.now))
        start=clock.now
        async let left=tokenizer.tokenize(sources[2],path:"a.ts")
        async let right=tokenizer.tokenize(sources[3],path:"a.ts")
        let (leftResult,rightResult)=await (left,right)
        let concurrent=Self.seconds(start.duration(to:clock.now))
        for result in [first,second,leftResult,rightResult] { XCTAssertEqual(result.engine,.treeSitter,result.fallbackReason ?? "") }
        print("TOKENIZER typescript tinyFirstCall=\(tiny[0]) tinyLaterAverage=\(tiny.dropFirst().reduce(0,+)/5) twoLargeSequential=\(sequential) twoLargeConcurrent=\(concurrent) ratio=\(concurrent/sequential)")
    }
}

extension TokenizerTests {
    func testHighlightQueryCompilesOncePerLanguageAndCostsMoreThanAParse() async throws {
        let tokenizer=CodeTokenizer(),clock=ContinuousClock()
        let compile=try clock.measure { _ = try CodeTokenizer.compileHighlightQuery("typescript") }
        var parses:[Duration]=[]
        for seed in 0..<3 {
            let start=clock.now
            let result=await tokenizer.tokenize(Self.typeScript(lines:20,seed:seed),path:"a.ts")
            parses.append(start.duration(to:clock.now));XCTAssertEqual(result.engine,.treeSitter)
        }
        _ = await tokenizer.tokenize("print('x')",path:"a.py")
        print("TOKENIZER typescript queryCompile=\(compile) twentyLineTokenizeFirst=\(parses[0]) twentyLineTokenizeCachedQuery=\(parses[2])")
        XCTAssertEqual(tokenizer.queries.compileCount,2,"one TypeScript and one Python compile, regardless of how many files")
        XCTAssertWithinPerformanceBudget(parses[2],compile,"a small file with a cached query must cost less than compiling the query")
    }
    func testParseGateAdmitsTwoAtOnceAndQueuesTheRest() async {
        XCTAssertGreaterThanOrEqual(CodeTokenizer.shared.parses.limit,2,"both diff sides must be able to parse at once")
        let gate=ParseGate(limit:2)
        await gate.acquire();await gate.acquire()
        XCTAssertEqual(gate.peak,2)
        let third=Task { await gate.acquire();return true }
        try? await Task.sleep(for:.milliseconds(50))
        XCTAssertEqual(gate.peak,2,"a third parse waits for a free slot")
        gate.release()
        let admitted=await third.value
        XCTAssertTrue(admitted);XCTAssertEqual(gate.peak,2)
        gate.release();gate.release()
        await gate.acquire();await gate.acquire();XCTAssertEqual(gate.peak,2)
    }
    func testConcurrentDiffSidesOverlapOnTheSharedTokenizer() async {
        let tokenizer=CodeTokenizer()
        async let left=tokenizer.tokenize(Self.typeScript(lines:600,seed:91),path:"a.ts")
        async let right=tokenizer.tokenize(Self.typeScript(lines:600,seed:92),path:"a.ts")
        let results=await [left,right]
        XCTAssertTrue(results.allSatisfy { $0.engine == .treeSitter })
        XCTAssertEqual(tokenizer.parses.peak,2,"the two sides of a diff parse at the same time")
    }
    func testResultsAreReusedByContentAndLanguageWithinBounds() async {
        let tokenizer=CodeTokenizer()
        let source=Self.typeScript(lines:5,seed:7)
        let first=await tokenizer.tokenize(source,path:"one.ts"),again=await tokenizer.tokenize(source,path:"renamed/two.ts")
        XCTAssertEqual(tokenizer.results.hitCount,1,"same content and language reuse the parse even under another path")
        XCTAssertEqual(first.tokens,again.tokens);XCTAssertEqual(first.symbols,again.symbols)
        _ = await tokenizer.tokenize(source,path:"one.ts",languageOverride:"javascript")
        XCTAssertEqual(tokenizer.results.hitCount,1,"another language is another result")
        _ = await tokenizer.tokenize(source+" ",path:"one.ts")
        XCTAssertEqual(tokenizer.results.hitCount,1,"any content change is a miss")
        _ = await tokenizer.tokenize("hello",path:"a.unknown")
        XCTAssertEqual(tokenizer.results.count,3,"plain-text fallbacks are not cached")

        let cache=HighlightResultCache(maximumEntries:2,maximumTokens:3)
        func result(_ count:Int) -> HighlightResult { .init(engine:.treeSitter,tokens:Array(repeating:.init(range:NSRange(location:0,length:1),scopes:["x"]),count:count),symbols:[],fallbackReason:nil) }
        let keys=["a","b","c"].map { HighlightResultCache.Key(source:$0,language:"swift") }
        cache.insert(result(1),for:keys[0]);cache.insert(result(1),for:keys[1])
        XCTAssertNotNil(cache.value(for:keys[0]))
        cache.insert(result(1),for:keys[2])
        XCTAssertNil(cache.value(for:keys[1]),"least recently used entry is evicted at the entry bound")
        XCTAssertNotNil(cache.value(for:keys[0]))
        cache.insert(result(3),for:keys[1])
        XCTAssertEqual(cache.count,1,"the token bound evicts older entries")
        cache.insert(result(4),for:keys[2])
        XCTAssertNil(cache.value(for:keys[2]),"a result larger than the whole budget is not cached")
    }
    func testCancelledTokenizationIsNotCached() async {
        let tokenizer=CodeTokenizer()
        let source=Self.typeScript(lines:400,seed:3)
        let task=Task { [tokenizer] in await tokenizer.tokenize(source,path:"a.ts") }
        task.cancel()
        let result=await task.value
        XCTAssertEqual(result.engine,.plainText)
        XCTAssertEqual(tokenizer.results.count,0)
        let fresh=await tokenizer.tokenize(Self.typeScript(lines:400,seed:3),path:"a.ts")
        XCTAssertEqual(fresh.engine,.treeSitter)
    }
}
