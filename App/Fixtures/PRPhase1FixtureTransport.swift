import Foundation
import MergeProCore

/// Finite provider-shaped offline data. Never initializes AppKit or reaches URLSession.
enum PRPhase1Fixtures {
    static var enabled:Bool { ProcessInfo.processInfo.environment["MERGEPRO_PHASE1_FIXTURES"] == "1" && ProcessInfo.processInfo.environment["MERGEPRO_UI_TEST_NAMESPACE"].flatMap(UUID.init(uuidString:)) != nil }
    static let inboxBaselineCycle=UUID(uuidString:"99999999-9999-9999-9999-999999999999")!
    static let accounts=[AccountScope(host:"github.com",accountID:"41"),AccountScope(host:"github.com",accountID:"42")]
    static let origin=String(repeating:"b",count:40),target=String(repeating:"c",count:40),later=String(repeating:"d",count:40),mergedCommit=String(repeating:"e",count:40)
    static func head(_ n:Int) -> String { String(format:"%040x",256+n) }
    static func base(_ n:Int) -> String { n == 10 ? head(9) : target }
    static func token(_ account:AccountScope) -> String { "offline-phase1-"+account.accountID }
    static func source(_ n:Int=1) -> String { (1...500).map { "let value\($0) = \($0) // 🐈 fixture" }.joined(separator:"\n")+"\n" }
    static func seedAccounts(_ database:DatabaseStore) throws {
        guard enabled,try database.applicationSetting(.phase1Seeded) == nil else { return }
        for account in accounts {
            let repo=RepositoryKey(account:account,repositoryID:"1")
            try database.saveAccount(.init(scope:account,login:"Fixture "+account.accountID,tokenReference:nil))
            try database.saveRepository(.init(key:repo,name:"o/r",isPrivate:true,capabilities:[]))
            try database.setTracked(repo,tracked:true)
        }
        try database.setApplicationSetting(AccountSessionStore.tokenReference(for:accounts[1]),for:.activeActionAccount)
        try database.setApplicationSetting("true",for:.phase1Seeded)
    }
    static func prepare(_ database:DatabaseStore,session:GitHubAccountSession,budget:RateBudget) async throws {
        let inbox=PollCycleStore(database:database)
        try inbox.begin(inboxBaselineCycle,at:Date(),baseline:true)
        for account in accounts {
            let ticket=try await session.authenticatedOperation(for:account,clientID:"fixture")
            let repo=RepositoryKey(account:account,repositoryID:"1")
            let context=PollFetchContext(cycleID:UUID(),account:account,repositories:[repo],featureID:"github-pr-inventory",cachedPullRequests:[],cachedSnapshots:[],repositoryMetadata:[repo:.init(key:repo,name:"o/r",isPrivate:true,capabilities:[])],deadline:.now.advanced(by:.seconds(180)),operation:ticket,client:await session.featureClient(account:account,budget:budget),budget:budget,baselinedRepositories:[],suppressNotifications:true,cachedResponses:[:])
            let result=try await GitHubPRInventoryFetcher().fetch(context)
            guard result.pullRequests.count == 10 else { throw GitHubFailure.invalidResponse }
            guard try await session.withCurrentOperation(ticket,body:{ db in try db.savePullRequests(result.pullRequests) }) else { throw GitHubFailure.invalidAuthentication }
            let feedContext=PollFetchContext(cycleID:inboxBaselineCycle,account:account,repositories:[repo],featureID:"github-notification-signals",cachedPullRequests:[],cachedSnapshots:[],repositoryMetadata:context.repositoryMetadata,deadline:context.deadline,operation:ticket,client:context.client,budget:budget,baselinedRepositories:[],suppressNotifications:true,cachedResponses:[:])
            let feed=try await GitHubNotificationFeedFetcher().fetch(feedContext)
            guard feed.events.count == 1,try await session.withCurrentOperation(ticket,body:{ _ in try inbox.apply(feed,context:feedContext,deadline:feedContext.deadline,requireTracked:true) }) else { throw GitHubFailure.invalidResponse }
            let service=PRDetailService(session:session,budget:budget,clientID:"fixture")
            guard let pr=result.pullRequests.first(where:{ $0.metadata?.number == 1 }) else { throw GitHubFailure.invalidResponse }
            _ = try await service.detail(pr)
            _ = try await service.blob(pr,path:"sample.swift",sha:origin)
            _ = try await service.blob(pr,path:"sample.swift",sha:head(1))
            if account == accounts[1] {
                let coordinator=MergeCoordinator(session:session,budget:budget,database:database,clientID:"fixture",activeAccount:{ account })
                for number in [2,6,7,9,10] {
                    guard let row=result.pullRequests.first(where:{ $0.metadata?.number == number }) else { throw GitHubFailure.invalidResponse }
                    _ = try await coordinator.inspect(row)
                }
            }
        }
        let summary=try inbox.close(inboxBaselineCycle,at:Date(),policy:.init(enabled:false),suppress:true)
        guard summary.eventKeys.isEmpty,try inbox.attemptState(inboxBaselineCycle) == nil else { throw GitHubFailure.invalidResponse }
    }
}
actor PRPhase1FixtureTransport:GitHubTransport {
    private(set) var reads=0,mutations=0
    private var reviews:[String:[[String:Any]]]=[:],threads:[String:[[String:Any]]]=[:],comments:[String:[[String:Any]]]=[:]
    private var viewed:Set<String>=[],merged:Set<Int>=[],statusReads=0
    private var loseConversation=true,moveRevision=false,denyB=false,holdRefresh=false
    private var unreadThreads=Set(PRPhase1Fixtures.accounts.map(\.accountID))
    private var mergeReady=false,mergeStarted=false,mergeMethod="squash"
    private var refreshGates:[CheckedContinuation<Void,Never>]=[]
    private let asyncID=UUID(uuidString:"22222222-2222-2222-2222-222222222222")!
    func holdFreshDetail() { holdRefresh=true }
    func releaseRefresh() { holdRefresh=false;let gates=refreshGates;refreshGates=[];gates.forEach { $0.resume() } }
    func confirmMerge() { mergeReady=true }
    func moveHeadOnIdentity() { moveRevision=true }
    func denyAccountB() { denyB=true }
    private func page(_ nodes:[[String:Any]]) -> [String:Any] { ["nodes":nodes,"pageInfo":["hasNextPage":false,"hasPreviousPage":false,"endCursor":NSNull()]] }
    private func viewer(_ account:Int) -> [String:Any] { ["id":"U\(account)","databaseId":account,"login":"Fixture \(account)"] }
    private func oid(_ value:String) -> [String:Any] { ["oid":value] }
    private func response(_ value:Any,status:Int=200) throws -> GitHubResponse {
        .init(status:status,headers:["X-RateLimit-Remaining":"4900","X-RateLimit-Reset":"1893456000"],data:try JSONSerialization.data(withJSONObject:value))
    }
    private func node(_ number:Int,_ account:Int) -> [String:Any] {
        let head=PRPhase1Fixtures.head(number),empty=page([])
        let author=number == 8 ? "Fixture 42" : "Fixture author"
        return ["id":"NODE\(number)","number":number,"title":"Phase 1 \(number) · \([1:"Cached review",2:"Direct merge",3:"Ineligible draft",4:"Revision movement",5:"Lost comment",6:"Native lower",7:"Native upper",8:"Own author",9:"Inferred lower",10:"Inferred upper"][number]!)","url":"https://github.com/o/r/pull/\(number)","body":"Offline provider-shaped review fixture 🐈","state":merged.contains(number) ? "MERGED" : "OPEN","isDraft":number == 3,"headRefOid":head,"baseRefOid":PRPhase1Fixtures.base(number),"headRefName":"layer-\(number)","baseRefName":number == 10 ? "layer-9" : "main","headRepository":["databaseId":1],"createdAt":"2026-10-01T10:00:00Z","updatedAt":"2026-10-01T11:00:00Z","mergedAt":merged.contains(number) ? "2026-10-01T22:00:00Z" as Any : NSNull(),"mergeCommit":merged.contains(number) ? oid(PRPhase1Fixtures.mergedCommit) as Any : NSNull(),"author":["id":number == 8 ? "U42" : "AUTHOR","login":author,"__typename":"User"],"viewerDidAuthor":number == 8 && account == 42,"viewerCanUpdate":number != 8,"viewerCanClose":number != 8,"viewerCanReopen":number != 8,"viewerCanAssign":number != 8,"viewerCanLabel":number != 8,"isLocked":false,"changedFiles":2,"additions":3,"deletions":3,"reviewDecision":NSNull(),"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","autoMergeRequest":NSNull(),"isMergeQueueEnabled":false,"isInMergeQueue":false,"viewerCanEnableAutoMerge":true,"viewerCanDisableAutoMerge":false,"viewerCanUpdateBranch":true,"baseRef":["branchProtectionRule":NSNull()],"repository":["id":"REPOSITORY_NODE","databaseId":1,"nameWithOwner":"o/r","isPrivate":true,"viewerPermission":number == 8 ? "READ" : "WRITE","mergeCommitAllowed":true,"squashMergeAllowed":true,"rebaseMergeAllowed":true,"autoMergeAllowed":true],"labels":empty,"assignees":empty,"reviews":empty,"reviewRequests":empty,"timelineItems":empty,"comments":["totalCount":0],"commits":page([["commit":["oid":head,"parents":["totalCount":1],"statusCheckRollup":["state":"SUCCESS"]]]]),"milestone":NSNull()]
    }
    private func mergeNode(_ number:Int,_ account:Int) -> [String:Any] {
        var value=node(number,account)
        value["headRef"]=["target":["oid":PRPhase1Fixtures.head(number),"parents":["nodes":[oid(PRPhase1Fixtures.origin)]],"statusCheckRollup":["contexts":page([["__typename":"CheckRun","name":"Optional lint","status":"COMPLETED","conclusion":"FAILURE","checkSuite":["app":["databaseId":41],"workflowRun":["event":"pull_request"]]]])]]]
        value["potentialMergeCommit"]=NSNull();value["reviewThreads"]=page([])
        value["stack"]=NSNull()
        if [6,7].contains(number) {
            var entries=page([["position":1,"pullRequest":node(6,account)]])
            entries["pageInfo"]=["hasNextPage":true,"endCursor":"native-second"]
            value["stack"]=["id":"NATIVE_STACK","number":7,"size":2,"entries":entries]
        }
        return value
    }
    private func comment(_ id:String,_ body:String,_ account:Int) -> [String:Any] {
        ["id":id,"body":body,"createdAt":ISO8601DateFormatter().string(from:Date()),"author":["login":"Fixture \(account)"],"viewerDidAuthor":true,"viewerCanUpdate":true,"viewerCanDelete":true,"viewerCanReact":true,"viewerCanMinimize":true,"viewerCanUnminimize":false,"isMinimized":false,"reactionGroups":[],"url":"https://github.com/o/r/pull/1#discussion"]
    }
    private func number(_ node:String?) throws -> Int {
        guard let node,node.hasPrefix("NODE"),let n=Int(node.dropFirst(4)),(1...10).contains(n),node == "NODE\(n)" else { throw GitHubFailure.invalidResponse };return n
    }
    private func queryItems(_ url:URL) -> [String:String] {
        Dictionary((URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,_ in "duplicate" })
    }
    func send(_ request:URLRequest) async throws -> GitHubResponse {
        guard let url=request.url,url.scheme == "https",url.host == "api.github.com",url.user == nil,url.password == nil,(url.port ?? 443) == 443,
              let account=PRPhase1Fixtures.accounts.first(where:{ request.value(forHTTPHeaderField:"Authorization") == "Bearer "+PRPhase1Fixtures.token($0) }),let actor=Int(account.accountID) else { throw GitHubFailure.unsafeURL }
        let method=request.httpMethod ?? "GET",path=url.path,items=queryItems(url)
        let body=try request.httpBody.map { try JSONSerialization.jsonObject(with:$0) as? [String:Any] } ?? nil
        let query=body?["query"] as? String ?? ""
        let mutation=method != "GET" && !(method == "POST" && query.hasPrefix("query "))
        if mutation { mutations += 1 } else { reads += 1 }
        guard reads <= 384,mutations <= 12 else { throw GitHubFailure.resourceDenied }
        let family=query.split(separator:"(").first.map(String.init) ?? method+" "+path
        print("T9 transport account=\(actor) route=\(family) reads=\(reads) mutations=\(mutations)")
        if denyB && actor == 42 { return .init(status:401) }
        if holdRefresh,method == "GET",path == "/repos/o/r/pulls/1" { await withCheckedContinuation { refreshGates.append($0) } }
        if path == "/graphql",method == "POST",items.isEmpty,let vars=body?["variables"] as? [String:Any] {
            if query.hasPrefix("query Inventory("),vars["owner"] as? String == "o",vars["repo"] as? String == "r",vars["after"] == nil || vars["after"] is NSNull {
                return try response(["data":["viewer":viewer(actor),"repository":["pullRequests":page((1...10).map { node($0,actor) })],"rateLimit":["cost":1,"remaining":4900,"resetAt":"2030-01-01T00:00:00Z"]]])
            }
            if query.hasPrefix("query PRReadOnlyContext("),vars["owner"] as? String == "o",vars["repo"] as? String == "r",vars["after"] == nil || vars["after"] is NSNull {
                guard let range=query.range(of:"pullRequest(number:"),let n=Int(query[range.upperBound...].prefix(while:{ $0.isNumber })),(1...10).contains(n) else { throw GitHubFailure.invalidResponse }
                var pr=node(n,actor);pr["closingIssuesReferences"]=page([]);pr["commits"]=page([])
                return try response(["data":["repository":["pullRequest":pr]]])
            }
            if query.hasPrefix("mutation Command("),let input=vars["input"] as? [String:Any] { return try mutate(query,input,actor) }
            let n=try number(vars["id"] as? String),key="\(actor):\(n)"
            guard Set(vars.keys).isSubset(of:["id","after"]) else { throw GitHubFailure.invalidResponse }
            if query.hasPrefix("query StackPage("),[6,7].contains(n),vars["after"] as? String == "native-second" {
                return try response(["data":["node":["headRefOid":PRPhase1Fixtures.head(n),"stack":["id":"NATIVE_STACK","entries":page([["position":2,"pullRequest":node(7,actor)]])]]]])
            }
            guard vars["after"] == nil || vars["after"] is NSNull else { throw GitHubFailure.invalidResponse }
            var value=node(n,actor)
            if query.hasPrefix("query MergeEvidence(") { value=mergeNode(n,actor) }
            else if query.hasPrefix("query MergeIdentity(") { if n == 4,moveRevision { value["headRefOid"]=PRPhase1Fixtures.later } }
            else if query.hasPrefix("query WriteIdentity(") || query.hasPrefix("query WriteAfter(") { }
            else if query.hasPrefix("query WriteConnection(") {
                if query.contains("reviewThreads(first:") { value["reviewThreads"]=page(threads[key] ?? []) }
                else if query.contains("reviews(first:") { value["reviews"]=page(reviews[key] ?? []) }
                else if query.contains("comments(first:") { value["comments"]=page(comments[key] ?? []) }
                else if query.contains("files(first:") { value["files"]=page(["sample.swift","new.swift"].map { ["path":$0,"viewerViewedState":viewed.contains(key+":"+$0) ? "VIEWED" : "UNVIEWED"] }) }
                else if query.contains("reviewRequests(first:") { value["reviewRequests"]=page([]) }
                else { throw GitHubFailure.resourceDenied }
            } else { throw GitHubFailure.resourceDenied }
            return try response(["data":["viewer":viewer(actor),"node":value,"rateLimit":["cost":1,"remaining":4900,"resetAt":"2030-01-01T00:00:00Z"]]])
        }
        if method == "GET",path == "/repos/o/r/notifications",items == ["all":"true","per_page":"50"] {
            return try response([["id":"99","reason":"review_requested","updated_at":"2026-10-01T11:00:00Z","repository":["id":1],"subject":["title":"Simulated provider review request","type":"PullRequest","url":"https://api.github.com/repos/o/r/pulls/1"]]])
        }
        if path == "/notifications/threads/99",items.isEmpty,body == nil {
            if method == "GET" { return try response(["id":"99","unread":unreadThreads.contains(account.accountID),"repository":["id":1]]) }
            if method == "PATCH" || method == "DELETE" { unreadThreads.remove(account.accountID);return .init(status:method == "PATCH" ? 205 : 204) }
        }
        if method == "GET",path == "/user/teams",items == ["per_page":"100"] { return try response([]) }
        if method == "GET",path == "/repos/o/r/rulesets",items == ["per_page":"100","includes_parents":"true"] { return try response([]) }
        if method == "GET",["/repos/o/r/rules/branches/main","/repos/o/r/rules/branches/layer-9"].contains(path),items == ["per_page":"100"] { return try response([]) }
        if method == "GET",path.hasPrefix("/repos/o/r/contents/"),Set(items.keys) == ["ref"],let sha=items["ref"],([PRPhase1Fixtures.origin,PRPhase1Fixtures.target]+(1...10).map(PRPhase1Fixtures.head)).contains(sha) {
            let file=String(path.dropFirst("/repos/o/r/contents/".count)),source:String
            switch file { case "sample.swift":source=PRPhase1Fixtures.source();case "old.swift":source="old\ndeleted\n";case "new.swift":source="new\nreplacement\n";case ".gitattributes":source="*.swift linguist-language=Swift\n";default:throw GitHubFailure.resourceDenied }
            return try response(["type":"file","encoding":"base64","size":source.utf8.count,"content":Data(source.utf8).base64EncodedString()])
        }
        if method == "GET",path.hasPrefix("/repos/o/r/compare/"),items.isEmpty {
            let pair=String(path.dropFirst("/repos/o/r/compare/".count)).components(separatedBy:"...")
            guard pair.count == 2,(1...10).contains(where:{ pair == [PRPhase1Fixtures.base($0),PRPhase1Fixtures.head($0)] }) else { throw GitHubFailure.resourceDenied }
            return try response(["merge_base_commit":["sha":PRPhase1Fixtures.origin]])
        }
        let pieces=path.split(separator:"/").map(String.init)
        if pieces.count >= 6,Array(pieces.prefix(3)) == ["repos","o","r"],pieces[3] == "pulls",let n=Int(pieces[4]),(1...10).contains(n) {
            if method == "GET",pieces.count == 6,pieces[5] == "files",items == ["per_page":"100","page":"1"] {
                return try response([["filename":"sample.swift","status":"modified","patch":"@@ -1,500 +1,500 @@\n"+PRPhase1Fixtures.source().split(separator:"\n").map { " "+$0 }.joined(separator:"\n"),"additions":0,"deletions":0],["filename":"new.swift","previous_filename":"old.swift","status":"renamed","patch":"@@ -1,2 +1,2 @@\n-old\n-deleted\n+new\n+replacement","additions":2,"deletions":2]])
            }
            if n == 2,pieces[5] == "merge-async",method == "PUT",pieces.count == 6,items.isEmpty,let body {
                guard body["sha"] as? String == PRPhase1Fixtures.head(2),body["merge_action"] as? String == "direct_merge",["merge","squash","rebase"].contains(body["merge_method"] as? String ?? ""),body["bypass_rules"] as? Bool == false,Set(body.keys).isSubset(of:["sha","merge_action","merge_method","bypass_rules","commit_title","commit_message"]) else { throw GitHubFailure.invalidResponse }
                guard !mergeStarted else { throw GitHubFailure.resourceDenied };mergeStarted=true;mergeMethod=body["merge_method"] as! String
                return try response(["status":"pending","details":["uuid":asyncID.uuidString,"expected_head_sha":PRPhase1Fixtures.head(2),"merge_action":"direct_merge","merge_method":body["merge_method"]!,"bypass_rules":false]],status:202)
            }
            if n == 2,pieces.count == 7,pieces[5] == "merge-async",pieces[6].uppercased() == asyncID.uuidString,method == "GET",items.isEmpty {
                guard mergeStarted,statusReads < 4 else { throw GitHubFailure.resourceDenied }
                statusReads += 1
                if mergeReady { merged.insert(2);return try response(["status":"merged","details":["sha":PRPhase1Fixtures.mergedCommit,"message":"Offline finite receipt"]]) }
                return try response(["status":"pending","details":["uuid":asyncID.uuidString,"expected_head_sha":PRPhase1Fixtures.head(2),"merge_action":"direct_merge","merge_method":mergeMethod,"bypass_rules":false]])
            }
        }
        if method == "GET",pieces.count == 5,Array(pieces.prefix(4)) == ["repos","o","r","pulls"],let n=Int(pieces[4]),(1...10).contains(n),items.isEmpty {
            return try response(["body":"Offline provider-shaped review fixture 🐈","head":["sha":PRPhase1Fixtures.head(n)],"base":["sha":PRPhase1Fixtures.base(n)],"changed_files":2])
        }
        if method == "GET",items == ["per_page":"100","page":"1"],(1...10).contains(where:{ path == "/repos/o/r/issues/\($0)/timeline" || path == "/repos/o/r/pulls/\($0)/comments" || path == "/repos/o/r/commits/\(PRPhase1Fixtures.head($0))/statuses" }) { return try response([]) }
        if method == "GET",items == ["per_page":"100","page":"1"],(1...10).contains(where:{ path == "/repos/o/r/commits/\(PRPhase1Fixtures.head($0))/check-runs" }) { return try response(["check_runs":[]]) }
        throw GitHubFailure.resourceDenied
    }
    private func mutate(_ query:String,_ input:[String:Any],_ account:Int) throws -> GitHubResponse {
        let direct=input["pullRequestId"] as? String ?? input["subjectId"] as? String
        let pending=input["pullRequestReviewId"] as? String
        let n:Int
        if let direct { n=try number(direct) }
        else if let pending,let found=reviews.first(where:{ $0.key.hasPrefix("\(account):") && $0.value.contains(where:{ $0["id"] as? String == pending }) }) { n=Int(found.key.split(separator:":").last!)! }
        else { throw GitHubFailure.invalidResponse }
        guard [1,5,8].contains(n),UUID(uuidString:input["clientMutationId"] as? String ?? "") != nil else { throw GitHubFailure.resourceDenied }
        let key="\(account):\(n)"
        if n == 8 { return try response(["data":["mutation":NSNull()],"errors":[["type":"FORBIDDEN","message":"Named fixture permission denial"]]]) }
        var payload:[String:Any]=["clientMutationId":input["clientMutationId"]!]
        if query.contains("addPullRequestReview(") {
            guard Set(input.keys).isSubset(of:["pullRequestId","commitOID","body","event","clientMutationId"]),input["commitOID"] as? String == PRPhase1Fixtures.head(n),let body=input["body"] as? String else { throw GitHubFailure.invalidResponse }
            let event=input["event"] as? String
            guard event == nil || ["COMMENT","APPROVE","REQUEST_CHANGES"].contains(event!) else { throw GitHubFailure.invalidResponse }
            let review:[String:Any]=["id":"REVIEW-\(account)-\(n)-\(mutations)","body":body,"state":event == nil ? "PENDING" : event == "APPROVE" ? "APPROVED" : event == "REQUEST_CHANGES" ? "CHANGES_REQUESTED" : "COMMENTED","commit":oid(PRPhase1Fixtures.head(n)),"createdAt":ISO8601DateFormatter().string(from:Date()),"submittedAt":ISO8601DateFormatter().string(from:Date()),"author":["login":"Fixture \(account)"]]
            reviews[key,default:[]].append(review);payload["pullRequestReview"]=review
        } else if query.contains("submitPullRequestReview(") {
            guard Set(input.keys).isSubset(of:["pullRequestReviewId","body","event","clientMutationId"]),let pending,let index=reviews[key]?.firstIndex(where:{ $0["id"] as? String == pending }),let body=input["body"] as? String,let event=input["event"] as? String,["COMMENT","APPROVE","REQUEST_CHANGES"].contains(event) else { throw GitHubFailure.invalidResponse }
            reviews[key]![index]["body"]=body;reviews[key]![index]["state"]=event == "APPROVE" ? "APPROVED" : event == "REQUEST_CHANGES" ? "CHANGES_REQUESTED" : "COMMENTED"
            payload["pullRequestReview"]=reviews[key]![index]
        } else if query.contains("addPullRequestReviewThread(") {
            guard Set(input.keys).isSubset(of:["pullRequestReviewId","body","path","subjectType","line","side","startLine","startSide","clientMutationId"]),let pending,let body=input["body"] as? String,let path=input["path"] as? String,["sample.swift","new.swift"].contains(path),let subject=input["subjectType"] as? String,["FILE","LINE"].contains(subject) else { throw GitHubFailure.invalidResponse }
            if subject == "LINE" { guard let line=input["line"] as? Int,(1...(path == "new.swift" ? 2 : 500)).contains(line),["LEFT","RIGHT"].contains(input["side"] as? String ?? "") else { throw GitHubFailure.invalidResponse } }
            var value=comment("COMMENT-\(account)-\(mutations)",body,account)
            value["commit"]=oid(PRPhase1Fixtures.head(n));value["originalCommit"]=oid(PRPhase1Fixtures.head(n));value["pullRequestReview"]=["id":pending]
            value["line"]=input["line"];value["originalLine"]=input["line"];value["startLine"]=input["startLine"];value["originalStartLine"]=input["startLine"]
            var thread:[String:Any]=["id":"THREAD-\(account)-\(mutations)","path":path,"subjectType":subject,"isOutdated":false,"isResolved":false,"viewerCanReply":true,"viewerCanResolve":true,"viewerCanUnresolve":false,"comments":page([value])]
            for field in ["line","startLine"] { thread[field]=input[field] }
            thread["originalLine"]=input["line"];thread["originalStartLine"]=input["startLine"];thread["diffSide"]=input["side"];thread["startDiffSide"]=input["startSide"]
            threads[key,default:[]].append(thread);payload["thread"]=thread
        } else if query.contains("markFileAsViewed(") {
            guard Set(input.keys).isSubset(of:["pullRequestId","path","clientMutationId"]),let path=input["path"] as? String,["sample.swift","new.swift"].contains(path) else { throw GitHubFailure.invalidResponse }
            viewed.insert(key+":"+path);payload["pullRequest"]=["id":"NODE\(n)","headRefOid":PRPhase1Fixtures.head(n)]
        } else if query.contains("addComment(") {
            guard Set(input.keys).isSubset(of:["subjectId","body","clientMutationId"]),let body=input["body"] as? String else { throw GitHubFailure.invalidResponse }
            let value=comment("CONVERSATION-\(account)-\(mutations)",body,account)
            comments[key,default:[]].append(value);payload["commentEdge"]=["node":value]
            if n == 5,loseConversation { loseConversation=false;throw URLError(.networkConnectionLost) }
        } else { throw GitHubFailure.resourceDenied }
        return try response(["data":["mutation":payload]])
    }
}
