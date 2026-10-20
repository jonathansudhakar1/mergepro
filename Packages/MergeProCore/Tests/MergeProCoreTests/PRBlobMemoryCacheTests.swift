import XCTest
@testable import MergeProCore

final class PRBlobMemoryCacheTests:XCTestCase {
    private let a=AccountScope(host:"github.com",accountID:"a"),b=AccountScope(host:"github.com",accountID:"b")
    private func key(_ account:AccountScope,_ path:String,sha:String="s") -> PRBlobMemoryCache.Key { .init(repository:.init(account:account,repositoryID:"1"),sha:sha,path:path) }
    func testOneBoundedCacheEvictsLeastRecentlyUsedFirst() {
        let cache=PRBlobMemoryCache(maximumBytes:400)
        cache.store(Data(count:100),for:key(a,"1"));cache.store(Data(count:100),for:key(a,"2"));cache.store(Data(count:100),for:key(a,"3"))
        XCTAssertNotNil(cache.data(key(a,"1")),"A hit refreshes recency")
        cache.store(Data(count:100),for:key(a,"4"));cache.store(Data(count:100),for:key(a,"5"))
        XCTAssertLessThanOrEqual(cache.byteCount,400)
        XCTAssertNil(cache.data(key(a,"2")));XCTAssertNotNil(cache.data(key(a,"1")));XCTAssertNotNil(cache.data(key(a,"5")))
    }
    func testOversizedBlobIsNotKept() {
        let cache=PRBlobMemoryCache(maximumBytes:400)
        cache.store(Data(count:101),for:key(a,"big"))
        XCTAssertNil(cache.data(key(a,"big")));XCTAssertEqual(cache.byteCount,0)
    }
    func testContentIsScopedToItsAccountAndPurgedWithIt() {
        let memory=PRDetailMemoryCache(blobs:PRBlobMemoryCache(maximumBytes:1_000))
        memory.blobs.store(Data("private".utf8),for:key(a,"x"))
        XCTAssertNil(memory.blobs.data(key(b,"x")),"Another account never reads this account's content")
        memory.blobs.store(Data("other".utf8),for:key(b,"x"))
        memory.purge(account:a)
        XCTAssertNil(memory.blobs.data(key(a,"x")));XCTAssertEqual(memory.blobs.data(key(b,"x")),Data("other".utf8))
        XCTAssertEqual(memory.blobs.byteCount,5)
        memory.removeAll();XCTAssertEqual(memory.blobs.count,0)
    }
}
