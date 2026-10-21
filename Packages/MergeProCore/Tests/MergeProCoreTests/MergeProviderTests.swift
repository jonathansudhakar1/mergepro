import XCTest
@testable import MergeProCore

private actor MergeReaderTransport:GitHubTransport {
    struct Configuration:Sendable { var requiredChecks=false;var testMergeFailure=false;var optionalFailure=false;var rulesDenied=false;var unknownRule=false;var permission="WRITE";var reviewRequired=false;var changesDuringRead=false;var nativeMode:String?;var rebaseAllowed=true;var allowedMethods:[String]?=nil;var lowerAllowedMethods:[String]?=nil;var linear=false;var autoMerge=false;var chain:String?=nil }
    let config:Configuration
    var paths:[String]=[]
    var nodeIDs:[String]=[]
    static let head=String(repeating:"a",count:40),base=String(repeating:"b",count:40),test=String(repeating:"c",count:40)
    init(_ config:Configuration = .init()) { self.config=config }
    func send(_ request:URLRequest) async throws -> GitHubResponse {
        paths.append(request.url!.path)
        if request.httpMethod != "POST" {
            if request.url!.path.hasSuffix("rulesets") { return json(config.allowedMethods == nil && config.lowerAllowedMethods == nil ? "[]" : #"[{"id":7,"name":"Main protections","target":"branch","enforcement":"active"}]"#) }
            let lower = nodeIDs.last == "NODE2"
            if config.rulesDenied || (lower && config.nativeMode == "lower-rules-denied") { return json("{}",status:404) }
            var rules:[[String:Any]]=[]
            if config.unknownRule { rules.append(["type":"future_rule"]) }
            if let allowed = lower ? config.lowerAllowedMethods : config.allowedMethods { rules.append(["type":"pull_request","ruleset_id":7,"parameters":["dismiss_stale_reviews_on_push":false,"require_code_owner_review":false,"require_last_push_approval":false,"required_approving_review_count":0,"required_review_thread_resolution":false,"allowed_merge_methods":allowed]]) }
            if config.linear && !lower { rules.append(["type":"required_linear_history"]) }
            if config.requiredChecks || (lower && config.nativeMode == "lower-checks-unknown") { rules.append(["type":"required_status_checks","parameters":["required_status_checks":[["context":"CI","integration_id":41]],"strict_required_status_checks_policy":false]]) }
            return .init(status:200,data:try JSONSerialization.data(withJSONObject:rules))
        }
        let requestBody=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        let variables=requestBody["variables"] as! [String:Any]
        nodeIDs.append(variables["id"] as? String ?? "")
        if config.nativeMode == "lower-stack-incomplete",variables["id"] as? String == "NODE2",(requestBody["query"] as? String)?.contains("query StackPage") == true {
            throw GitHubFailure.invalidResponse
        }
        let empty:[String:Any]=["nodes":[],"pageInfo":["hasNextPage":false,"endCursor":NSNull()]]
        func commit(_ sha:String,_ state:String) -> [String:Any] {
            ["oid":sha,"statusCheckRollup":["contexts":["nodes":[["__typename":"CheckRun","name":config.optionalFailure ? "optional" : "CI","status":"COMPLETED","conclusion":state,"checkSuite":["app":["databaseId":41],"workflowRun":["event":"pull_request"]]]],"pageInfo":["hasNextPage":false]]]]
        }
        let protection:Any=config.reviewRequired ? ["requiresApprovingReviews":true,"requiredApprovingReviewCount":2,"requiresCodeOwnerReviews":true,"requiresStatusChecks":false,"restrictsPushes":false] : NSNull()
        let lower = variables["id"] as? String == "NODE2"
        var pr:[String:Any]=[
            "id":"NODE1","number":1,"title":"Provider parsed","url":"https://github.com/o/r/pull/1","state":"OPEN","isDraft":false,
            "headRefOid":config.changesDuringRead && nodeIDs.count>1 ? String(repeating:"d",count:40) : Self.head,"baseRefOid":Self.base,"baseRefName":"main","headRefName":"feature","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":NSNull(),
            "isMergeQueueEnabled":false,"isInMergeQueue":false,"viewerCanEnableAutoMerge":true,"viewerCanDisableAutoMerge":false,"viewerCanUpdateBranch":true,
            "autoMergeRequest":NSNull(),"potentialMergeCommit":config.testMergeFailure ? commit(Self.test,"FAILURE") : NSNull(),"headRef":["target":commit(Self.head,config.optionalFailure ? "FAILURE" : "NEUTRAL")],
            "repository":["id":"GRAPHQL_REPO_NODE","databaseId":1,"nameWithOwner":"o/r","viewerPermission":config.permission,"isPrivate":false,"mergeCommitAllowed":true,"squashMergeAllowed":true,"rebaseMergeAllowed":config.rebaseAllowed,"autoMergeAllowed":true],
            "baseRef":["branchProtectionRule":protection,"refUpdateRule":["viewerCanPush":false]],"commits":empty,"reviewThreads":empty,"stack":NSNull()
        ]
        if let chain=config.chain {
            func node(_ oid:String,_ parents:[String]) -> [String:Any] { ["commit":["oid":oid,"signature":NSNull(),"parents":["totalCount":parents.count,"nodes":parents.map { ["oid":$0] }]]] }
            let middle=String(repeating:"e",count:40),tip=chain == "stale-tip" ? String(repeating:"f",count:40) : Self.head
            pr["commits"]=["nodes":[node(middle,[Self.base]),node(tip,chain == "merge" ? [middle,Self.base] : [middle])],"pageInfo":["hasNextPage":chain == "incomplete","endCursor":"c"]]
        }
        if config.autoMerge { pr["autoMergeRequest"] = ["enabledAt":"2026-01-02T03:04:05Z","mergeMethod":"SQUASH","commitHeadline":"Ship it","commitBody":"Body"] }
        if let mode = config.nativeMode {
            let commits: [String:Any] = ["nodes":[["commit":["parents":["totalCount":1]]]], "pageInfo":["hasNextPage":false]]
            func layer(_ id:String,_ n:Int,_ state:String) -> [String:Any] {
                ["id":id,"number":n,"title":id,"state":state,"isDraft":false,"headRefOid":id == "NODE1" ? Self.head : String(repeating:"d",count:40),"baseRefOid":Self.base,"headRefName":id,"baseRefName":"main","commits":commits]
            }
            var bottom = layer("NODE2",2,mode == "closed" ? "CLOSED" : "OPEN")
            if lower && mode == "lower-linearity-incomplete" {
                bottom["commits"] = ["nodes":[["commit":["parents":["totalCount":1]]]],"pageInfo":["hasNextPage":true,"endCursor":"unread-commits"]]
            }
            let top = layer("NODE1",1,"OPEN")
            pr["stack"] = ["id":"STACK","number":7,"size":2,"entries":["nodes":[["position":1,"pullRequest":bottom],["position":2,"pullRequest":top]],"pageInfo":["hasNextPage":mode == "incomplete" || (lower && mode == "lower-stack-incomplete"),"endCursor":"cursor"]]]
            pr["commits"] = commits
            if lower {
                for (key,value) in bottom { pr[key] = value }
                var head = commit(String(repeating:"d",count:40),"NEUTRAL")
                if mode == "lower-checks-unknown" {
                    var rollup = head["statusCheckRollup"] as! [String:Any]
                    var contexts = rollup["contexts"] as! [String:Any]
                    contexts["pageInfo"] = ["hasNextPage":true,"endCursor":"unread-checks"]
                    rollup["contexts"] = contexts;head["statusCheckRollup"] = rollup
                }
                pr["headRef"] = ["target":head]
                if mode == "blocked" { pr["baseRef"] = ["branchProtectionRule":["requiresApprovingReviews":true,"requiredApprovingReviewCount":1,"restrictsPushes":false]] }
            }
        }
        return .init(status:200,data:try JSONSerialization.data(withJSONObject:["data":["viewer":["id":"U1","databaseId":1,"login":"viewer"],"node":pr]]))
    }
}
final class MergeProviderTests:XCTestCase {
    func testActualInventoryNormalizationThroughReaderAndMutationBoundary() async throws {
        let inventory=InventoryTransport(headRevision:MergeReaderTransport.head,baseRevision:MergeReaderTransport.base)
        let fetched=try await GitHubPRInventoryFetcher().fetch(PRInventoryTests().context(inventory))
        let pr=try XCTUnwrap(fetched.pullRequests.first { $0.metadata?.number == 1 })
        XCTAssertEqual(pr.key.objectID,"pull-request:NODE1");XCTAssertEqual(pr.key.repositoryID,"1")
        let transport=MergeReaderTransport(.init(optionalFailure:true))
        let value=try await GitHubMergeAdapter().inspect(MergeTarget(pr),client:.init(transport:transport),credential:.init(accessToken:"offline",scopes:["repo"]))
        XCTAssertTrue(MergePolicy.evaluate(value.evidence).eligible,"No required reviews, configured optional failing check, and viewerCanPush false do not invent blockers")
        let command=try MergeCommand(selected:value,affected:[value],method:.squash,action:.enableAutoMerge)
        let request=try GitHubMergeAdapter.request(.init(command:command.writeCommand))
        let body=try JSONSerialization.jsonObject(with:request.body) as! [String:Any]
        let input=(body["variables"] as! [String:Any])["input"] as! [String:Any]
        XCTAssertEqual(input["pullRequestId"] as? String,"NODE1");XCTAssertEqual(input["expectedHeadOid"] as? String,MergeReaderTransport.head)
        XCTAssertEqual(command.pr,pr.key)
        let ids=await transport.nodeIDs;XCTAssertEqual(ids,["NODE1","NODE1"])
    }
    func testRealNativeReaderFeedsIncompleteClosedAndBlockedLowerIntoSharedPolicy() async throws {
        let key=ProviderKey(host:"github.com",accountID:"1",repositoryID:"1",objectID:"pull-request:NODE1")
        let pr=PullRequest(key:key,headRevision:.init(MergeReaderTransport.head),title:"PR",state:.open,isDraft:false,metadata:PRMetadata(number:1,webURL:URL(string:"https://github.com/o/r/pull/1")!,repositoryName:"o/r"))
        var reads:[String:PullRequest]=[:]
        for mode in ["incomplete","closed","blocked","eligible"] {
            let result=try await GitHubMergeAdapter().inspect(MergeTarget(pr),client:.init(transport:MergeReaderTransport(.init(nativeMode:mode))),credential:.init(accessToken:"offline",scopes:["repo"]))
            reads[mode]=result.pr
            XCTAssertEqual(result.stack?.kind,.native)
            XCTAssertEqual(MergePolicy.evaluate(result.evidence).eligible,mode == "eligible",mode)
            XCTAssertEqual(MergePolicy.evaluate(pr:result.pr).eligible,mode == "eligible",mode)
            if mode != "eligible" { XCTAssertFalse(MergePolicy.evaluate(result.evidence).reasons.isEmpty) }
        }
        let ready=try XCTUnwrap(reads["eligible"])
        XCTAssertFalse(MergePolicy.becameReady(previous:reads["incomplete"],current:ready))
        XCTAssertFalse(MergePolicy.becameReady(previous:reads["closed"],current:ready))
        XCTAssertTrue(MergePolicy.becameReady(previous:reads["blocked"],current:ready))
        XCTAssertFalse(MergePolicy.becameReady(previous:nil,current:ready))
    }
    func testLowerOnlyUnknownProofCannotEnableMergeOrProduceReadyTransition() async throws {
        let key=ProviderKey(host:"github.com",accountID:"1",repositoryID:"1",objectID:"pull-request:NODE1")
        let pr=PullRequest(key:key,headRevision:.init(MergeReaderTransport.head),title:"Selected complete",state:.open,isDraft:false,metadata:PRMetadata(number:1,webURL:URL(string:"https://github.com/o/r/pull/1")!,repositoryName:"o/r"))
        func read(_ mode:String) async throws -> MergeInspection {
            try await GitHubMergeAdapter().inspect(MergeTarget(pr),client:.init(transport:MergeReaderTransport(.init(nativeMode:mode))),credential:.init(accessToken:"offline",scopes:["repo"]))
        }
        let ready=try await read("eligible")
        XCTAssertTrue(MergePolicy.evaluate(pr:ready.pr).eligible)
        for mode in ["lower-linearity-incomplete","lower-stack-incomplete","lower-rules-denied","lower-checks-unknown"] {
            let result=try await read(mode)
            XCTAssertTrue(result.stack?.warnings.isEmpty == true,"Selected topology remains complete: "+mode)
            XCTAssertTrue(result.evidence.rulesComplete,"Selected rules remain complete: "+mode)
            XCTAssertTrue(result.evidence.requirements.isEmpty,"Only the lower proof varies: "+mode)
            XCTAssertEqual(result.evidence.nativeAdmission?.state,.unknown,mode)
            XCTAssertFalse(MergePolicy.evaluate(pr:result.pr).eligible,mode)
            XCTAssertFalse(MergePolicy.becameReady(previous:result.pr,current:ready.pr),"Unknown lower proof is not an authoritative blocked→ready transition: "+mode)
        }
        let blocked=try await read("blocked")
        XCTAssertEqual(blocked.evidence.nativeAdmission?.state,.pending)
        XCTAssertFalse(MergePolicy.evaluate(pr:blocked.pr).eligible)
        XCTAssertTrue(MergePolicy.becameReady(previous:blocked.pr,current:ready.pr))

        // Cached pre-fix proof omitted lower unknownness. It remains decodable, but
        // cannot advertise eligibility or act as an authoritative readiness baseline.
        var oldPayload = try JSONSerialization.jsonObject(with:JSONEncoder.stable.encode(ready.evidence)) as! [String:Any]
        oldPayload.removeValue(forKey:"nativeAdmissionVersion")
        var legacy = try JSONDecoder().decode(MergeEvidence.self,from:JSONSerialization.data(withJSONObject:oldPayload))
        XCTAssertFalse(MergePolicy.evaluate(legacy).eligible)
        legacy.nativeAdmission = .init(name:"Prior flattened lower blocker",state:.pending)
        var metadata = ready.pr.metadata
        metadata?.mergeEvidence = legacy
        let legacyRow = PullRequest(key:ready.pr.key,headRevision:ready.pr.headRevision,title:ready.pr.title,state:ready.pr.state,isDraft:ready.pr.isDraft,metadata:metadata)
        XCTAssertFalse(MergePolicy.becameReady(previous:legacyRow,current:ready.pr))
    }
    func testRealReaderRejectsHeadChangeDuringRuleReads() async throws {
        let key=ProviderKey(host:"github.com",accountID:"1",repositoryID:"1",objectID:"pull-request:NODE1")
        let pr=PullRequest(key:key,headRevision:.init(MergeReaderTransport.head),title:"PR",state:.open,isDraft:false,metadata:PRMetadata(number:1,webURL:URL(string:"https://github.com/o/r/pull/1")!,repositoryName:"o/r"))
        do { _ = try await GitHubMergeAdapter().inspect(MergeTarget(pr),client:.init(transport:MergeReaderTransport(.init(changesDuringRead:true))),credential:.init(accessToken:"offline",scopes:["repo"]));XCTFail("Mixed revisions cannot establish admission") }
        catch { XCTAssertEqual(error as? PRWriteFailure,.revisionChanged) }
    }
    func testRealParsedRequirementsUnknownsAndTestMergePrecedence() async throws {
        let key=ProviderKey(host:"github.com",accountID:"1",repositoryID:"1",objectID:"pull-request:NODE1")
        let m=PRMetadata(number:1,webURL:URL(string:"https://github.com/o/r/pull/1")!,repositoryName:"o/r")
        let pr=PullRequest(key:key,headRevision:.init(MergeReaderTransport.head),title:"PR",state:.open,isDraft:false,metadata:m)
        let cases:[(MergeReaderTransport.Configuration,Bool)]=[(.init(requiredChecks:true),true),(.init(requiredChecks:true,testMergeFailure:true),false),(.init(rulesDenied:true),false),(.init(unknownRule:true),false),(.init(permission:"READ"),false),(.init(reviewRequired:true),false)]
        for (config,expected) in cases {
            let value=try await GitHubMergeAdapter().inspect(MergeTarget(pr),client:.init(transport:MergeReaderTransport(config)),credential:.init(accessToken:"offline",scopes:["repo"]))
            XCTAssertEqual(MergePolicy.evaluate(value.evidence).eligible,expected)
        }
    }
}

extension MergeProviderTests {
    private var selectedPR:PullRequest {
        .init(key:.init(host:"github.com",accountID:"1",repositoryID:"1",objectID:"pull-request:NODE1"),headRevision:.init(MergeReaderTransport.head),title:"PR",state:.open,isDraft:false,metadata:PRMetadata(number:1,webURL:URL(string:"https://github.com/o/r/pull/1")!,repositoryName:"o/r"))
    }
    private func read(_ config:MergeReaderTransport.Configuration) async throws -> MergeInspection {
        try await GitHubMergeAdapter().inspect(MergeTarget(selectedPR),client:.init(transport:MergeReaderTransport(config)),credential:.init(accessToken:"offline",scopes:["repo"]))
    }
    func testRealReaderRecordsWhyEachMethodWasTrimmed() async throws {
        let all=try await read(.init())
        XCTAssertEqual(all.evidence.methods,[.merge,.squash,.rebase]);XCTAssertEqual(all.evidence.methodReasons,[:])
        let value=try await read(.init(rebaseAllowed:false,allowedMethods:["squash","rebase"],linear:true))
        XCTAssertEqual(value.evidence.methods,[.squash])
        XCTAssertEqual(value.evidence.methodReasons,["rebase":"Disabled in repository settings","merge":"Not allowed by ruleset 'Main protections'"],"The first trimming site explains each method")
        XCTAssertTrue(MergePolicy.evaluate(value.evidence).eligible)
        let options=MergePolicy.methodOptions(value.evidence,action:.direct)
        XCTAssertEqual(options.map(\.method),[.merge,.squash,.rebase]);XCTAssertEqual(options.map(\.enabled),[false,true,false])
        XCTAssertEqual(options.map(\.reason),["Not allowed by ruleset 'Main protections'",nil,"Disabled in repository settings"])
        let linear=try await read(.init(linear:true))
        XCTAssertEqual(linear.evidence.methods,[.squash,.rebase]);XCTAssertEqual(linear.evidence.methodReasons?["merge"],"Linear history required")
        let native=try await read(.init(nativeMode:"eligible",lowerAllowedMethods:["squash"]))
        XCTAssertEqual(native.evidence.methods,[.squash]);XCTAssertTrue(MergePolicy.evaluate(pr:native.pr).eligible)
        XCTAssertEqual(native.evidence.methodReasons?["merge"],"Not allowed by stack layer #2 (Not allowed by ruleset 'Main protections')")
        XCTAssertEqual(native.evidence.methodReasons?["rebase"],"Not allowed by stack layer #2 (Not allowed by ruleset 'Main protections')")
    }
    func testAdmissionReadExposesAutoMergeOptionsWithoutChangingEvidence() async throws {
        let plain=try await read(.init()),enabled=try await read(.init(autoMerge:true))
        XCTAssertNil(plain.autoMergeRequest)
        XCTAssertEqual(enabled.autoMergeRequest,.init(method:.squash,commitHeadline:"Ship it",commitBody:"Body",enabledAt:ISO8601DateFormatter().date(from:"2026-01-02T03:04:05Z")))
        XCTAssertTrue(enabled.evidence.autoMergeEnabled)
        XCTAssertTrue(GitHubMergeReader.admissionQuery.contains("autoMergeRequest { enabledAt mergeMethod commitHeadline commitBody }"))
    }
    func testRebaseAndQueueRequestsOmitCommitTextWhileAutoMergeCarriesIt() async throws {
        let value=try await read(.init())
        func body(_ method:MergeMethod,_ action:MergeAction,_ title:String?,_ message:String?) throws -> [String:Any] {
            let command=try MergeCommand(selected:value,affected:[value],method:method,action:action,title:title,message:message)
            return try JSONSerialization.jsonObject(with:GitHubMergeAdapter.request(.init(command:command.writeCommand)).body) as! [String:Any]
        }
        let rebase=try body(.rebase,.direct,"Typed title","Typed message")
        XCTAssertEqual(rebase["merge_method"] as? String,"rebase");XCTAssertNil(rebase["commit_title"]);XCTAssertNil(rebase["commit_message"])
        let squash=try body(.squash,.direct,"Edited",nil)
        XCTAssertEqual(squash["commit_title"] as? String,"Edited");XCTAssertNil(squash["commit_message"],"Unedited body follows GitHub's default")
        XCTAssertNil(try body(.squash,.queue,"T","M")["commit_title"])
        // A decoded legacy rebase command that still carries text is not sent either.
        var legacy=try JSONSerialization.jsonObject(with:JSONEncoder.stable.encode(MergeCommand(selected:value,affected:[value],method:.squash,action:.direct,title:"Old",message:"Old"))) as! [String:Any]
        legacy["method"]="rebase"
        let decoded=try JSONDecoder().decode(MergeCommand.self,from:JSONSerialization.data(withJSONObject:legacy))
        let legacyBody=try JSONSerialization.jsonObject(with:GitHubMergeAdapter.request(.init(command:decoded.writeCommand)).body) as! [String:Any]
        XCTAssertNil(legacyBody["commit_title"]);XCTAssertNil(legacyBody["commit_message"])
        func input(_ method:MergeMethod,_ title:String?,_ message:String?) throws -> [String:Any] { (try body(method,.enableAutoMerge,title,message)["variables"] as! [String:Any])["input"] as! [String:Any] }
        let auto=try input(.squash,"Ship it","Body")
        XCTAssertEqual(auto["commitHeadline"] as? String,"Ship it");XCTAssertEqual(auto["commitBody"] as? String,"Body");XCTAssertEqual(auto["mergeMethod"] as? String,"SQUASH")
        let plain=try input(.squash,nil,nil);XCTAssertNil(plain["commitHeadline"]);XCTAssertNil(plain["commitBody"])
        let rebaseAuto=try input(.rebase,"T","M");XCTAssertNil(rebaseAuto["commitHeadline"]);XCTAssertNil(rebaseAuto["commitBody"])
    }
    func testRealReaderProvesALinearChainOnlyFromACompleteCommitPage() async throws {
        XCTAssertTrue(GitHubMergeReader.admissionQuery.contains("parents(first:2) { totalCount nodes { oid } }"))
        let linear=try await read(.init(chain:"linear"))
        XCTAssertEqual(linear.linearBase,MergeReaderTransport.base)
        for mode in ["incomplete","merge","stale-tip"] { let value=try await read(.init(chain:mode));XCTAssertNil(value.linearBase,mode) }
        let none=try await read(.init());XCTAssertNil(none.linearBase,"No commits proves nothing")
        let merged=try await read(.init(chain:"merge"))
        XCTAssertTrue(linear.evidence.sameAdmission(as:merged.evidence),"Chain proof is reconciliation data, not admission evidence")
    }
    func testRebaseUpdateUsesGraphQLWithExpectedHeadWhileMergeUpdateStaysREST() async throws {
        let value=try await read(.init())
        func request(_ action:MergeAction,_ update:MergeUpdateMethod?) throws -> GitHubPRWriteAdapter.Request {
            try GitHubMergeAdapter.request(.init(command:MergeCommand(selected:value,affected:[value],method:.squash,action:action,updateMethod:update).writeCommand))
        }
        let rebase=try request(.updateBranch,.rebase)
        XCTAssertEqual(rebase.path,"graphql");XCTAssertEqual(rebase.method,"POST")
        let root=try XCTUnwrap(JSONSerialization.jsonObject(with:rebase.body) as? [String:Any]),input=try XCTUnwrap((root["variables"] as? [String:Any])?["input"] as? [String:Any])
        XCTAssertTrue((root["query"] as? String)?.contains("updatePullRequestBranch(input:$input)") == true)
        XCTAssertEqual(input["pullRequestId"] as? String,"NODE1");XCTAssertEqual(input["expectedHeadOid"] as? String,MergeReaderTransport.head);XCTAssertEqual(input["updateMethod"] as? String,"REBASE")
        for update in [MergeUpdateMethod?.none,.merge] {
            let merge=try request(.updateBranch,update)
            XCTAssertEqual(merge.path,"repos/o/r/pulls/1/update-branch");XCTAssertEqual(try JSONSerialization.jsonObject(with:merge.body) as? [String:String],["expected_head_sha":MergeReaderTransport.head])
        }
        XCTAssertEqual(try MergeCommand(selected:value,affected:[value],method:.squash,action:.updateBranch,updateMethod:.rebase).updateMethod,"rebase")
        XCTAssertNil(try MergeCommand(selected:value,affected:[value],method:.squash,action:.updateBranch,updateMethod:.merge).updateMethod,"Merge update keeps the legacy encoding")
        XCTAssertNil(try MergeCommand(selected:value,affected:[value],method:.squash,action:.direct,updateMethod:.rebase).updateMethod,"Only update-branch carries an update method")
        var payload=try JSONSerialization.jsonObject(with:JSONEncoder.stable.encode(MergeCommand(selected:value,affected:[value],method:.squash,action:.updateBranch))) as! [String:Any]
        XCTAssertNil(payload["updateMethod"]);XCTAssertNil(try JSONDecoder().decode(MergeCommand.self,from:JSONSerialization.data(withJSONObject:payload)).updateMethod,"Legacy commands decode")
        payload["updateMethod"]="squash"
        let unknown=try JSONDecoder().decode(MergeCommand.self,from:JSONSerialization.data(withJSONObject:payload))
        XCTAssertThrowsError(try GitHubMergeAdapter.request(.init(command:unknown.writeCommand)),"An unknown update method is never guessed")
    }
}
