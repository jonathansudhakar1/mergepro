import Foundation

public protocol RepositoryCommitProvider:Sendable {
    func commits(repository:RepoCatalogEntry,ref:ResolvedRepositoryRef,path:String?,author:String?,page:Int) async throws -> RepositoryPage<RepositoryCommit>
}
extension RepositoryBrowserService:RepositoryCommitProvider {}
public struct RepositoryHistorySnapshot:Sendable {
    public var commits:[RepositoryCommit]=[]
    public var nextPage:Int?=1
    public var loading=false
    public var generation:UInt64=0
    public init() {}
}
public actor RepositoryHistoryStore {
    private let provider:any RepositoryCommitProvider
    private var repository:RepoCatalogEntry?
    private var ref:ResolvedRepositoryRef?
    private var path:String?
    private var author:String?
    private var state=RepositoryHistorySnapshot()
    public init(provider:any RepositoryCommitProvider) { self.provider=provider }
    public func snapshot() -> RepositoryHistorySnapshot { state }
    public func reset(repository:RepoCatalogEntry,ref:ResolvedRepositoryRef,path:String?,author:String?) async throws {
        state.generation &+= 1;state.commits=[];state.nextPage=1;state.loading=false
        self.repository=repository;self.ref=ref;self.path=path;self.author=author
        try await loadMore()
    }
    public func loadMore() async throws {
        guard !state.loading,let page=state.nextPage,let repository,let ref else { return }
        state.loading=true;let generation=state.generation
        do {
            let result=try await provider.commits(repository:repository,ref:ref,path:path,author:author,page:page)
            guard generation==state.generation,!Task.isCancelled else { throw CancellationError() }
            let known=Set(state.commits.map(\.sha));state.commits += result.values.filter { !known.contains($0.sha) };state.nextPage=result.nextPage;state.loading=false
        } catch { if generation==state.generation { state.loading=false };throw error }
    }
}
