import XCTest
@testable import MergeProCore
final class ReviewTransportTests:XCTestCase {
    let key=ProviderKey(host:"github.com",accountID:"42",repositoryID:"1",objectID:"PR1")
    func testPendingFileThreadKeepsAssociationWithoutInventingLineOrCommitInput() throws {
        let doc=DiffDocument(baseSHA:"origin",headSHA:"reviewed",files:[.init(path:"new",previousPath:"old",status:.renamed,patch:"@@ -1 +1 @@\n-old\n+new")],expectedFiles:1)
        let file=try ReviewDraftComment(fileBody:"file draft",path:"new",document:doc,revision:.init(head:doc.headSHA,origin:doc.baseSHA,target:doc.baseSHA))
        let op=PRWriteOperation(command:.init(key:key,repository:"o/r",number:1,revision:.init(head:"reviewed",origin:"origin",target:"tip"),intent:.thread(file,pendingReviewID:"pending")))
        let request=try GitHubPRWriteAdapter.request(op)
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:request.body) as? [String:Any]);let variables=try XCTUnwrap(json["variables"] as? [String:Any]);let input=try XCTUnwrap(variables["input"] as? [String:Any])
        XCTAssertEqual(input["subjectType"] as? String,"FILE");XCTAssertEqual(input["pullRequestReviewId"] as? String,"pending")
        XCTAssertNil(input["line"]);XCTAssertNil(input["commitOID"])
    }
    func testLeftMultilineCreationUsesReviewedHeadAndCanonicalProviderPath() throws {
        let file=DiffFile(path:"new",previousPath:"old",status:.renamed,patch:"@@ -1,2 +1,2 @@\n-old\n-deleted\n+new\n+replacement")
        let doc=DiffDocument(baseSHA:"origin",headSHA:"reviewed",files:[file],expectedFiles:1)
        let comment=try ReviewDraftComment(body:"line draft",anchor:doc.anchor(file:file,side:.left,start:1,end:2),document:doc,revision:.init(head:doc.headSHA,origin:doc.baseSHA,target:doc.baseSHA))
        let op=PRWriteOperation(command:.init(key:key,repository:"o/r",number:1,revision:.init(head:"reviewed",origin:"origin",target:"tip"),intent:.thread(comment,pendingReviewID:nil)))
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:GitHubPRWriteAdapter.request(op).body) as? [String:Any])
        XCTAssertEqual(json["commit_id"] as? String,"reviewed");XCTAssertEqual(json["path"] as? String,"new")
        XCTAssertEqual(json["side"] as? String,"LEFT");XCTAssertEqual(json["start_line"] as? Int,1);XCTAssertEqual(json["line"] as? Int,2)
    }
    func testPendingReviewUsesCommitOIDAndNeverEventOrBatchFileSubjects() throws {
        let op=PRWriteOperation(command:.init(key:key,repository:"o/r",number:1,revision:.init(head:"reviewed",origin:"origin",target:"tip"),intent:.createPending("summary")))
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:GitHubPRWriteAdapter.request(op).body) as? [String:Any]);let input=try XCTUnwrap((json["variables"] as? [String:Any])?["input"] as? [String:Any])
        XCTAssertEqual(input["commitOID"] as? String,"reviewed");XCTAssertNil(input["event"]);XCTAssertNil(input["threads"])
    }
}

extension ReviewTransportTests {
    func testMetadataRoutesAndGraphQLWriteInputsMatchDocumentedFields() throws {
        let revision=PRWriteRevision(head:"reviewed",origin:"origin",target:"tip")
        func request(_ intent:PRWriteIntent) throws -> GitHubPRWriteAdapter.Request { try GitHubPRWriteAdapter.request(.init(command:.init(key:key,repository:"o/r",number:1,revision:revision,intent:intent))) }
        let cases:[(PRMetadataMutation,String,String,String)]=[
            (.title("Title"),"repos/o/r/pulls/1","PATCH","title"),(.body("Body"),"repos/o/r/pulls/1","PATCH","body"),(.base("release"),"repos/o/r/pulls/1","PATCH","base"),(.closed(true),"repos/o/r/pulls/1","PATCH","state"),(.labels(["bug"]),"repos/o/r/issues/1","PATCH","labels"),(.assignees(["actor"]),"repos/o/r/issues/1","PATCH","assignees"),(.milestone(nil),"repos/o/r/issues/1","PATCH","milestone"),(.reviewers(users:["actor"],teams:["team"],remove:false),"repos/o/r/pulls/1/requested_reviewers","POST","team_reviewers"),(.reviewers(users:["actor"],teams:[],remove:true),"repos/o/r/pulls/1/requested_reviewers","DELETE","reviewers")]
        for (mutation,path,method,field) in cases { let result=try request(.metadata(mutation));XCTAssertEqual(result.path,path);XCTAssertEqual(result.method,method);let body=try XCTUnwrap(JSONSerialization.jsonObject(with:result.body) as? [String:Any]);XCTAssertNotNil(body[field]) }
        let graph:[(PRWriteIntent,String,String)]=[
            (.metadata(.draft(true)),"convertPullRequestToDraft","pullRequestId"),(.metadata(.draft(false)),"markPullRequestReadyForReview","pullRequestId"),(.editComment(id:"C1",kind:.review,body:"new"),"updatePullRequestReviewComment","pullRequestReviewCommentId"),(.editComment(id:"C1",kind:.conversation,body:"new"),"updateIssueComment","id"),(.deleteComment(id:"C1",kind:.review),"deletePullRequestReviewComment","id"),(.deleteComment(id:"C1",kind:.conversation),"deleteIssueComment","id"),(.reply(threadID:"T1",body:"reply",pendingReviewID:"R1"),"addPullRequestReviewThreadReply","pullRequestReviewThreadId"),(.resolve(threadID:"T1",resolved:true),"resolveReviewThread","threadId"),(.resolve(threadID:"T1",resolved:false),"unresolveReviewThread","threadId"),(.reaction(subjectID:"C1",reaction:.heart,remove:false),"addReaction","subjectId"),(.reaction(subjectID:"C1",reaction:.heart,remove:true),"removeReaction","subjectId"),(.moderate(subjectID:"C1",classifier:"OUTDATED"),"minimizeComment","classifier"),(.moderate(subjectID:"C1",classifier:nil),"unminimizeComment","subjectId"),(.viewed(path:"new",viewed:true),"markFileAsViewed","path"),(.viewed(path:"new",viewed:false),"unmarkFileAsViewed","path")]
        for (intent,name,field) in graph { let result=try request(intent);let body=try XCTUnwrap(JSONSerialization.jsonObject(with:result.body) as? [String:Any]),input=try XCTUnwrap((body["variables"] as? [String:Any])?["input"] as? [String:Any]);XCTAssertTrue((body["query"] as? String)?.contains(name+"(input:$input)") == true);XCTAssertNotNil(input[field]);XCTAssertNotNil(input["clientMutationId"]) }
    }
    func testUnsafeHostAndRepositoryNeverProduceMutationRequest() throws {
        let revision=PRWriteRevision(head:"h",origin:"o",target:"t")
        for repo in ["o/../secret","o/r?token=secret","o/r/extra"] { XCTAssertThrowsError(try GitHubPRWriteAdapter.request(.init(command:.init(key:key,repository:repo,number:1,revision:revision,intent:.conversation("body"))))) }
        let other=ProviderKey(host:"enterprise.example",accountID:"42",repositoryID:"1",objectID:"PR1")
        XCTAssertThrowsError(try GitHubPRWriteAdapter.request(.init(command:.init(key:other,repository:"o/r",number:1,revision:revision,intent:.conversation("body")))))
    }
}
