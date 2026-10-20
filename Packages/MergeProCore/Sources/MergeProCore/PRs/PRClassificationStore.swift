import Foundation
import GRDB

/// User rules are account-scoped configuration, distinct from cached provider identity.
public struct PRClassificationStore:Sendable {
    private let database:DatabaseStore
    public init(database:DatabaseStore) { self.database=database }
    static func rules(account:AccountScope,in db:Database) throws -> [String:AgentClassifier.Classification] {
        guard let value=try DatabaseStore.applicationSetting(.authorRules(account),in:db),let data=Data(base64Encoded:value) else { return [:] }
        return try JSONDecoder().decode([String:AgentClassifier.Classification].self,from:data)
    }
    public func rules(account:AccountScope) throws -> [String:AgentClassifier.Classification] {
        try database.database.read { try Self.rules(account:account,in:$0) }
    }
    public enum Failure:Error { case invalidRule }
    public func save(_ rules:[String:AgentClassifier.Classification],account:AccountScope) throws {
        guard rules.count <= 200 else { throw Failure.invalidRule }
        var normalized:[String:AgentClassifier.Classification]=[:]
        for (login,value) in rules {
            let key=login.lowercased()
            guard !key.isEmpty,key.count <= 100,key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_[].".contains($0)) }),normalized[key] == nil else { throw Failure.invalidRule }
            normalized[key]=value
        }
        let data=try JSONEncoder().encode(normalized).base64EncodedString()
        try database.database.write { db in
            try db.execute(sql:"INSERT INTO applicationSettings VALUES (?,?) ON CONFLICT(name) DO UPDATE SET value=excluded.value",arguments:[SettingsKey.authorRules(account).rawValue,data])
            let rows=try Data.fetchAll(db,sql:"SELECT json FROM pullRequests WHERE host=? AND accountID=?",arguments:[account.host,account.accountID])
            for value in rows {
                let pr=try Self.applyingRules(to:JSONDecoder().decode(PullRequest.self,from:value),in:db)
                try db.execute(sql:"UPDATE pullRequests SET json=? WHERE host=? AND accountID=? AND repositoryID=? AND objectID=?",arguments:[JSONEncoder().encode(pr),pr.key.host,pr.key.accountID,pr.key.repositoryID,pr.key.objectID])
            }
        }
    }
    /// Called inside every normalized PR write transaction. A late fetch cannot restore stale overrides.
    static func applyingRules(to pr:PullRequest,in db:Database) throws -> PullRequest {
        guard var m=pr.metadata else { return pr }
        m.authorClassification=AgentClassifier.classify(login:m.authorLogin,actorType:m.actorType,manual:try rules(account:pr.key.account,in:db),branch:m.headBranch,labels:m.labels).rawValue
        return .init(key:pr.key,headRevision:pr.headRevision,title:pr.title,state:pr.state,isDraft:pr.isDraft,metadata:m)
    }
}
