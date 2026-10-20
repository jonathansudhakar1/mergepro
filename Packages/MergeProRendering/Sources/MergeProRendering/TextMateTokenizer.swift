import Foundation
import JavaScriptCore

/// All JS values, rule stacks and native scanner IDs live within this synchronous worker turn.
final class TextMateTokenizer {
    private let context:JSContext
    private var scanners:[Int:NativeScanner]=[:]
    private var nextID=0
    private var failed=false
    init() throws {
        guard let context=JSContext() else { throw TokenizerFailure.grammar };self.context=context
        let create:@convention(block) ([String])->Int = { [weak self] patterns in
            guard let self,self.scanners.count < 512 else { return -1 }
            do { let scanner=try NativeScanner(patterns:patterns);let id=self.nextID;self.nextID += 1;self.scanners[id]=scanner;return id }
            catch { self.failed=true;return -1 }
        }
        let search:@convention(block) (Int,String,Int,Int)->Any = { [weak self] id,text,start,flags in
            guard let self,let scanner=self.scanners[id] else { return ["error":true] }
            do {
                guard let value=try scanner.search(text,start:start,flags:flags) else { return NSNull() }
                return ["index":value.index,"captureIndices":value.captures.map { ["start":$0.location,"end":NSMaxRange($0),"length":$0.length] }] as [String:Any]
            } catch { self.failed=true;return ["error":true] }
        }
        let dispose:@convention(block) (Int)->Void = { [weak self] id in self?.scanners[id]=nil }
        context.setObject(create,forKeyedSubscript:"nativeCreate" as NSString)
        context.setObject(search,forKeyedSubscript:"nativeSearch" as NSString)
        context.setObject(dispose,forKeyedSubscript:"nativeDispose" as NSString)
        for name in ["vscode-textmate","tokenizer"] {
            guard let url=Bundle.module.url(forResource:name,withExtension:"js",subdirectory:"Resources") else { throw TokenizerFailure.grammar }
            context.evaluateScript(try String(contentsOf:url,encoding:.utf8))
            guard context.exception == nil else { throw TokenizerFailure.grammar }
        }
    }
    func tokenize(_ source:String,grammar:Data,dependencies:[Data] = []) throws -> [CodeToken] {
        let object=try JSONSerialization.jsonObject(with:grammar)
        let others=try dependencies.map { try JSONSerialization.jsonObject(with:$0) }
        context.objectForKeyedSubscript("prepareGrammar").call(withArguments:[object,others])
        guard context.exception == nil,context.objectForKeyedSubscript("activeGrammar").isObject else { throw TokenizerFailure.grammar }
        var offset=0;var tokens:[CodeToken]=[]
        let deadline=ContinuousClock.now.advanced(by:.seconds(2))
        for line in source.components(separatedBy:"\n") {
            try Task.checkCancellation();guard ContinuousClock.now < deadline,line.utf16.count <= 32768 else { throw TokenizerFailure.budget }
            guard let values=context.objectForKeyedSubscript("tokenizeSourceLine").call(withArguments:[line])?.toArray() as? [[String:Any]],context.exception == nil,!failed else { throw TokenizerFailure.grammar }
            for value in values {
                guard let lo=value["startIndex"] as? Int,let rawEnd=value["endIndex"] as? Int,let scopes=value["scopes"] as? [String] else { throw TokenizerFailure.grammar }
                let hi=min(line.utf16.count,rawEnd)
                guard lo >= 0,hi >= lo else { throw TokenizerFailure.invalidRange }
                if hi > lo { tokens.append(.init(range:NSRange(location:offset+lo,length:hi-lo),scopes:scopes)) }
            }
            offset += line.utf16.count+1
        }
        return tokens
    }
}
