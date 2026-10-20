import Foundation
import MergeProCore
@testable import MergePro

/// Holds an async read until the test opens it, so a test decides which of two overlapping reads finishes first.
actor TestGate {
    private var isOpen=false
    private var waiting=0
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    private var arrivals:[CheckedContinuation<Void,Never>]=[]
    func wait() async {
        guard !isOpen else { return }
        waiting += 1
        arrivals.forEach { $0.resume() };arrivals=[]
        await withCheckedContinuation { waiters.append($0) }
    }
    /// Returns once a read is waiting at the gate.
    func arrived() async {
        guard waiting == 0 else { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
    func open() { isOpen=true;waiters.forEach { $0.resume() };waiters=[] }
}

/// Scripted detail reads by head SHA (or comparison base); nothing touches storage or the network.
actor FakeDetailServices:PRDetailServices {
    private var snapshots:[String:PRDetailSnapshot]=[:]
    private var failures:[String:any Error]=[:]
    private var gates:[String:TestGate]=[:]
    private var comparisons:[String:DiffDocument]=[:]
    private(set) var detailReads:[String]=[]
    private(set) var savedStates=0
    func script(head:String,snapshot:PRDetailSnapshot? = nil,failure:(any Error)? = nil,gate:TestGate? = nil) {
        snapshots[head]=snapshot;failures[head]=failure;gates[head]=gate
    }
    func scriptComparison(base:String,document:DiffDocument,gate:TestGate? = nil) { comparisons[base]=document;gates["compare:"+base]=gate }

    func detail(_ pr:PullRequest,maxAge:TimeInterval) async throws -> PRDetailSnapshot {
        let head=pr.headRevision.rawValue
        detailReads.append(head)
        if let gate=gates[head] { await gate.wait() }
        if let failure=failures[head] { throw failure }
        guard let snapshot=snapshots[head] else { throw PRDetailFailure.unavailable }
        return snapshot
    }
    func detail(_ pr:PullRequest) async throws -> PRDetailSnapshot { try await detail(pr,maxAge:0) }
    func detailDescription(_ pr:PullRequest,maxAge:TimeInterval) async throws -> PRDescriptionSnapshot {
        .init(body:"Description",headSHA:pr.headRevision.rawValue,fetchedAt:Date(),cached:false)
    }
    func compareDetail(_ pr:PullRequest,base:String,head:String) async throws -> DiffDocument {
        if let gate=gates["compare:"+base] { await gate.wait() }
        guard let document=comparisons[base] else { throw PRDetailFailure.unavailable }
        return document
    }
    func snapshotInterdiff(_ pr:PullRequest,old:String,new:String) async throws -> DiffDocument { try await compareDetail(pr,base:old,head:new) }
    func codeAppearance() async throws -> CodeAppearance { throw PRDetailFailure.unavailable }
    func detailState(_ pr:PullRequest) async throws -> PRDetailState { PRDetailState(headSHA:pr.headRevision.rawValue) }
    func saveDetailState(_ state:PRDetailState,key:ProviderKey) async throws { savedStates += 1 }
    func detailRepositoryBaseline(_ pr:PullRequest) async throws -> RepositorySizeBaseline { throw PRDetailFailure.unavailable }
    func cachedDetailDescription(_ pr:PullRequest) async throws -> PRDescriptionSnapshot? { nil }
    func cachedDetail(_ pr:PullRequest) async throws -> PRDetailSnapshot? { nil }
    func moreDetail(_ pr:PullRequest,snapshot:PRDetailSnapshot) async throws -> PRDetailSnapshot { throw PRDetailFailure.unavailable }
    func cachedDetailSection(_ pr:PullRequest,tab:PRDetailTab) async throws -> PRDetailSection? { nil }
    func detailSection(_ pr:PullRequest,tab:PRDetailTab) async throws -> PRDetailSection { .init(events:[],complete:true) }
    func snapshotFile(_ pr:PullRequest,document:DiffDocument,file:DiffFile) async throws -> DiffFile { throw PRDetailFailure.unavailable }
    func stackComparison(_ pr:PullRequest,base:String,head:String) async throws -> DiffDocument { throw PRDetailFailure.unavailable }
    func reReview(_ actionKey:ProviderKey,currentHead:String,administration:PRReviewAdministration?) async throws -> PRReReviewState? { nil }
}

enum DetailFixtures {
    static func key(_ object:String = "pr-1") -> ProviderKey { .init(host:"github.com",accountID:"account-1",repositoryID:"repo-1",objectID:object) }
    static func pr(head:String,title:String = "Improve caching",object:String = "pr-1",state:PullRequest.State = .open) -> PullRequest {
        .init(key:key(object),headRevision:.init(head),title:title,state:state,isDraft:false)
    }
    static func snapshot(head:String,base:String = "base-sha",files:[String]) -> PRDetailSnapshot {
        .init(body:"Body at \(head)",baseSHA:base,headSHA:head,files:files.map { file($0) },expectedFiles:files.count)
    }
    static func file(_ path:String) -> DiffFile { .init(path:path,status:.modified,patch:"@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n",additions:1,deletions:1) }
}
