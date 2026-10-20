import Foundation
import GRDB

public struct ReviewDraftComment:Codable,Sendable,Equatable,Identifiable {
    public private(set) var id:UUID
    public var body:String
    public let revision:PRWriteRevision?
    public var originalRevisions:[PRWriteRevision]? = []
    public let contentAnchor:ReviewAnchor?
    public let location:PRProviderCommentLocation?
    public let providerPath:String
    public let originalPatch:String?
    public var originalAnchors:[ReviewAnchor] = []
    public var originalPatches:[String] = []
    public var postedCommentID:String?
    public var postedBody:String?
    public var hasUnsentEdit:Bool { postedCommentID != nil && postedBody != body }
    public init(body:String,anchor:ReviewAnchor,document:DiffDocument,revision:PRWriteRevision) throws {
        guard revision.head == document.headSHA,revision.origin == document.baseSHA,let location=document.providerCommentLocation(for:anchor) else { throw PRWriteFailure.invalidAnchor }
        self.revision=revision;id=UUID();self.body=body;contentAnchor=anchor;self.location=location;providerPath=location.path
        originalPatch=document.files.first { $0.path == location.path }?.patch
    }
    public func withBody(_ body:String) -> Self { var value=self;value.id=UUID();value.body=body;return value }
    /// Called only by an explicit native relocation command. Preserve original identities and
    /// displayed patches; provider commit fields never replace the original merge base.
    public func relocated(to selection:Self) -> Self {
        var value=selection.withBody(body)
        value.originalRevisions=(originalRevisions ?? [])+(revision.map { [$0] } ?? [])
        value.originalAnchors=originalAnchors+(contentAnchor.map { [$0] } ?? [])
        value.originalPatches=originalPatches+(originalPatch.map { [$0] } ?? [])
        return value
    }
    public init(fileBody:String,path:String,document:DiffDocument,revision:PRWriteRevision) throws {
        guard revision.head == document.headSHA,revision.origin == document.baseSHA,document.comparison == .pullRequest,document.files.contains(where:{ $0.path == path }) else { throw PRWriteFailure.invalidAnchor }
        self.revision=revision;id=UUID();body=fileBody;contentAnchor=nil;location=nil;providerPath=path;originalPatch=document.files.first { $0.path == path }?.patch
    }
}
public struct ReviewDraftArchive:Codable,Sendable,Equatable {
    public let revision:PRWriteRevision
    public let summary:String
    public let comments:[ReviewDraftComment]
    public let texts:[String:String]
    public let pendingReviewID:String?
}
public struct ReviewDraft:Codable,Sendable,Equatable {
    public let key:ProviderKey
    public var revision:PRWriteRevision
    /// Optional for old persisted drafts; new reviews always receive a fresh local identity.
    public var reviewGeneration:UUID? = UUID()
    public var editVersion:Int = 0
    public var previousDrafts:[ReviewDraftArchive] = []
    public var priorRevisions:[PRWriteRevision] = []
    public var texts:[String:String] = [:]
    public var summary:String
    public var comments:[ReviewDraftComment]
    public var pendingReviewID:String?
    public init(key:ProviderKey,revision:PRWriteRevision,summary:String="",comments:[ReviewDraftComment]=[],pendingReviewID:String?=nil) { self.key=key;self.revision=revision;self.summary=summary;self.comments=comments;self.pendingReviewID=pendingReviewID }
}
public struct PRWriteOperation:Codable,Sendable,Equatable,Identifiable {
    public enum State:String,Codable,Sendable { case prepared,sending,confirmed,postedOutdated,uncertain,rejected }
    public let id:UUID
    public let command:PRWriteCommand
    public let createdAt:Date
    public var state:State
    public var draftGeneration:UUID?
    /// Migration may canonicalize provider identity while retaining a distinct legacy draft owner.
    public fileprivate(set) var draftOwnerKey:ProviderKey?
    public var beforeIDs:Set<String> = []
    public var providerIDs:[String]
    /// Raw provider response is evidence, never a reconstructed original diff identity.
    public var mergeConfirmedKeys:Set<ProviderKey>?
    public var mergeSelectedCommit:String?
    public var mergeRevisionDrift:[String]?
    /// HTTP status of the saved mutation receipt, needed to validate 409 option identity.
    public var mergeResponseStatus:Int?
    public var mergeOperationID:UUID?
    public var mergeOutcome:MergeOutcome?
    public var response:Data?
    public var message:String?
    public init(command:PRWriteCommand) { id=UUID();self.command=command;createdAt=Date();state = .prepared;providerIDs=[] }
}
/// Mutable SQLite drafts and a durable write ledger in the existing application database.
/// No account FK: loss/removal of a credential must preserve unsent text and original anchors.
public final class DraftReviewStore:Sendable {
    private let database:DatabaseStore
    public init(database:DatabaseStore) { self.database=database }
    private func identity(_ key:ProviderKey) throws -> String { let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys];return try encoder.encode(key).base64EncodedString() }
    public func save(_ draft:ReviewDraft,expectedVersion:Int?=nil) throws {
        let key=try identity(draft.key)
        try database.database.write { db in
            var value=draft
            if let json=try Data.fetchOne(db,sql:"SELECT json FROM reviewDrafts WHERE identity=?",arguments:[key]) {
                let saved=try JSONDecoder().decode(ReviewDraft.self,from:json)
                // Server receipt adoption must survive an autosave captured before that receipt.
                if draft.revision == saved.revision {
                    value.pendingReviewID=value.pendingReviewID ?? saved.pendingReviewID
                    for index in value.comments.indices {
                        if let prior=saved.comments.first(where:{ $0.id == value.comments[index].id }),prior.postedCommentID != nil {
                            value.comments[index].postedCommentID=prior.postedCommentID;value.comments[index].postedBody=prior.postedBody
                        }
                    }
                }
                // An identical retry is harmless; equal-base editors with different local
                // fields must conflict. Provider receipt merging is not a user-edit merge.
                if value == saved { return }
                let expected=expectedVersion ?? draft.editVersion-1
                guard saved.editVersion == expected,draft.editVersion == expected+1 else { throw PRWriteFailure.draftChanged }
            }
            let data=try JSONEncoder().encode(value)
            guard data.count <= 12_000_000 else { throw PRDetailFailure.oversized }
            try db.execute(sql:"INSERT INTO reviewDrafts VALUES (?,?,?,?) ON CONFLICT(identity) DO UPDATE SET json=excluded.json",arguments:[key,draft.key.host,draft.key.accountID,data])
        }
    }
    /// Explicit local start-next command archives all original text/anchors. It never hides an
    /// unresolved provider write; provider pending review admission still runs before POST.
    public func beginReview(_ key:ProviderKey,revision:PRWriteRevision) throws -> ReviewDraft {
        let identity=try identity(key)
        return try database.database.write { db in
            let operations=try Data.fetchAll(db,sql:"SELECT json FROM reviewOperations WHERE identity=? OR \(Migrations.reviewOperationState) IN ('prepared','sending','uncertain')",arguments:[identity]).map { try JSONDecoder().decode(PRWriteOperation.self,from:$0) }.filter { $0.command.reservedKeys.contains(key) }
            guard !operations.contains(where:{ [.prepared,.sending,.uncertain].contains($0.state) }) else { throw PRWriteFailure.operationInProgress }
            for receipt in operations { try adopt(receipt,in:db) }
            var next=ReviewDraft(key:key,revision:revision)
            if let json=try Data.fetchOne(db,sql:"SELECT json FROM reviewDrafts WHERE identity=?",arguments:[identity]) {
                let old=try JSONDecoder().decode(ReviewDraft.self,from:json)
                next.editVersion=old.editVersion+1;next.previousDrafts=old.previousDrafts+[ReviewDraftArchive(revision:old.revision,summary:old.summary,comments:old.comments,texts:old.texts,pendingReviewID:old.pendingReviewID)]
            }
            let data=try JSONEncoder().encode(next);guard data.count <= 12_000_000 else { throw PRDetailFailure.oversized }
            try db.execute(sql:"INSERT INTO reviewDrafts VALUES (?,?,?,?) ON CONFLICT(identity) DO UPDATE SET json=excluded.json",arguments:[identity,key.host,key.accountID,data]);return next
        }
    }
    public func load(_ key:ProviderKey) throws -> ReviewDraft? {
        try recoverReceipts(key)
        let identity=try identity(key)
        return try database.database.read { try Data.fetchOne($0,sql:"SELECT json FROM reviewDrafts WHERE identity=?",arguments:[identity]).map { try JSONDecoder().decode(ReviewDraft.self,from:$0) } }
    }
    public func all(account:AccountScope) throws -> [ReviewDraft] {
        try database.database.read { try Data.fetchAll($0,sql:"SELECT json FROM reviewDrafts WHERE host=? AND accountID=? ORDER BY identity",arguments:[account.host,account.accountID]).map { try JSONDecoder().decode(ReviewDraft.self,from:$0) } }
    }
    public func prepare(_ operation:PRWriteOperation) throws {
        let identity=try identity(operation.command.key)
        try database.database.write { db in
            let active=try Data.fetchAll(db,sql:"SELECT json FROM reviewOperations WHERE identity=? OR \(Migrations.reviewOperationState) IN ('prepared','sending','uncertain') ORDER BY rowid",arguments:[identity]).map { try JSONDecoder().decode(PRWriteOperation.self,from:$0) }.filter { !$0.command.reservedKeys.isDisjoint(with:operation.command.reservedKeys) }
            for receipt in active { try adopt(receipt,in:db) }
            guard !active.contains(where:{ [.prepared,.sending,.uncertain].contains($0.state) }) else { throw PRWriteFailure.operationInProgress }
            if case .thread(let captured,_) = operation.command.intent,
               let json=try Data.fetchOne(db,sql:"SELECT json FROM reviewDrafts WHERE identity=?",arguments:[identity]),
               try JSONDecoder().decode(ReviewDraft.self,from:json).comments.contains(where:{ $0.id == captured.id && $0.postedCommentID != nil }) {
                throw PRWriteFailure.draftChanged
            }
            var captured=operation
            if let json=try Data.fetchOne(db,sql:"SELECT json FROM reviewDrafts WHERE identity=?",arguments:[identity]) { captured.draftGeneration=try JSONDecoder().decode(ReviewDraft.self,from:json).reviewGeneration }
            try db.execute(sql:"INSERT INTO reviewOperations VALUES (?,?,?)",arguments:[captured.id.uuidString,identity,try JSONEncoder().encode(captured)])
        }
    }
    public func rejectUnsent(_ id:UUID) throws {
        try database.database.write { db in
            guard let json=try Data.fetchOne(db,sql:"SELECT json FROM reviewOperations WHERE id=?",arguments:[id.uuidString]) else { throw PRWriteFailure.unavailable }
            var operation=try JSONDecoder().decode(PRWriteOperation.self,from:json)
            guard operation.state == .prepared else { throw PRWriteFailure.uncertain }
            operation.state = .rejected;operation.message="Explicitly released before any dispatch. Draft retained."
            try db.execute(sql:"UPDATE reviewOperations SET json=? WHERE id=?",arguments:[try JSONEncoder().encode(operation),id.uuidString])
        }
    }
    public func update(_ operation:PRWriteOperation,expectedState:PRWriteOperation.State?=nil) throws {
        try database.database.write { db in
            _ = try update(operation,expectedState:expectedState,in:db)
        }
    }
    @discardableResult private func update(_ operation:PRWriteOperation,expectedState:PRWriteOperation.State?,in db:Database) throws -> PRWriteOperation {
        guard let json=try Data.fetchOne(db,sql:"SELECT json FROM reviewOperations WHERE id=?",arguments:[operation.id.uuidString]) else { throw StorageError.draftIdentityConflict }
        let old=try JSONDecoder().decode(PRWriteOperation.self,from:json)
        guard old.command == operation.command else { throw StorageError.draftIdentityConflict }
        if old == operation { return old }
        guard expectedState == nil || old.state == expectedState else { throw PRWriteFailure.operationInProgress }
        let allowed:Bool
        switch old.state {
        case .prepared:allowed=[.prepared,.sending,.rejected].contains(operation.state)
        case .sending,.uncertain:allowed=[.uncertain,.confirmed,.postedOutdated,.rejected].contains(operation.state)
        case .confirmed,.postedOutdated,.rejected:allowed=false
        }
        guard allowed else { throw PRWriteFailure.operationInProgress }
        var value=operation;value.draftGeneration=old.draftGeneration;value.draftOwnerKey=old.draftOwnerKey
        try db.execute(sql:"UPDATE reviewOperations SET json=? WHERE id=?",arguments:[try JSONEncoder().encode(value),value.id.uuidString]);return value
    }
    /// One owner transaction commits terminal state, adopted draft receipt and normalized truth.
    public func commitReceipt(_ operation:PRWriteOperation,expectedState:PRWriteOperation.State,normalized:PullRequest?) throws {
        try commitReceipt(operation,expectedState:expectedState,confirmations:normalized.map { [$0] } ?? [])
    }
    public func commitReceipt(_ operation:PRWriteOperation,expectedState:PRWriteOperation.State,confirmations:[PullRequest]) throws {
        try database.database.write { db in
            if let json=try Data.fetchOne(db,sql:"SELECT json FROM reviewOperations WHERE id=?",arguments:[operation.id.uuidString]),
               try JSONDecoder().decode(PRWriteOperation.self,from:json) == operation {
                try adopt(operation,in:db);return
            }
            let receipt=try update(operation,expectedState:expectedState,in:db)
            try adopt(receipt,in:db)
            for normalized in confirmations { try DatabaseStore.confirmWrite(normalized,in:db) }
        }
    }
    /// Mandatory idempotent legacy/crash recovery, also called before reserving a later command.
    public func recoverReceipts(_ key:ProviderKey) throws {
        let identity=try identity(key)
        try database.database.write { db in
            for json in try Data.fetchAll(db,sql:"SELECT json FROM reviewOperations WHERE identity=? ORDER BY rowid",arguments:[identity]) { try adopt(JSONDecoder().decode(PRWriteOperation.self,from:json),in:db) }
        }
    }
    /// Attach a uniquely reconciled provider result to its original local draft. This is also
    /// applied after relaunch/response loss so continuing a pending draft cannot repost a thread.
    public func reconcileDraft(_ operation:PRWriteOperation) throws {
        try database.database.write { try adopt(operation,in:$0) }
    }
    private func adopt(_ operation:PRWriteOperation,in db:Database) throws {
        guard [.confirmed,.postedOutdated].contains(operation.state),let providerID=operation.providerIDs.first else { return }
        let key=try identity(operation.draftOwnerKey ?? operation.command.key)
            guard let json=try Data.fetchOne(db,sql:"SELECT json FROM reviewDrafts WHERE identity=?",arguments:[key]) else { return }
            var draft=try JSONDecoder().decode(ReviewDraft.self,from:json)
            guard draft.revision == operation.command.revision,draft.reviewGeneration == operation.draftGeneration else { return }
            switch operation.command.intent {
            case .createPending:draft.pendingReviewID=providerID
            case .thread(let sent,_):
                if let index=draft.comments.firstIndex(where:{ $0.id == sent.id }) { draft.comments[index].postedCommentID=providerID;draft.comments[index].postedBody=sent.body }
            case .editComment(let id,.review,let body):
                if let index=draft.comments.firstIndex(where:{ $0.postedCommentID == id }) { draft.comments[index].postedBody=body }
            default:return
            }
            try db.execute(sql:"UPDATE reviewDrafts SET json=? WHERE identity=?",arguments:[try JSONEncoder().encode(draft),key])
    }
    /// Retention for terminal history (confirmed, posted-outdated, rejected) created before `cutoff`. Each
    /// receipt is adopted into its draft first, so a pruned row can never make sent text look unsent.
    /// Prepared, sending and uncertain operations are never pruned.
    func pruneTerminalOperations(createdBefore cutoff:Date) throws -> Int {
        try database.database.write { db in
            var removed=0
            for row in try Row.fetchAll(db,sql:"SELECT id,json FROM reviewOperations WHERE \(Migrations.reviewOperationState) IN ('confirmed','postedOutdated','rejected') AND \(Migrations.extract("$.createdAt")) < ?",arguments:[cutoff.timeIntervalSinceReferenceDate]) {
                let operation:PRWriteOperation
                do { operation=try JSONDecoder().decode(PRWriteOperation.self,from:row["json"] as Data) } catch {
                    Log.writes.error("A terminal write operation did not decode and is kept: \(Log.kind(error), privacy: .public)");continue
                }
                guard [.confirmed,.postedOutdated,.rejected].contains(operation.state),operation.createdAt < cutoff else { continue }
                try adopt(operation,in:db)
                try db.execute(sql:"DELETE FROM reviewOperations WHERE id=?",arguments:[row["id"] as String]);removed += 1
            }
            return removed
        }
    }
    public func operation(_ id:UUID) throws -> PRWriteOperation? { try database.database.read { try Data.fetchOne($0,sql:"SELECT json FROM reviewOperations WHERE id=?",arguments:[id.uuidString]).map { try JSONDecoder().decode(PRWriteOperation.self,from:$0) } } }
    public func operations(_ key:ProviderKey) throws -> [PRWriteOperation] {
        let identity=try identity(key)
        return try database.database.read { try Data.fetchAll($0,sql:"SELECT json FROM reviewOperations WHERE identity=? OR \(Migrations.reviewOperationState) IN ('prepared','sending','uncertain') ORDER BY rowid DESC",arguments:[identity]).map { try JSONDecoder().decode(PRWriteOperation.self,from:$0) }.filter { $0.command.reservedKeys.contains(key) } }
    }
}
