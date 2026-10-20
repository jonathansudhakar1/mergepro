import XCTest
@testable import MergeProCore

private let messageHead=String(repeating:"a",count:40)
/// The merge message-defaults read for PR #1 as `viewer`, with or without GitHub's prefilled messages.
private func messageDefaultsTransport(prefill:Bool,viewer:Int=1) throws -> ScriptedTransport {
    let authors:[[String:Any]]=[["name":"Octo","email":"octo@example.com","user":["login":"octo"]],["name":"Sam","email":"sam@example.com","user":["login":"sam"]]]
    let node:[String:Any]=[
        "id":"NODE1","number":1,"title":"Add feature","body":"PR body","headRefOid":messageHead,"headRefName":"feature",
        "headRepositoryOwner":["login":"octo"],"author":["login":"octo"],
        "mergeHeadline":prefill ? "Merge pull request #1 from octo/feature" : NSNull(),"mergeBody":prefill ? "Add feature" : NSNull(),
        "squashHeadline":prefill ? "Provider squash (#1)" : NSNull(),"squashBody":prefill ? "Provider body\n\nCo-authored-by: Lee <lee@example.com>" : NSNull(),
        "repository":["databaseId":1,"nameWithOwner":"o/r","squashMergeCommitTitle":"PR_TITLE","squashMergeCommitMessage":"PR_BODY","mergeCommitTitle":"PR_TITLE","mergeCommitMessage":"BLANK"],
        "commits":["nodes":[["commit":["messageHeadline":"Only","messageBody":"","authors":["nodes":authors]]]],"pageInfo":["hasNextPage":true,"endCursor":"c"]]
    ]
    return ScriptedTransport(fallback:try json(object:["data":["viewer":["databaseId":viewer],"node":node]]))
}
private struct NoDefaultsAdapter:MergeAdapter {
    func inspect(_ target:MergeTarget,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> MergeInspection { throw PRWriteFailure.unavailable }
    func send(_ operation:PRWriteOperation,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> GitHubResponse { throw PRWriteFailure.unavailable }
    func status(_ id:UUID,target:MergeTarget,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> GitHubResponse { throw PRWriteFailure.unavailable }
}

final class MergeMessageComposerTests:XCTestCase {
    private let sam="Co-authored-by: Sam <sam@example.com>",pat="Co-authored-by: Pat <pat@example.com>"
    private var defaults:MergeMessageDefaults {
        .init(head:"h",titles:[.squash:"Squash T (#1)",.merge:"Merge pull request #1 from o/f"],bodies:[.squash:"* a\n\n"+sam,.merge:"PR"],coAuthorTrailers:[sam])
    }
    private var pr:PullRequest {
        .init(key:.init(host:"github.com",accountID:"1",repositoryID:"1",objectID:"pull-request:NODE1"),headRevision:.init(messageHead),title:"Add feature",state:.open,isDraft:false,metadata:PRMetadata(number:1,webURL:URL(string:"https://github.com/o/r/pull/1")!,repositoryName:"o/r"))
    }

    func testFallbackEncodesEverySettingsCombination() {
        let one=[MergeMessageCommit(headline:"Only commit",body:"detail")],many=[MergeMessageCommit(headline:"First"),.init(headline:"Second")]
        for st in MergeMessageSettings.SquashTitle.allCases { for sb in MergeMessageSettings.SquashBody.allCases {
            for mt in MergeMessageSettings.MergeTitle.allCases { for mb in MergeMessageSettings.MergeBody.allCases {
                for commits in [one,many] {
                    let settings=MergeMessageSettings(squashTitle:st,squashBody:sb,mergeTitle:mt,mergeBody:mb),name="\(settings) \(commits.count)"
                    let v=MergeMessageComposer.fallback(settings:settings,prTitle:"Add feature",prBody:"PR body",number:42,headLabel:"octo/feature",commits:commits,prAuthor:"octo")
                    XCTAssertEqual(v.titles[.squash],st == .commitOrPRTitle && commits.count == 1 ? "Only commit (#42)" : "Add feature (#42)",name)
                    XCTAssertEqual(v.bodies[.squash],sb == .prBody ? "PR body" : sb == .blank ? "" : commits.map { "* "+$0.headline }.joined(separator:"\n\n"),name)
                    XCTAssertEqual(v.titles[.merge],mt == .mergeMessage ? "Merge pull request #42 from octo/feature" : "Add feature (#42)",name)
                    XCTAssertEqual(v.bodies[.merge],mb == .prTitle ? "Add feature" : mb == .prBody ? "PR body" : "",name)
                    XCTAssertNil(v.titles[.rebase]);XCTAssertNil(v.bodies[.rebase])
                }
            } }
        } }
        XCTAssertEqual(MergeMessageSettings(),.init(squashTitle:.commitOrPRTitle,squashBody:.commitMessages,mergeTitle:.mergeMessage,mergeBody:.prTitle),"GitHub's repository defaults")
    }
    func testFallbackSquashBodyKeepsCoAuthorsExceptPRAuthor() {
        let commits=[MergeMessageCommit(headline:"A",authors:[.init(name:"Octo",email:"octo@example.com",login:"octo")]),
                     .init(headline:"B",body:"Explain\n\n"+pat,authors:[.init(name:"Sam",email:"sam@example.com",login:"sam")])]
        let v=MergeMessageComposer.fallback(settings:.init(),prTitle:"T",prBody:"",number:1,headLabel:"octo/f",commits:commits,prAuthor:"octo")
        XCTAssertEqual(v.bodies[.squash],"* A\n\n* B\n\n"+sam+"\n"+pat)
        let blank=MergeMessageComposer.fallback(settings:.init(squashBody:.blank),prTitle:"T",prBody:"",number:1,headLabel:"octo/f",commits:commits,prAuthor:"octo")
        XCTAssertEqual(blank.bodies[.squash],"","BLANK stays blank; edited text can opt into trailers")
        XCTAssertEqual(v.bodies[.merge],"T","Merge commits preserve authorship through parents, without trailers")
    }
    func testCoAuthorTrailersAreDedupedAndExcludePRAuthor() {
        let commits=[
            MergeMessageCommit(headline:"1",body:"Fix\n\nCo-authored-by: Pat <PAT@example.com>\nco-authored-by:  Octo Alt <12345+octo@users.noreply.github.com>",authors:[.init(name:"Octo",email:"octo@example.com",login:"octo"),.init(name:"Sam",email:"sam@example.com",login:"sam")]),
            .init(headline:"2",body:"Co-authored-by: Octo <octo@example.com>\n"+pat,authors:[.init(name:"Sam S",email:"sam@other.example",login:"sam"),.init(name:"Pat",email:"pat@example.com",login:nil)])]
        XCTAssertEqual(MergeMessageComposer.coAuthors(commits:commits,prAuthor:"Octo"),[sam,"Co-authored-by: Pat <PAT@example.com>"])
        XCTAssertEqual(MergeMessageComposer.coAuthors(commits:commits,prAuthor:nil).count,4,"Without an author login only exact duplicates collapse")
        XCTAssertEqual(MergeMessageComposer.trailers(in:"Body\nco-authored-by:  Octo Alt <x@example.com>  \nSigned-off-by: A <a@example.com>"),["Co-authored-by: Octo Alt <x@example.com>"])
    }
    func testEnsuringTrailersIsIdempotentAndAppendsOnlyMissing() {
        let trailers=[sam,pat]
        let once=MergeMessageComposer.ensuring(trailers:trailers,in:"Body\n\nCo-authored-by: pat <PAT@example.com>\n")
        XCTAssertEqual(once,"Body\n\nCo-authored-by: pat <PAT@example.com>\n"+sam)
        XCTAssertEqual(MergeMessageComposer.ensuring(trailers:trailers,in:once),once)
        XCTAssertEqual(MergeMessageComposer.ensuring(trailers:trailers,in:""),sam+"\n"+pat)
        XCTAssertEqual(MergeMessageComposer.ensuring(trailers:trailers+trailers,in:"Edited"),"Edited\n\n"+sam+"\n"+pat)
        XCTAssertEqual(MergeMessageComposer.ensuring(trailers:[],in:"Edited  \n"),"Edited  \n","Nothing missing leaves the text byte-identical")
    }
    func testSwitchingMethodsAndRefreshingDefaultsNeverOverwriteEdits() {
        var text=MergeCommitText(method:.squash)
        XCTAssertEqual(text.title,"");XCTAssertFalse(text.titleEdited)
        text.applyDefaults(defaults,method:.squash)
        XCTAssertEqual(text.title,"Squash T (#1)");XCTAssertEqual(text.message,"* a\n\n"+sam)
        text.title="Squash T (#1)";XCTAssertFalse(text.titleEdited,"Typing the default is not an edit")
        text.message="Custom body";XCTAssertTrue(text.messageEdited)
        text.applyDefaults(defaults,method:.merge)
        XCTAssertEqual(text.method,.merge);XCTAssertEqual(text.title,"Merge pull request #1 from o/f");XCTAssertEqual(text.message,"Custom body")
        text.applyDefaults(defaults,method:.rebase);text.applyDefaults(defaults,method:.squash)
        XCTAssertEqual(text.message,"Custom body")
        var refreshed=defaults;refreshed.titles[.squash]="Renamed (#1)";refreshed.bodies[.squash]="Custom body"
        text.applyDefaults(refreshed,method:.squash)
        XCTAssertEqual(text.title,"Renamed (#1)");XCTAssertTrue(text.messageEdited,"Edits are sticky even when a refreshed default equals them");XCTAssertEqual(text.message,"Custom body")
        text.message="Again";text.title="Mine";text.resetToDefault()
        XCTAssertEqual(text.title,"Renamed (#1)");XCTAssertEqual(text.message,"Custom body");XCTAssertFalse(text.titleEdited||text.messageEdited)
        var early=MergeCommitText();early.title="Typed before defaults";early.applyDefaults(defaults,method:.squash)
        XCTAssertEqual(early.title,"Typed before defaults");XCTAssertTrue(early.titleEdited)
    }
    /// A deliberate blank squash body survives a detour through a method whose default is also blank.
    func testEditEqualToATemporaryDefaultSurvivesMethodSwitches() {
        var text=MergeCommitText(method:.squash,defaults:defaults)
        text.message="";XCTAssertTrue(text.messageEdited)
        text.applyDefaults(defaults,method:.rebase);XCTAssertTrue(text.messageEdited)
        text.applyDefaults(defaults,method:.squash)
        XCTAssertEqual(text.message,"","The GitHub body must not reappear");XCTAssertEqual(text.overrides(keepTrailers:false).message,"")
        var merge=MergeCommitText(method:.merge,defaults:defaults);merge.title="Squash T (#1)"
        merge.applyDefaults(defaults,method:.squash);XCTAssertTrue(merge.titleEdited,"An edit equal to another method's default stays an edit")
        merge.applyDefaults(defaults,method:.merge);XCTAssertEqual(merge.title,"Squash T (#1)")
        merge.title=merge.defaultTitle;XCTAssertFalse(merge.titleEdited,"Typing the current default clears the edit")
        merge.message="Body";merge.resetToDefault();XCTAssertFalse(merge.messageEdited)
    }
    /// Missing prefill (head moved, read failed) leaves unedited fields blank; the presentation must
    /// say GitHub applies its own default rather than imply an empty commit message.
    func testUneditedFieldsWithoutPrefillReportProviderDefault() {
        var text=MergeCommitText(method:.squash)
        XCTAssertTrue(text.titleUsesProviderDefault);XCTAssertTrue(text.messageUsesProviderDefault)
        XCTAssertNil(text.overrides().title);XCTAssertNil(text.overrides().message)
        text.message="Mine";XCTAssertFalse(text.messageUsesProviderDefault);XCTAssertTrue(text.titleUsesProviderDefault)
        text.title="   ";XCTAssertTrue(text.titleUsesProviderDefault,"A blank headline is not sent")
        text.applyDefaults(defaults,method:.squash)
        XCTAssertTrue(text.titleUsesProviderDefault,"Still a blank, unsent headline");XCTAssertFalse(text.messageUsesProviderDefault)
        text.resetToDefault();XCTAssertFalse(text.titleUsesProviderDefault,"The shown prefill is the default");XCTAssertFalse(text.messageUsesProviderDefault)
        text.applyDefaults(nil,method:.squash);XCTAssertTrue(text.titleUsesProviderDefault);XCTAssertTrue(text.messageUsesProviderDefault)
        text.applyDefaults(nil,method:.rebase);XCTAssertFalse(text.titleUsesProviderDefault,"Rebase has no commit text");XCTAssertFalse(text.messageUsesProviderDefault)
        var presentation=MergeOptionsPresentationState();XCTAssertTrue(presentation.titleUsesProviderDefault);presentation.message="x";XCTAssertFalse(presentation.messageUsesProviderDefault)
    }
    func testOverridesAreNilUnlessEditedForDirectOrAutoMergeNonRebase() {
        var text=MergeCommitText(method:.squash,defaults:defaults)
        XCTAssertNil(text.overrides().title);XCTAssertNil(text.overrides().message)
        text.title="Edited title"
        XCTAssertEqual(text.overrides().title,"Edited title");XCTAssertNil(text.overrides().message)
        text.message="Edited body"
        XCTAssertEqual(text.overrides(keepTrailers:true).message,"Edited body\n\n"+sam)
        XCTAssertEqual(text.overrides(keepTrailers:false).message,"Edited body")
        XCTAssertEqual(text.overrides(action:.enableAutoMerge).title,"Edited title")
        for action in [MergeAction.queue,.disableAutoMerge,.removeQueue,.updateBranch] {
            XCTAssertNil(text.overrides(action:action).title);XCTAssertNil(text.overrides(action:action).message)
        }
        text.applyDefaults(defaults,method:.merge)
        XCTAssertEqual(text.overrides().message,"Edited body","Trailers are a squash concern")
        text.applyDefaults(defaults,method:.rebase)
        XCTAssertNil(text.overrides().title);XCTAssertNil(text.overrides().message)
        text.applyDefaults(defaults,method:.squash);text.title="   "
        XCTAssertNil(text.overrides().title,"A blank headline cannot override GitHub's default")
        text.message=""
        XCTAssertEqual(text.overrides(keepTrailers:false).message,"","Deliberately blanking the body is an override")
    }
    func testCommandKeepsTextOnlyForDirectAndAutoMergeNonRebase() throws {
        let key=ProviderKey(host:"github.com",accountID:"1",repositoryID:"1",objectID:"pull-request:NODE1")
        var e=MergeEvidence(key:key,head:"h",base:"b",branch:"main",fetchedAt:Date());e.methods=[.merge,.squash,.rebase]
        let value=MergeInspection(pr:.init(key:key,headRevision:.init("h"),title:"T",state:.open,isDraft:false,metadata:PRMetadata(number:1,webURL:URL(string:"https://github.com/o/r/pull/1")!,repositoryName:"o/r")),evidence:e)
        for method in MergeMethod.allCases {
            for action in [MergeAction.direct,.queue,.enableAutoMerge,.disableAutoMerge,.removeQueue,.updateBranch] {
                let command=try MergeCommand(selected:value,affected:[value],method:method,action:action,title:"T",message:"M")
                let kept=method != .rebase && [.direct,.enableAutoMerge].contains(action)
                XCTAssertEqual(command.title,kept ? "T" : nil,"\(method) \(action)");XCTAssertEqual(command.message,kept ? "M" : nil,"\(method) \(action)")
            }
        }
        XCTAssertNil(try MergeCommand(selected:value,affected:[value],method:.squash,action:.direct,title:"  ").title)
    }
    func testReaderParsesProviderPrefillSettingsAndBoundedCommits() async throws {
        let transport=try messageDefaultsTransport(prefill:true)
        let read=try await GitHubMergeAdapter().messageDefaults(MergeTarget(pr),client:.init(transport:transport),credential:.init(accessToken:"offline",scopes:["repo"]))
        let value=try XCTUnwrap(read)
        XCTAssertEqual(value.head,messageHead);XCTAssertTrue(value.providerPrefill);XCTAssertFalse(value.commitsComplete)
        XCTAssertEqual(value.settings,.init(squashTitle:.prTitle,squashBody:.prBody,mergeTitle:.prTitle,mergeBody:.blank))
        XCTAssertEqual(value.titles[.squash],"Provider squash (#1)");XCTAssertEqual(value.bodies[.squash],"Provider body\n\nCo-authored-by: Lee <lee@example.com>")
        XCTAssertEqual(value.titles[.merge],"Merge pull request #1 from octo/feature");XCTAssertEqual(value.bodies[.merge],"Add feature")
        XCTAssertEqual(value.coAuthorTrailers,[sam,"Co-authored-by: Lee <lee@example.com>"])
        let queries=await transport.requests.map { request in ((try? JSONSerialization.jsonObject(with:request.httpBody ?? Data())) as? [String:Any])?["query"] as? String ?? "" }
        let query=try XCTUnwrap(queries.first)
        for field in ["viewerMergeHeadlineText(mergeType:MERGE)","viewerMergeHeadlineText(mergeType:SQUASH)","viewerMergeBodyText(mergeType:SQUASH)","squashMergeCommitTitle","mergeCommitMessage","authors(first:5)","author { login }"] { XCTAssertTrue(query.contains(field),field) }
        XCTAssertFalse(query.contains("branchProtectionRule"),"Separate from the admission evidence query")
        XCTAssertEqual(queries.count,1)
    }
    func testReaderFallsBackWhenPrefillIsNullAndRejectsAnotherViewer() async throws {
        let read=try await GitHubMergeAdapter().messageDefaults(MergeTarget(pr),client:.init(transport:try messageDefaultsTransport(prefill:false)),credential:.init(accessToken:"offline",scopes:["repo"]))
        let value=try XCTUnwrap(read)
        XCTAssertFalse(value.providerPrefill)
        XCTAssertEqual(value.titles[.squash],"Add feature (#1)");XCTAssertEqual(value.bodies[.squash],"PR body\n\n"+sam)
        XCTAssertEqual(value.titles[.merge],"Add feature (#1)");XCTAssertEqual(value.bodies[.merge],"")
        XCTAssertEqual(value.coAuthorTrailers,[sam])
        do { _ = try await GitHubMergeAdapter().messageDefaults(MergeTarget(pr),client:.init(transport:try messageDefaultsTransport(prefill:true,viewer:2)),credential:.init(accessToken:"offline",scopes:["repo"]));XCTFail("Another account's read cannot supply prefill") }
        catch { XCTAssertEqual(error as? PRWriteFailure,.unavailable) }
        let none=try await NoDefaultsAdapter().messageDefaults(MergeTarget(pr),client:.init(transport:try messageDefaultsTransport(prefill:true)),credential:.init(accessToken:"offline",scopes:["repo"]))
        XCTAssertNil(none,"Protocol default keeps existing adapters (fixtures) compiling with no prefill")
    }
}
