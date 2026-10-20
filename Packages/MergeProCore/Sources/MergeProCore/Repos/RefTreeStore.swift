import Foundation

public enum TreeChildrenState: Equatable,Sendable { case unloaded,loading,loaded,incomplete,failed(String) }
public struct RefTreeSnapshot:Sendable {
    public var ref:ResolvedRepositoryRef?
    public var children:[String:[GitTreeEntry]] = [:]
    public var loading:[String:TreeChildrenState] = [:]
    public var selection:String?
    public var missingPath:String?
    public var generation:UInt64 = 0
    public init() {}
    public var entries:[GitTreeEntry] { children.values.flatMap { $0 } }
}
public actor RefTreeStore {
    private let provider:any GitTreeProvider
    private var repository:RepoCatalogEntry?
    private var state=RefTreeSnapshot()
    public init(provider:any GitTreeProvider) { self.provider=provider }
    public func snapshot() -> RefTreeSnapshot { state }
    public func switchRef(repository:RepoCatalogEntry,ref:ResolvedRepositoryRef,preserving path:String? = nil) async throws {
        state.generation &+= 1;let generation=state.generation
        self.repository=repository;state.ref=ref;state.children=[:];state.loading=[:];state.missingPath=nil;state.selection=nil
        try await load(path:"",sha:ref.treeSHA,generation:generation)
        guard generation == state.generation else { throw CancellationError() }
        if let path { try await reveal(path,generation:generation) }
    }
    public func expand(_ path:String) async throws {
        guard state.loading[path] != .loaded,state.loading[path] != .loading,let entry=state.entries.first(where:{ $0.path == path && $0.kind == .directory }) else { return }
        try await load(path:path,sha:entry.sha,generation:state.generation)
    }
    public func retry(_ path:String) async throws {
        guard let ref=state.ref else { return }
        let sha=path.isEmpty ? ref.treeSHA : state.entries.first(where:{ $0.path == path })?.sha
        if let sha { try await load(path:path,sha:sha,generation:state.generation) }
    }
    public func select(_ path:String?) { state.selection=path }
    public func reveal(_ path:String) async throws { try await reveal(path,generation:state.generation) }
    private func reveal(_ path:String,generation:UInt64) async throws {
        let components=path.split(separator:"/").map(String.init);var parent=""
        for (index,component) in components.enumerated() {
            let candidate=parent.isEmpty ? component : parent+"/"+component
            guard let entry=state.children[parent]?.first(where:{ $0.path == candidate }) else {
                guard generation == state.generation else { throw CancellationError() }
                state.selection=parent.isEmpty ? nil : parent;state.missingPath=path;return
            }
            parent=candidate
            if index < components.count-1,entry.kind == .directory { try await load(path:parent,sha:entry.sha,generation:generation) }
            guard generation == state.generation else { throw CancellationError() }
        }
        state.selection=parent;state.missingPath=nil
    }
    private func load(path:String,sha:String,generation:UInt64) async throws {
        guard generation == state.generation,let repository,let ref=state.ref else { throw CancellationError() }
        if state.loading[path] == .loaded { return }
        state.loading[path] = .loading
        do {
            let page=try await provider.children(repository:repository,ref:ref,treeSHA:sha)
            try Task.checkCancellation();guard generation == state.generation else { throw CancellationError() }
            state.children[path]=page.entries.map { $0.prefixed(path) }.sorted {
                if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory };return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            state.loading[path]=page.truncated ? .incomplete : .loaded
        } catch {
            if generation == state.generation { state.loading[path] = .failed(String(describing:error)) }
            throw error
        }
    }
}
