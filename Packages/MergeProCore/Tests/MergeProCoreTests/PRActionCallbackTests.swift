import XCTest
@testable import MergeProCore

@MainActor final class PRActionCallbackTests:XCTestCase {
    final class Surface {
        var state=PRActionLoadState()
        var text="",status="",busy=false,payload=""
        func present(_ key:ProviderKey) -> UUID {
            let request=state.begin();state.select(key,request:request)
            XCTAssertTrue(state.present(key,request:request,available:true))
            payload=key.accountID;text="new editor "+key.accountID;status="new status";busy=true
            return request
        }
        func complete(_ key:ProviderKey,_ request:UUID,available:Bool,success:Bool) {
            state.publish(key,request:request,available:available) {
                self.payload=key.accountID;self.text=success ? "" : "failed old editor";self.status=success ? "confirmed" : "failed";self.busy=false
            }
        }
    }
    func key(_ account:String) -> ProviderKey { .init(host:"github.com",accountID:account,repositoryID:"R",objectID:"pull-request:N") }
    func testHeldArchiveReceiptWriteSuccessFailureAndCleanupCannotPublishOverReplacement() async {
        for success in [true,false] {
            let surface=Surface(),old=key("B"),current=key("A")
            let request=surface.present(old)
            let held=Task { @MainActor in
                await Task.yield()
                surface.complete(old,request,available:true,success:success)
            }
            let newer=surface.present(current)
            await held.value
            XCTAssertEqual(surface.payload,"A");XCTAssertEqual(surface.text,"new editor A")
            XCTAssertEqual(surface.status,"new status");XCTAssertTrue(surface.busy)
            XCTAssertTrue(surface.state.isCurrent(newer));XCTAssertTrue(surface.state.canDisplay(current,available:true))
        }
    }
    func testSameKeyReplacementReadAndReauthorizationRetireOldCallbackPermanently() {
        let surface=Surface(),key=key("B"),old=surface.present(key)
        surface.state.invalidate()
        let current=surface.present(key)
        surface.complete(key,old,available:true,success:true)
        XCTAssertEqual(surface.text,"new editor B");XCTAssertTrue(surface.busy)
        XCTAssertTrue(surface.state.isCurrent(current))
        surface.complete(key,current,available:false,success:false)
        XCTAssertEqual(surface.status,"new status")
        surface.complete(key,current,available:true,success:true)
        XCTAssertEqual(surface.status,"confirmed");XCTAssertFalse(surface.busy)
    }
}
