import XCTest
@testable import MergeProCore

/// The asset API redirects to `destination`; every other URL serves the asset bytes.
private func assetTransport(destination:String) async -> RoutingTransport {
    let transport=RoutingTransport()
    await transport.route(path:"/repos/o/r/releases/assets/1") { GitHubResponse(status:302,headers:["Location":destination],responseURL:$0.url) }
    await transport.route { GitHubResponse(status:200,data:Data("abc".utf8),responseURL:$0.url) }
    return transport
}
final class RepositoryAssetTests:XCTestCase,@unchecked Sendable {
    func testAllowlistedReleaseRedirectStripsCredential() async throws {
        let transport=await assetTransport(destination:"https://release-assets.githubusercontent.com/github-production-release-asset/file?signature=signed")
        let client=GitHubHTTPClient(transport:transport)
        let data=try await RepositoryAssetDownload.download(client:client,repository:"o/r",asset:RepositoryReleaseAsset(id:1,name:"asset.zip",size:3,downloadURL:nil),token:"secret")
        XCTAssertEqual(String(decoding:data,as:UTF8.self),"abc")
        let headers=await transport.requests.map { $0.value(forHTTPHeaderField:"Authorization") };XCTAssertEqual(headers.count,2);XCTAssertEqual(headers[0],"Bearer secret");XCTAssertNil(headers[1])
    }
    func testUntrustedAssetRedirectIsRejectedBeforeCredentialOrAnonymousRequest() async throws {
        let transport=await assetTransport(destination:"https://evil.example/asset")
        do { _ = try await RepositoryAssetDownload.download(client:GitHubHTTPClient(transport:transport),repository:"o/r",asset:RepositoryReleaseAsset(id:1,name:"asset.zip",size:3,downloadURL:nil),token:"secret");XCTFail() } catch { XCTAssertEqual(error as? GitHubFailure,.unsafeURL) }
        let headers=await transport.requests.map { $0.value(forHTTPHeaderField:"Authorization") };XCTAssertEqual(headers.count,1)
    }
    func testSavedAssetNamesCannotBeHiddenDotfilesOrContainSeparatorsOrControls() throws {
        let folder=try makeTemporaryDirectory(prefix:"MergePro-Asset")
        let expected=[".zshenv":"zshenv","...profile":"profile","../.bashrc":"bashrc"," ..ssh config":"ssh config","a\u{1}b\nc\u{7F}d\u{202E}gpj.zip":"abcdgpj.zip","sub/dir/":"dir","x:y\\z.tar.gz":"xyz.tar.gz"]
        for (name,clean) in expected {
            let url=try RepositoryAssetDownload.save(Data("x".utf8),name:name,directory:folder)
            XCTAssertEqual(url.lastPathComponent,clean,name);XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path,folder.standardizedFileURL.path)
        }
        for name in ["",".","..","...","/",". .","\u{0}\u{1}","\n.\t"] {
            XCTAssertThrowsError(try RepositoryAssetDownload.save(Data("x".utf8),name:name,directory:folder),name) { XCTAssertEqual($0 as? RepositoryBrowserFailure,.invalidAsset) }
        }
        let saved=try FileManager.default.contentsOfDirectory(atPath:folder.path)
        XCTAssertFalse(saved.contains { $0.hasPrefix(".") })
    }
}
