import Foundation
import MergeProCore

enum PRDetailFixtures {
    static func blob(_ pr:PullRequest,path:String,sha:String) -> Data {
        if path.hasSuffix("swift") { return Data(snapshot(pr).files[0].lines.map(\.text).joined(separator:"\n").utf8) }
        if path.hasSuffix("svg") { return Data("<svg><script>neverExecuted()</script></svg>".utf8) }
        return Data("# Inert preview\n\nText **selection** and code.".utf8)
    }
    static func snapshot(_ pr:PullRequest) -> PRDetailSnapshot {
        let count=ProcessInfo.processInfo.environment["MERGEPRO_DETAIL_LINES"].flatMap(Int.init) ?? 5000
        let safeCount=ProcessInfo.processInfo.environment["MERGEPRO_DETAIL_VERIFY"] == "1" ? (pr.metadata?.number == 2 ? 10000 : 5000) : ([5000,10000].contains(count) ? count : 5000)
        let patch="@@ -0,0 +1,\(safeCount) @@\n"+(1...safeCount).map { "+let fixture\($0) = \($0) // 🐈 native selection" }.joined(separator:"\n")
        return .init(body:"# Native detail fixture\n\nText selection, **bold**, and [explicit link](https://example.invalid).\n\n```swift\nlet hello = \"🐈\"\n```",baseSHA:"fixture-base",headSHA:pr.headRevision.rawValue,files:[.init(path:"Sources/Fixture.swift",status:.added,patch:patch,additions:safeCount),.init(path:"Docs/README.md",status:.modified,patch:"@@ -1 +1 @@\n-old\n+new"),.init(path:"assets/diagram.svg",status:.modified,patch:nil)],expectedFiles:4)
    }
}
