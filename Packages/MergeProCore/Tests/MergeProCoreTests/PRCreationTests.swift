import XCTest
@testable import MergeProCore

final class PRCreationTests: XCTestCase {
    func testForkHeadPreservesOwnerAndRejectsMissingForkRepository() throws {
        let key=ProviderKey(host:"github.com",accountID:"a",repositoryID:"r",objectID:"repository")
        let valid=CreatePRCommand(repository:key,repositoryName:"upstream/project",head:"octo:feature",base:"main",title:"Feature",body:"",draft:true,reviewers:["reviewer"],headRepository:"octo/project")
        XCTAssertNoThrow(try valid.validate())
        let missing=CreatePRCommand(repository:key,repositoryName:"upstream/project",head:"octo:feature",base:"main",title:"Feature",body:"",draft:true,reviewers:[])
        XCTAssertThrowsError(try missing.validate())
    }
    func testCreationRejectsSameBranchAndEmptyTitle() {
        let key=ProviderKey(host:"github.com",accountID:"a",repositoryID:"r",objectID:"repository")
        XCTAssertThrowsError(try CreatePRCommand(repository:key,repositoryName:"o/r",head:"main",base:"main",title:"Title",body:"",draft:false,reviewers:[]).validate())
        XCTAssertThrowsError(try CreatePRCommand(repository:key,repositoryName:"o/r",head:"feature",base:"main",title:" ",body:"",draft:false,reviewers:[]).validate())
    }
}
