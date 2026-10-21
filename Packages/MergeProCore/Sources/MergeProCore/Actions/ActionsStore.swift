import Foundation
import GRDB

public enum ActionsWriteState:String,Codable,Sendable { case prepared,sending,accepted,confirmed,rejected,uncertain }
public enum ActionsIntent:Equatable,Codable,Sendable {
    case dispatch(workflow:ActionsWorkflow,schema:WorkflowInputSchema,inputs:[String:WorkflowInputValue],productionConfirmed:Bool)
    case rerunAll(runID:Int64,attempt:Int)
    case rerunFailed(runID:Int64,attempt:Int)
    case cancel(runID:Int64,attempt:Int)
    case approveFork(runID:Int64,attempt:Int)
    case deployment(runID:Int64,attempt:Int,environmentIDs:[Int64],approve:Bool,comment:String,productionConfirmed:Bool=false)
    public var runIdentity:(Int64,Int)? {
        switch self { case .dispatch:return nil
        case .rerunAll(let id,let attempt),.rerunFailed(let id,let attempt),.cancel(let id,let attempt),.approveFork(let id,let attempt),.deployment(let id,let attempt,_,_,_,_):return (id,attempt) }
    }
    func sanitized() -> Self {
        guard case .dispatch(let workflow,let schema,let inputs,let confirmed)=self else { return self }
        let allowed=Set(schema.inputs.filter { !$0.secret }.map(\.id))
        return .dispatch(workflow:workflow,schema:schema.redactingSecrets(),inputs:inputs.filter { allowed.contains($0.key) },productionConfirmed:confirmed)
    }
    var lockIdentity:String { switch self {
        case .dispatch(let workflow,let schema,_,_):"dispatch:\(workflow.id):\(schema.ref)"
        case .rerunAll(let id,_),.rerunFailed(let id,_),.cancel(let id,_),.approveFork(let id,_),.deployment(let id,_,_,_,_,_):"run:\(id)"
    } }
}
public struct ActionsWriteOperation: Codable, Equatable, Identifiable, Sendable {
    public let id:UUID
    public let repository:Repository
    public let intent:ActionsIntent
    public let createdAt:Date
    public var state:ActionsWriteState
    public var message:String?
    public var beforeRunIDs:[Int64]
    public init(repository:Repository,intent:ActionsIntent) { id=UUID();self.repository=repository;self.intent=intent.sanitized();createdAt=Date();state = .prepared;message=nil;beforeRunIDs=[] }
}
public struct ActionsStore:Sendable {
    let database:DatabaseStore
    /// The schema is created by migration v7; constructing a store is free and never writes.
    public init(database:DatabaseStore) throws { self.database=database }
    public func catalog(_ repository:RepositoryKey) throws -> ActionsCatalog? {
        let cached=try storedCatalog(repository)
        // Only this repository's polled runs; decoding the whole account's runs per repository was quadratic.
        let snapshots=try PollCycleStore(database:database).featureSnapshots(account:repository.account,feature:"github-actions",repositories:[repository])
        let polled=snapshots.compactMap { try? JSONDecoder().decode(WorkflowRun.self,from:$0.payload) }
        guard !polled.isEmpty else { return cached }
        let metadata=try database.repository(repository)
        guard let repo=cached?.repository ?? metadata else { return cached }
        let merged=Dictionary((cached?.runs ?? []).map { ($0.key,$0) },uniquingKeysWith:{ _,last in last }).merging(Dictionary(polled.map { ($0.key,$0) },uniquingKeysWith:{ _,last in last })) { before,after in before.updatedAt>after.updatedAt ? before:after }
        return .init(repository:repo,runs:merged.values.sorted { $0.createdAt>$1.createdAt },workflows:cached?.workflows ?? [],deployments:cached?.deployments ?? [],environments:cached?.environments ?? [],unavailableSections:cached?.unavailableSections ?? [:])
    }
    private func storedCatalog(_ repository:RepositoryKey) throws -> ActionsCatalog? {
        try database.database.read { db in try Data.fetchOne(db,sql:"SELECT json FROM actions_catalog WHERE host=? AND accountID=? AND repositoryID=?",arguments:[repository.account.host,repository.account.accountID,repository.repositoryID]).map { try JSONDecoder().decode(ActionsCatalog.self,from:$0) } }
    }
    public func save(_ catalog:ActionsCatalog) throws {
        let key=catalog.repository.key
        try database.database.write { try $0.execute(sql:"INSERT INTO actions_catalog VALUES(?,?,?,?) ON CONFLICT(host,accountID,repositoryID) DO UPDATE SET json=excluded.json",arguments:[key.account.host,key.account.accountID,key.repositoryID,try JSONEncoder.stable.encode(catalog)]) }
    }
    public func presets(_ repository:RepositoryKey?=nil) throws -> [WorkflowPreset] {
        try database.database.read { db in
            let blobs:[Data]
            if let repository { blobs=try Data.fetchAll(db,sql:"SELECT json FROM actions_presets WHERE host=? AND accountID=? AND repositoryID=?",arguments:[repository.account.host,repository.account.accountID,repository.repositoryID]) }
            else { blobs=try Data.fetchAll(db,sql:"SELECT json FROM actions_presets") }
            return try blobs.map { try JSONDecoder().decode(WorkflowPreset.self,from:$0) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
    public func save(_ preset:WorkflowPreset) throws {
        let key=preset.repository
        try database.database.write { try $0.execute(sql:"INSERT INTO actions_presets VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json",arguments:[preset.id.uuidString,key.account.host,key.account.accountID,key.repositoryID,try JSONEncoder.stable.encode(preset)]) }
    }
    public func removePreset(_ id:UUID) throws { try database.database.write { try $0.execute(sql:"DELETE FROM actions_presets WHERE id=?",arguments:[id.uuidString]) } }
    public func prepare(_ operation:ActionsWriteOperation) throws {
        let key=operation.repository.key;let lock=[key.account.host,key.account.accountID,key.repositoryID,operation.intent.lockIdentity].joined(separator:"|")
        try database.database.write { db in
            guard try !Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM actions_operations WHERE lockKey=?)",arguments:[lock])! else { throw ActionsFailure.operationInProgress }
            try db.execute(sql:"INSERT INTO actions_operations VALUES(?,?,?,?,?,?,?)",arguments:[operation.id.uuidString,key.account.host,key.account.accountID,key.repositoryID,operation.state.rawValue,try JSONEncoder.stable.encode(operation),lock])
        }
    }
    public func update(_ operation:ActionsWriteOperation,from expected:ActionsWriteState) throws {
        try database.database.write { db in
            let acceptedCreation:Bool
            if case .dispatch=operation.intent { acceptedCreation=operation.state == .accepted } else { acceptedCreation=false }
            let unlock=[ActionsWriteState.rejected,.confirmed].contains(operation.state) || acceptedCreation
            try db.execute(sql:"UPDATE actions_operations SET state=?,json=?,lockKey=CASE WHEN ? THEN NULL ELSE lockKey END WHERE id=? AND state=?",arguments:[operation.state.rawValue,try JSONEncoder.stable.encode(operation),unlock,operation.id.uuidString,expected.rawValue])
            guard db.changesCount==1 else { throw ActionsFailure.operationInProgress }
        }
    }
    public func operation(_ id:UUID) throws -> ActionsWriteOperation? { try database.database.read { db in try Data.fetchOne(db,sql:"SELECT json FROM actions_operations WHERE id=?",arguments:[id.uuidString]).map { try JSONDecoder().decode(ActionsWriteOperation.self,from:$0) } } }
    public func operations(_ repository:RepositoryKey?=nil) throws -> [ActionsWriteOperation] {
        try database.database.read { db in
            let values:[Data]
            if let repository { values=try Data.fetchAll(db,sql:"SELECT json FROM actions_operations WHERE host=? AND accountID=? AND repositoryID=?",arguments:[repository.account.host,repository.account.accountID,repository.repositoryID]) } else { values=try Data.fetchAll(db,sql:"SELECT json FROM actions_operations") }
            return try values.map { try JSONDecoder().decode(ActionsWriteOperation.self,from:$0) }.sorted { $0.createdAt>$1.createdAt }
        }
    }
}
