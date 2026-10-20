import Foundation

public struct RepositoryCommit: Identifiable,Equatable,Codable,Sendable {
    public let sha:String
    public let message:String
    public let author:String
    public let date:Date?
    public let webURL:URL?
    public let checks:String?
    public var id:String { sha }
    public init(sha:String,message:String,author:String,date:Date?,webURL:URL?,checks:String? = nil) { self.sha=sha;self.message=message;self.author=author;self.date=date;self.webURL=webURL;self.checks=checks }
}
public struct RepositoryPage<Value:Sendable>:Sendable {
    public let values:[Value]
    public let nextPage:Int?
    public init(values:[Value],nextPage:Int?) { self.values=values;self.nextPage=nextPage }
}
public struct RepositoryBranch: Identifiable,Equatable,Codable,Sendable {
    public let name:String
    public let sha:String
    public let protected:Bool
    public var ahead:Int?
    public var behind:Int?
    public var linkedPR:ProviderKey?
    public var message:String?
    public var id:String { name }
    public init(name:String,sha:String,protected:Bool,ahead:Int? = nil,behind:Int? = nil,linkedPR:ProviderKey? = nil,message:String? = nil) { self.name=name;self.sha=sha;self.protected=protected;self.ahead=ahead;self.behind=behind;self.linkedPR=linkedPR;self.message=message }
}
public struct RepositoryTag:Identifiable,Equatable,Codable,Sendable {
    public let name:String
    public let sha:String
    public var id:String { name }
    public init(name:String,sha:String) { self.name=name;self.sha=sha }
}
public struct RepositoryReleaseAsset:Identifiable,Equatable,Codable,Sendable {
    public let id:Int
    public let name:String
    public let size:Int
    public let downloadURL:URL?
    public init(id:Int,name:String,size:Int,downloadURL:URL?) { self.id=id;self.name=name;self.size=size;self.downloadURL=downloadURL }
}
public struct RepositoryRelease:Identifiable,Equatable,Codable,Sendable {
    public let id:Int
    public let name:String
    public let tag:String
    public let body:String
    public let draft:Bool
    public let prerelease:Bool
    public let publishedAt:Date?
    public let webURL:URL?
    public let assets:[RepositoryReleaseAsset]
    public init(id:Int,name:String,tag:String,body:String,draft:Bool,prerelease:Bool,publishedAt:Date?,webURL:URL?,assets:[RepositoryReleaseAsset]) { self.id=id;self.name=name;self.tag=tag;self.body=body;self.draft=draft;self.prerelease=prerelease;self.publishedAt=publishedAt;self.webURL=webURL;self.assets=assets }
}
public struct RepositoryComparison:Equatable,Codable,Sendable {
    public let status:String
    public let ahead:Int
    public let behind:Int
    public let commits:[RepositoryCommit]
    public let files:[RepositoryChangedFile]
    public let webURL:URL?
    public let incomplete:Bool
    public init(status:String,ahead:Int,behind:Int,commits:[RepositoryCommit],files:[RepositoryChangedFile],webURL:URL?,incomplete:Bool) { self.status=status;self.ahead=ahead;self.behind=behind;self.commits=commits;self.files=files;self.webURL=webURL;self.incomplete=incomplete }
}
public struct RepositoryChangedFile:Identifiable,Equatable,Codable,Sendable {
    public let path:String
    public let status:String
    public let additions:Int
    public let deletions:Int
    public let patch:String?
    public var id:String { path }
    public init(path:String,status:String,additions:Int,deletions:Int,patch:String?) { self.path=path;self.status=status;self.additions=additions;self.deletions=deletions;self.patch=patch }
}
public struct CreatedRepositoryPR:Equatable,Sendable {
    public let key:ProviderKey
    public let number:Int
    public let existing:Bool
    public let reviewersPending:Bool
    public init(key:ProviderKey,number:Int,existing:Bool,reviewersPending:Bool = false) { self.key=key;self.number=number;self.existing=existing;self.reviewersPending=reviewersPending }
}
