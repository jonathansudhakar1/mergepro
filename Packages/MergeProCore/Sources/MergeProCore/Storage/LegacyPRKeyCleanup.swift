import Foundation
import GRDB

/// PRs created or linked from the app were once saved under the raw GitHub node ID, while the inventory stores
/// `pull-request:<node ID>`, so both rows appeared on the board. Run once (migration `v9-legacy-pr-key-cleanup`).
///
/// A raw row is removed ONLY when the canonical row exists for the same account and repository; a raw row without
/// one stays (it is the only local copy). Local state keyed to a removed row moves to the canonical key so it stays
/// reachable from the row the board shows: pins, revision-bound reading progress, review drafts, inline drafts and
/// the write ledger (an in-flight write must keep reserving its PR, or a second write could start beside it).
///
/// When the canonical key already has its own state of that kind, the canonical copy wins and the raw copy is left
/// exactly as it is. Merging two drafts or two ledgers is not safe: they can belong to different revisions, review
/// generations and provider receipts, so a merge could resurrect superseded text or attach one review's posted
/// comments to the other. Drafts and the ledger are private local history, so the raw copy is retained, never
/// deleted. Corrupt or undecodable local state is likewise left in place.
enum LegacyPRKeyCleanup {
    static let prefix="pull-request:"
    /// SQL predicate: `table` names a raw (unprefixed) PR key whose canonical PR row exists.
    private static func hasCanonicalRow(_ table:String) -> String {
        """
        substr(\(table).objectID,1,\(prefix.count)) <> '\(prefix)' AND EXISTS (SELECT 1 FROM pullRequests canonical
            WHERE canonical.host=\(table).host AND canonical.accountID=\(table).accountID
            AND canonical.repositoryID=\(table).repositoryID AND canonical.objectID='\(prefix)'||\(table).objectID)
        """
    }
    /// Returns the number of duplicate PR rows removed.
    @discardableResult static func run(_ db:Database) throws -> Int {
        try db.execute(sql:"UPDATE OR IGNORE pins SET objectID='\(prefix)'||objectID WHERE "+hasCanonicalRow("pins"))
        // Left only when the canonical key was already pinned.
        try db.execute(sql:"DELETE FROM pins WHERE "+hasCanonicalRow("pins"))
        try moveReadingProgress(db)
        try moveReviewDrafts(db)
        try moveInlineDrafts(db)
        try moveLedger(db)
        try db.execute(sql:"DELETE FROM pullRequests WHERE "+hasCanonicalRow("pullRequests"))
        return db.changesCount
    }
    /// The canonical key for a raw PR key whose canonical row exists, else nil.
    private static func canonical(_ key:ProviderKey,in db:Database) throws -> ProviderKey? {
        guard !key.objectID.hasPrefix(prefix) else { return nil }
        let canonical=ProviderKey(host:key.host,accountID:key.accountID,repositoryID:key.repositoryID,objectID:prefix+key.objectID)
        return try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM pullRequests WHERE host=? AND accountID=? AND repositoryID=? AND objectID=?)",arguments:[canonical.host,canonical.accountID,canonical.repositoryID,canonical.objectID]) == true ? canonical : nil
    }
    /// `DraftReviewStore` names review drafts and ledger rows, and `PRDetailStore` reading progress, by
    /// base64 of the sorted-keys JSON of the PR key.
    private static func identity(_ key:ProviderKey) throws -> String {
        let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(key).base64EncodedString()
    }
    private static func key(identity:String) -> ProviderKey? {
        Data(base64Encoded:identity).flatMap { try? JSONDecoder().decode(ProviderKey.self,from:$0) }
    }
    /// The stored JSON with every encoded `raw` key replaced by `canonical`, preserving all other (including
    /// future) fields. Nil when nothing changed or the result no longer decodes as `T`.
    private static func rekeyed<T:Decodable>(_ json:Data,as type:T.Type,from raw:ProviderKey,to canonical:ProviderKey) -> Data? {
        guard let object=try? JSONSerialization.jsonObject(with:json) else { return nil }
        var changed=false
        func walk(_ value:Any) -> Any {
            if let dictionary=value as? [String:Any] {
                if dictionary.count == 4,dictionary["host"] as? String == raw.host,dictionary["accountID"] as? String == raw.accountID,
                   dictionary["repositoryID"] as? String == raw.repositoryID,dictionary["objectID"] as? String == raw.objectID {
                    changed=true;var copy=dictionary;copy["objectID"]=canonical.objectID;return copy
                }
                return dictionary.mapValues(walk)
            }
            if let array=value as? [Any] { return array.map(walk) }
            return value
        }
        let result=walk(object)
        guard changed,let data=try? JSONSerialization.data(withJSONObject:result,options:[.withoutEscapingSlashes]),
              (try? JSONDecoder().decode(T.self,from:data)) != nil else { return nil }
        return data
    }
    /// `PRDetailStore` names progress `pr-detail-viewed:` + the key identity.
    private static func moveReadingProgress(_ db:Database) throws {
        let settingPrefix="pr-detail-viewed:"
        for row in try Row.fetchAll(db,sql:"SELECT name,value FROM applicationSettings WHERE substr(name,1,?)=?",arguments:[settingPrefix.count,settingPrefix]) {
            let name:String=row["name"],value:String=row["value"]
            guard let raw=key(identity:String(name.dropFirst(settingPrefix.count))),let canonical=try canonical(raw,in:db) else { continue }
            let target=settingPrefix+(try identity(canonical))
            // Existing canonical progress wins; the raw copy is dropped either way (it is regenerable view state).
            try db.execute(sql:"INSERT OR IGNORE INTO applicationSettings (name,value) VALUES (?,?)",arguments:[target,value])
            try db.execute(sql:"DELETE FROM applicationSettings WHERE name=?",arguments:[name])
        }
    }
    private static func moveReviewDrafts(_ db:Database) throws {
        for row in try Row.fetchAll(db,sql:"SELECT identity,json FROM reviewDrafts") {
            let identity:String=row["identity"]
            guard let raw=key(identity:identity),let canonical=try canonical(raw,in:db),let json=row["json"] as Data? else { continue }
            let target=try Self.identity(canonical)
            guard try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM reviewDrafts WHERE identity=?)",arguments:[target]) == false,
                  let moved=rekeyed(json,as:ReviewDraft.self,from:raw,to:canonical) else { continue }
            try db.execute(sql:"UPDATE reviewDrafts SET identity=?,json=? WHERE identity=?",arguments:[target,moved,identity])
        }
    }
    /// Inline drafts carry their key only in JSON; every draft of a raw key moves unless the canonical key has one.
    private static func moveInlineDrafts(_ db:Database) throws {
        let decoder=JSONDecoder()
        let drafts=try Row.fetchAll(db,sql:"SELECT id,json FROM drafts").compactMap { row -> (id:String,json:Data,key:ProviderKey)? in
            guard let json=row["json"] as Data?,let draft=try? decoder.decode(Draft.self,from:json) else { return nil }
            return (row["id"],json,draft.key)
        }
        let keys=Set(drafts.map(\.key))
        for draft in drafts {
            guard let canonical=try canonical(draft.key,in:db),!keys.contains(canonical),
                  let moved=rekeyed(draft.json,as:Draft.self,from:draft.key,to:canonical) else { continue }
            try db.execute(sql:"UPDATE drafts SET json=? WHERE id=?",arguments:[moved,draft.id])
        }
    }
    /// Ledger rows move per key, all or nothing, so one PR's operation history is never split across keys.
    private static func moveLedger(_ db:Database) throws {
        let identities=try String.fetchAll(db,sql:"SELECT DISTINCT identity FROM reviewOperations")
        let present=Set(identities)
        for identity in identities {
            guard let raw=key(identity:identity),let canonical=try canonical(raw,in:db) else { continue }
            let target=try Self.identity(canonical)
            guard !present.contains(target) else { continue }
            let rows=try Row.fetchAll(db,sql:"SELECT id,json FROM reviewOperations WHERE identity=?",arguments:[identity])
            let moved=rows.compactMap { row -> (id:String,json:Data)? in
                guard let json=row["json"] as Data?,let value=rekeyed(json,as:PRWriteOperation.self,from:raw,to:canonical) else { return nil }
                return (row["id"],value)
            }
            guard moved.count == rows.count else { continue }
            for row in moved { try db.execute(sql:"UPDATE reviewOperations SET identity=?,json=? WHERE id=?",arguments:[target,row.json,row.id]) }
        }
    }

    /// Forward repair for v9 installations where both ledger identities already existed. Keep
    /// their distinct draft owners and generations, but unresolved commands must reserve the
    /// canonical provider key even after v9 removed the raw PR row. Also repair affected stack keys
    /// in commands owned by another PR. Completed history and undecodable records stay untouched.
    static func repairLedgerReservations(_ db:Database) throws {
        let decoder=JSONDecoder()
        for row in try Row.fetchAll(db,sql:"SELECT id,json FROM reviewOperations") {
            guard let json=row["json"] as Data?,let operation=try? decoder.decode(PRWriteOperation.self,from:json),
                  [.prepared,.sending,.uncertain].contains(operation.state) else { continue }
            var repaired=json
            for raw in operation.command.reservedKeys {
                guard let target=try canonical(raw,in:db),
                      let value=rekeyed(repaired,as:PRWriteOperation.self,from:raw,to:target) else { continue }
                repaired=value
            }
            if repaired != json {
                let command=try decoder.decode(PRWriteOperation.self,from:repaired).command
                // The ledger follows the provider key so terminal history and crash recovery remain
                // reachable. A retained raw draft stays the receipt owner, including legacy nil generations.
                if command.key != operation.command.key {
                    let original=operation.draftOwnerKey ?? operation.command.key
                    if try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM reviewDrafts WHERE identity=?)",arguments:[try identity(original)]) == true {
                        guard var object=try JSONSerialization.jsonObject(with:repaired) as? [String:Any] else { throw StorageError.draftIdentityConflict }
                        object["draftOwnerKey"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(original))
                        repaired=try JSONSerialization.data(withJSONObject:object,options:[.withoutEscapingSlashes])
                    }
                }
                try db.execute(sql:"UPDATE reviewOperations SET identity=?,json=? WHERE id=?",arguments:[try identity(command.key),repaired,row["id"] as String])
            }
        }
    }
}
