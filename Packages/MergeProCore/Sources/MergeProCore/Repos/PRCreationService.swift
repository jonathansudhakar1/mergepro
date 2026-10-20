import Foundation

public struct CreatePRCommand:Codable,Sendable,Equatable {
    public let repository:ProviderKey
    public let repositoryName:String
    public let head:String
    public let base:String
    public let title:String
    public let body:String
    public let draft:Bool
    public let reviewers:[String]
    public let headRepository:String?
    public init(repository:ProviderKey,repositoryName:String,head:String,base:String,title:String,body:String,draft:Bool,reviewers:[String],headRepository:String? = nil) { self.repository=repository;self.repositoryName=repositoryName;self.head=head;self.base=base;self.title=title;self.body=body;self.draft=draft;self.reviewers=reviewers;self.headRepository=headRepository }
    public func validate() throws {
        _ = try GitHubRepoReader.repositoryPath(repositoryName)
        guard repository.host == "github.com",!title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,title.count<=256,BranchService.validName(base),head != base,body.utf8.count<=65536,reviewers.count<=15,reviewers.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) else { throw RepositoryBrowserFailure.invalidRef }
        let parts=head.split(separator:":",omittingEmptySubsequences:false)
        guard (1...2).contains(parts.count),BranchService.validName(String(parts.last!)) else { throw RepositoryBrowserFailure.invalidRef }
        if parts.count == 2 {
            guard let headRepository,headRepository.split(separator:"/").first.map(String.init) == String(parts[0]) else { throw RepositoryBrowserFailure.permissionDenied }
            _ = try GitHubRepoReader.repositoryPath(headRepository)
        }
    }
    public var headBranch:String { head.split(separator:":").last.map(String.init) ?? head }
    public var qualifiedHead:String { head.contains(":") ? head : (repositoryName.split(separator:"/").first.map(String.init) ?? "")+":"+head }
}
