import CryptoKit
import Foundation
import GRDB

/// Local review progress is revision-bound. Provider viewed-file synchronization is separate.
/// A viewed mark is keyed by path and the file's change content: after a push, a mark carries to the
/// new head only when that file's diff is provably unchanged; unknown content never carries.
public struct PRDetailState: Codable, Sendable {
    public private(set) var headSHA: String
    public private(set) var viewed: Set<String> = []
    /// Content identity (`DiffFile.viewedContentIdentity`) per viewed path at `headSHA`; absent is unknown.
    public private(set) var viewedContent: [String:String] = [:]
    /// Marks from an earlier head, by path, waiting for this head's file inventory to compare content.
    public private(set) var carriedViewed: [String:String] = [:]
    /// Legacy field; reviewed heads now live in their own record (`PRDetailStore.recordReview`).
    public var lastReviewedSHA: String?
    public init(headSHA:String) { self.headSHA=headSHA }
    private enum CodingKeys:String,CodingKey { case headSHA,viewed,viewedContent,carriedViewed,lastReviewedSHA }
    public init(from decoder:any Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        headSHA=try c.decode(String.self,forKey:.headSHA)
        viewed=try c.decodeIfPresent(Set<String>.self,forKey:.viewed) ?? []
        viewedContent=try c.decodeIfPresent([String:String].self,forKey:.viewedContent) ?? [:]
        carriedViewed=try c.decodeIfPresent([String:String].self,forKey:.carriedViewed) ?? [:]
        lastReviewedSHA=try c.decodeIfPresent(String.self,forKey:.lastReviewedSHA)
    }
    /// A new head clears the visible marks; marks with known content wait in `carriedViewed` for `reconcile`.
    public mutating func acceptRevision(_ sha:String) {
        guard headSHA != sha else { return }
        for path in viewed { if let content=viewedContent[path] { carriedViewed[path]=content } }
        headSHA=sha;viewed=[];viewedContent=[:]
    }
    /// Compares carried marks with the canonical PR diff for `headSHA`: identical content keeps its mark,
    /// changed or unknown content drops it. Files not loaded yet keep waiting until a complete inventory
    /// shows they left the pull request. Same-head marks without content record it. Returns whether anything changed.
    @discardableResult public mutating func reconcile(_ document:DiffDocument) -> Bool {
        guard document.comparison == .pullRequest,document.headSHA == headSHA else { return false }
        var changed=false
        for file in document.files {
            let content=file.viewedContentIdentity
            if viewed.contains(file.path),viewedContent[file.path] == nil,let content { viewedContent[file.path]=content;changed=true }
            if let carried=carriedViewed.removeValue(forKey:file.path) {
                changed=true
                // Only the same identity proves the diff unchanged. A mark keyed by a head blob alone (stored
                // while blobs were preferred) no longer matches a file whose patch is readable: the base side
                // may have moved under the same head blob.
                if let content,carried == content { viewed.insert(file.path);viewedContent[file.path]=content }
            }
        }
        if document.missingFileCount == 0,!carriedViewed.isEmpty { carriedViewed=[:];changed=true }
        return changed
    }
    @discardableResult public mutating func markViewed(_ path:String,viewed:Bool,displayed:DiffDocument,canonical:DiffDocument) -> Bool {
        guard headSHA == canonical.headSHA,displayed.headSHA == canonical.headSHA,displayed.baseSHA == canonical.baseSHA else { return false }
        markViewed(path,viewed:viewed)
        if viewed,let content=canonical.files.first(where:{ $0.path == path })?.viewedContentIdentity { viewedContent[path]=content }
        return true
    }
    public mutating func markViewed(_ path:String,viewed:Bool) {
        carriedViewed[path]=nil
        if viewed { self.viewed.insert(path) } else { self.viewed.remove(path);viewedContent[path]=nil }
    }
}
extension DiffFile {
    /// What a reviewer saw for this file. With a usable patch: status, rename origin and the exact patch
    /// (`patchContentIdentity`), which covers both sides, so a base-only change (a merge from main that keeps
    /// the author's version) is new content. Without one (binary, oversized): the provider's head blob
    /// (`blobContentIdentity`). Nil when neither is known, so "unchanged" is never guessed.
    public var viewedContentIdentity:String? { patchContentIdentity ?? blobContentIdentity }
    /// Status, rename origin and the provider's head blob SHA (`blob:` prefixed); nil without a valid SHA.
    public var blobContentIdentity:String? {
        guard let blob=sha?.lowercased(),[40,64].contains(blob.count),blob.allSatisfy(\.isHexDigit),blob.contains(where:{ $0 != "0" }) else { return nil }
        return "blob:"+Self.digest([status.rawValue,previousPath ?? "",blob])
    }
    /// Status, rename origin and exact patch. Nil when the patch is unavailable or unparsable.
    public var patchContentIdentity:String? {
        guard let patch,patchState == .available else { return nil }
        return Self.digest([status.rawValue,previousPath ?? "",patch])
    }
    private static func digest(_ parts:[String]) -> String {
        var hash=SHA256()
        for part in parts { hash.update(data:Data(part.utf8));hash.update(data:Data([0])) }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
}
public enum InterdiffAvailability: Equatable, Sendable {
    case available(original:String,head:String), unavailable(original:String), neverReviewed
    public static func resolve(original:String?,head:String,retrievable:Bool) -> Self {
        guard let original else { return .neverReviewed };return retrievable ? .available(original:original,head:head) : .unavailable(original:original)
    }
}
/// The head a provider-confirmed review by one account covered, and when that was confirmed locally.
public struct PRReviewedHead: Codable, Equatable, Sendable {
    public let head:String
    public let at:Date
    public init(head:String,at:Date) { self.head=head;self.at=at }
}
/// "Changes since your review": the head the account's latest submitted review covered against the
/// current head. Provider history and local confirmations stay distinguishable through `source`.
public struct PRReReviewState: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case provider, local }
    public let reviewedHead:String
    public let currentHead:String
    public let source:Source
    /// Nil when the provider request list is unknown or incomplete.
    public let reRequested:Bool?
    public var hasNewCommits:Bool { reviewedHead != currentHead }
    /// Open the window on the interdiff only when your review was re-requested and commits landed since.
    public var opensOnInterdiff:Bool { reRequested == true && hasNewCommits }
    /// The latest review among the local record, provider-confirmed review writes in the ledger and the
    /// provider's own review list (the viewer's submitted, non-pending reviews). Nil when none is known.
    public static func resolve(currentHead:String,local:PRReviewedHead?,ledger:[PRWriteOperation],providerReviews:[PRReviewSummary]?,viewerRequested:Bool?) -> Self? {
        var candidates:[(head:String,at:Date,source:Source)]=[]
        if let local { candidates.append((local.head,local.at,.local)) }
        for operation in ledger where operation.state == .confirmed && operation.command.intent.decision != nil {
            candidates.append((operation.command.revision.head,operation.createdAt,.local))
        }
        for review in providerReviews ?? [] where review.viewerDidAuthor && ![.pending,.unknown].contains(review.state) {
            if let commit=review.commitOID,!commit.isEmpty { candidates.append((commit,review.submittedAt ?? .distantPast,.provider)) }
        }
        // Latest wins; on an exact tie the provider's own record is preferred.
        guard let latest=candidates.max(by:{ ($0.at,$0.source == .provider ? 1 : 0) < ($1.at,$1.source == .provider ? 1 : 0) }) else { return nil }
        return .init(reviewedHead:latest.head,currentHead:currentHead,source:latest.source,reRequested:viewerRequested)
    }
    /// Whether the action account's own login is among the requested reviewers. A missing login in an
    /// incomplete list is unknown, not "not requested".
    public static func viewerRequested(_ administration:PRReviewAdministration?) -> Bool? {
        guard let administration,!administration.viewerLogin.isEmpty else { return nil }
        if administration.requestedUsers.contains(where:{ $0.login.caseInsensitiveCompare(administration.viewerLogin) == .orderedSame }) { return true }
        return administration.requestsComplete ? false : nil
    }
}
public struct PRDetailStore: Sendable {
    private let database: DatabaseStore
    public init(database:DatabaseStore) { self.database=database }
    public func load(_ key:ProviderKey,headSHA:String) throws -> PRDetailState {
        guard let raw=try database.applicationSetting(.detailProgress(key)),let data=Data(base64Encoded:raw) else { return PRDetailState(headSHA:headSHA) }
        var state=try JSONDecoder().decode(PRDetailState.self,from:data);state.acceptRevision(headSHA);return state
    }
    public func save(_ state:PRDetailState,key:ProviderKey) throws { try database.setApplicationSetting(JSONEncoder().encode(state).base64EncodedString(),for:.detailProgress(key)) }
    /// Records the head a provider-confirmed review by `key`'s account covered. Call only after confirmation. Kept apart
    /// from reading progress so a window saving older progress never drops a newer review record.
    public func recordReview(_ key:ProviderKey,headSHA:String,at date:Date = Date()) throws {
        try database.setApplicationSetting(JSONEncoder().encode(PRReviewedHead(head:headSHA,at:date)).base64EncodedString(),for:.reviewedHead(key))
    }
    public func reviewedHead(_ key:ProviderKey) throws -> PRReviewedHead? {
        guard let raw=try database.applicationSetting(.reviewedHead(key)),let data=Data(base64Encoded:raw) else { return nil }
        return try JSONDecoder().decode(PRReviewedHead.self,from:data)
    }
    /// Local reading progress and reviewed heads name private repository paths and commits. App-wide
    /// settings otherwise survive account removal, so remove this account's records explicitly with the account.
    public func purge(account:AccountScope) throws {
        try database.database.write { db in
            for prefix in [SettingsKey.detailProgressPrefix,SettingsKey.reviewedHeadPrefix] {
                for name in try String.fetchAll(db,sql:"SELECT name FROM applicationSettings WHERE substr(name,1,?)=?",arguments:[prefix.count,prefix]) {
                    guard let data=Data(base64Encoded:String(name.dropFirst(prefix.count))),let key=try? JSONDecoder().decode(ProviderKey.self,from:data),key.account == account else { continue }
                    try db.execute(sql:"DELETE FROM applicationSettings WHERE name=?",arguments:[name])
                }
            }
        }
    }
}
