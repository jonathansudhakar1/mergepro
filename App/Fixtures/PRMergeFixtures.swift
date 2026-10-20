import Foundation
import MergeProCore

enum PRMergeFixtures {
    static var enabled:Bool { PRNativeFixtures.enabled && ProcessInfo.processInfo.environment["MERGEPRO_MERGE_FIXTURES"] == "1" }
    static let account=AccountScope(host:"github.com",accountID:"4242")
    static func seed(_ database:DatabaseStore) throws {
        guard enabled,try database.applicationSetting(.mergeFixtureSeeded) == nil else { return }
        let repository=RepositoryKey(account:account,repositoryID:"1")
        try database.saveAccount(.init(scope:account,login:"Offline merge actor",tokenReference:nil))
        try database.saveRepository(.init(key:repository,name:"fixtures/merge",isPrivate:false,capabilities:[]));try database.setTracked(repository,tracked:true)
        try database.setApplicationSetting(AccountSessionStore.tokenReference(for:account),for:.activeActionAccount)
        let topology=ProcessInfo.processInfo.environment["MERGEPRO_MERGE_TOPOLOGY"] ?? "none"
        var rows=(1...4).map { n -> PullRequest in
            let key=ProviderKey(host:account.host,accountID:account.accountID,repositoryID:"1",objectID:"pull-request:FIX_PR\(n)")
            var m=PRMetadata(number:n,webURL:URL(string:"https://github.com/fixtures/merge/pull/\(n)")!,repositoryName:"fixtures/merge")
            m.headRepositoryID="1";m.headBranch="layer-\(n)";m.baseBranch=topology == "inferred" && n>1 && n<4 ? "layer-\(n-1)" : "main";m.baseRevision="base";m.updatedAt=Date();m.createdAt=Date();m.fetchedAt=Date();m.checks="SUCCESS"
            var e=MergeEvidence(key:key,head:"head-\(n)",base:"base",branch:m.baseBranch,fetchedAt:Date());e.open=true;e.draft=n==4;e.actorAllowed=true;e.tokenCanWrite=true;e.conflictFree=true;e.rulesComplete=true;e.asyncSupported=true;e.methods=[.merge,.squash,.rebase];e.canEnableAutoMerge=true;e.canUpdateBranch=true
            m.mergeEvidence=e;m.mergeEligible=MergePolicy.evaluate(e).eligible
            return .init(key:key,headRevision:.init(e.head),title:n==4 ? "Ineligible draft" : "Merge fixture layer \(n)",state:.open,isDraft:n==4,metadata:m)
        }
        if topology == "native" {
            let stack=StackGraph.native(id:"FIX_STACK",number:1,size:3,entries:Array(rows.prefix(3)).enumerated().map { .init(position:$0.offset+1,pr:$0.element) },complete:true,linear:true)
            rows=rows.map { pr in var m=pr.metadata;if m!.number<4 { m?.nativeStack=stack };return .init(key:pr.key,headRevision:pr.headRevision,title:pr.title,state:pr.state,isDraft:pr.isDraft,metadata:m) }
        }
        try database.savePullRequests(rows);try database.setApplicationSetting("true",for:.mergeFixtureSeeded)
    }
    /// GitHub's documented defaults composed offline, so the fixture sheet shows prefilled, editable text.
    /// Two commits and a body trailer exercise squash co-author trailers; addresses are reserved `.invalid` fixtures.
    static func messageDefaults(_ pr:PullRequest) -> MergeMessageDefaults? {
        guard let m=pr.metadata,m.number>0 else { return nil }
        let author=MergeMessageAuthor(name:"Offline merge actor",email:"merge-actor@fixtures.invalid",login:"offline-merge-actor")
        let pair=MergeMessageAuthor(name:"Fixture Pair",email:"pair@fixtures.invalid",login:"fixture-pair")
        let commits=[MergeMessageCommit(headline:"Add \(m.headBranch)",authors:[author]),
                     MergeMessageCommit(headline:"Address review on \(m.headBranch)",body:"Co-authored-by: Fixture Reviewer <reviewer@fixtures.invalid>",authors:[author,pair])]
        let settings=MergeMessageSettings()
        let (titles,bodies)=MergeMessageComposer.fallback(settings:settings,prTitle:pr.title,prBody:"Offline fixture body for \(m.headBranch).",number:m.number,headLabel:"fixtures:"+m.headBranch,commits:commits,prAuthor:author.login)
        return .init(head:pr.headRevision.rawValue,titles:titles,bodies:bodies,coAuthorTrailers:MergeMessageComposer.coAuthors(commits:commits,prAuthor:author.login),settings:settings,commitsComplete:true,providerPrefill:false)
    }
    static func response(_ request:URLRequest) throws -> GitHubResponse {
        let body=request.httpBody.flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] } ?? [:]
        let number=request.url?.path.split(separator:"/").dropLast().last.flatMap { Int($0) } ?? 1
        let pending:[String:Any] = ["status":"pending","details":["uuid":"11111111-1111-1111-1111-111111111111","expected_head_sha":body["sha"] as? String ?? "head-\(number)","merge_action":body["merge_action"] as? String ?? "direct_merge","merge_method":body["merge_method"] as? String ?? "squash","bypass_rules":false]]
        let merged:[String:Any] = ["status":"merged","details":["sha":"fixture-merge-commit","message":"Offline fixture result"]]
        return .init(status:202,data:try JSONSerialization.data(withJSONObject:ProcessInfo.processInfo.environment["MERGEPRO_MERGE_RESULT"] == "merged" ? merged : pending))
    }
}
struct PRMergeFixtureAdapter:MergeAdapter {
    let database:DatabaseStore
    func inspect(_ target:MergeTarget,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> MergeInspection {
        guard PRMergeFixtures.enabled,let pr=try database.snapshot(for:target.key.account).pullRequests.first(where:{ $0.key == target.key }),var evidence=pr.metadata?.mergeEvidence else { throw PRWriteFailure.unavailable }
        evidence.fetchedAt=Date();evidence.operationInProgress=false
        let merged=try DraftReviewStore(database:database).operations(target.key).contains { operation in
            guard case .merge=operation.command.intent,let response=operation.response,let root=try? JSONSerialization.jsonObject(with:response) as? [String:Any] else { return false };return root["status"] as? String == "merged"
        }
        let truth=PullRequest(key:pr.key,headRevision:pr.headRevision,title:pr.title,state:merged ? .merged : pr.state,isDraft:pr.isDraft,metadata:pr.metadata)
        return .init(pr:truth,evidence:evidence,stack:pr.metadata?.nativeStack,mergeCommitSHA:merged ? "fixture-merge-commit" : nil)
    }
    func messageDefaults(_ target:MergeTarget,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> MergeMessageDefaults? {
        guard PRMergeFixtures.enabled,let pr=try database.snapshot(for:target.key.account).pullRequests.first(where:{ $0.key == target.key }),pr.headRevision.rawValue == target.head else { return nil }
        return PRMergeFixtures.messageDefaults(pr)
    }
    func send(_ operation:PRWriteOperation,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> GitHubResponse { try await GitHubMergeAdapter().send(operation,client:client,credential:credential) }
    func status(_ id:UUID,target:MergeTarget,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> GitHubResponse { try await GitHubMergeAdapter().status(id,target:target,client:client,credential:credential) }
}
