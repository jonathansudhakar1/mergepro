import Foundation

public struct ResolvedRepositoryRef: Equatable, Codable, Hashable, Sendable {
    public let name:String
    public let commitSHA:String
    public let treeSHA:String
    public init(name:String,commitSHA:String,treeSHA:String) { self.name=name;self.commitSHA=commitSHA;self.treeSHA=treeSHA }
}
public struct GitTreeEntry: Identifiable, Equatable, Codable, Sendable {
    public let path:String
    public let mode:String
    public let type:String
    public let sha:String
    public let size:Int?
    public var id:String { path }
    public init(path:String,mode:String,type:String,sha:String,size:Int? = nil) { self.path=path;self.mode=mode;self.type=type;self.sha=sha;self.size=size }
    public enum Kind:String,Sendable { case directory,file,symlink,submodule }
    public var kind:Kind { if mode == "160000" || type == "commit" { return .submodule };if mode == "120000" { return .symlink };return type == "tree" ? .directory : .file }
    public func prefixed(_ parent:String) -> GitTreeEntry { GitTreeEntry(path:parent.isEmpty ? path : parent+"/"+path,mode:mode,type:type,sha:sha,size:size) }
}
public struct GitTreePage: Equatable, Codable, Sendable {
    public let entries:[GitTreeEntry]
    public let truncated:Bool
    public init(entries:[GitTreeEntry],truncated:Bool) { self.entries=entries;self.truncated=truncated }
}
public protocol GitTreeProvider:Sendable {
    func children(repository:RepoCatalogEntry,ref:ResolvedRepositoryRef,treeSHA:String) async throws -> GitTreePage
}
public enum RepositoryBlob {
    public enum Kind:String,Sendable { case text,binary,lfsPointer }
    public static func classify(_ data:Data) -> Kind {
        if String(data:data.prefix(512),encoding:.utf8)?.hasPrefix("version https://git-lfs.github.com/spec/v1\n") == true { return .lfsPointer }
        return data.contains(0) || String(data:data,encoding:.utf8) == nil ? .binary : .text
    }
}
public enum RepositoryBrowserFailure:Error,Equatable,Sendable {
    case invalidPath,invalidRef,permissionDenied,protectedBranch,defaultBranch,existingBranch,unknownWriteOutcome,missingRefs,assetTooLarge,invalidAsset,reviewersNotRequested(ProviderKey)
}
