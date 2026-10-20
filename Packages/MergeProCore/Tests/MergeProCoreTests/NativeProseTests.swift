import XCTest
@testable import MergeProCore

@MainActor final class NativeProseTests:XCTestCase {
    func testFlowchartParsesLiteralLabelsAndEdges() throws {
        let graph=try NativeFlowchart.parse("flowchart TD\n A[Build] --> B[Test]\n B --> C[Ship]")
        XCTAssertEqual(graph.nodes.map(\.label),["Build","Test","Ship"])
        XCTAssertEqual(graph.edges.count,2)
        XCTAssertEqual(graph.direction,.vertical)
    }
    func testFlowchartRejectsExecutableUnsupportedAndOversizedSyntax() {
        for source in ["flowchart TD\nA[<script>alert(1)</script>]", "flowchart TD\nclick A href https://evil.invalid", "flowchart TD\nA -->|condition| B", "flowchart TD\n"+String(repeating:"x",count:9000)] {
            XCTAssertThrowsError(try NativeFlowchart.parse(source))
        }
    }
    func testAssetPolicyRejectsCredentialsSignedURLsAndHostSpoofs() {
        for value in ["http://user-images.githubusercontent.com/a.png","https://github.com.evil.invalid/a.png","https://secret@user-images.githubusercontent.com/a.png","https://user-images.githubusercontent.com/a.png?token=secret","https://github.com/o/r/private.png","file:///tmp/image.png"] {
            XCTAssertNil(MarkdownRasterPolicy.approved(URL(string:value)!))
        }
        XCTAssertNotNil(MarkdownRasterPolicy.approved(URL(string:"https://github.com/user-attachments/assets/public-id")!))
    }
    func testAnonymousAssetRedirectNeverSendsCredentialsAnd401IsNotAccountRevocation() async throws {
        let transport=ScriptedTransport([.init(status:302,headers:["Location":"https://user-images.githubusercontent.com/b.png"]),.init(status:200,headers:["Content-Type":"image/png"],data:Data([1,2]))])
        _ = try await MarkdownRasterClient(transport:transport).load(URL(string:"https://user-images.githubusercontent.com/a.png")!)
        let requests=await transport.captured();XCTAssertEqual(requests.count,2)
        for request in requests { XCTAssertNil(request.value(forHTTPHeaderField:"Authorization"));XCTAssertNil(request.value(forHTTPHeaderField:"Cookie"));XCTAssertNil(request.value(forHTTPHeaderField:"Referer")) }
        do { _ = try await MarkdownRasterClient(transport:ScriptedTransport([.init(status:401)])).load(URL(string:"https://user-images.githubusercontent.com/a.png")!);XCTFail() }
        catch { XCTAssertEqual(error as? MarkdownRasterFailure,.unavailable);XCTAssertNil(error as? GitHubFailure) }
    }
    func testExternalRedirectHTMLAndOversizedRasterFailClosed() async throws {
        for response in [GitHubResponse(status:302,headers:["Location":"https://evil.invalid/pixel"]),.init(status:200,headers:["Content-Type":"text/html"],data:Data("<script>evil</script>".utf8)),.init(status:200,headers:["Content-Type":"image/png"],data:Data(repeating:0,count:2_000_001))] {
            let transport=ScriptedTransport([response])
            do { _ = try await MarkdownRasterClient(transport:transport).load(URL(string:"https://user-images.githubusercontent.com/a.png")!);XCTFail() } catch {}
            let requests=await transport.captured();XCTAssertEqual(requests.count,1)
        }
    }
}
