import Foundation

public enum ReviewDecision:String,Codable,Sendable { case approve,requestChanges,comment
    public var providerEvent:String { switch self { case .approve:"APPROVE";case .requestChanges:"REQUEST_CHANGES";case .comment:"COMMENT" } }
}
public struct PRWriteRevision:Codable,Sendable,Equatable {
    public let head:String
    public let origin:String
    public let target:String
    public init(head:String,origin:String,target:String) { self.head=head;self.origin=origin;self.target=target }
    public init(_ snapshot:PRDetailSnapshot) { self.init(head:snapshot.headSHA,origin:snapshot.baseSHA,target:snapshot.baseBranchSHA) }
}
/// Value-only native load generation. Availability is supplied by the existing workspace,
/// not cached/owned here; invalidation makes a late result permanently ineligible.
public struct PRActionLoadState:Sendable {
    /// Selected request identity is separate from the identity allowed to render private values.
    public private(set) var key:ProviderKey?
    public private(set) var presentedKey:ProviderKey?
    private var request:UUID?
    public init() {}
    public mutating func begin() -> UUID { let id=UUID();request=id;key=nil;presentedKey=nil;return id }
    public mutating func select(_ key:ProviderKey,request:UUID) { if self.request == request { self.key=key;presentedKey=nil } }
    public mutating func invalidate() { request=nil;presentedKey=nil }
    public func isCurrent(_ request:UUID) -> Bool { self.request == request }
    public func accepts(_ key:ProviderKey,request:UUID,available:Bool) -> Bool { available && self.key == key && self.request == request }
    public mutating func present(_ key:ProviderKey,request:UUID,available:Bool) -> Bool {
        guard accepts(key,request:request,available:available) else { return false }
        presentedKey=key;return true
    }
    public mutating func fail(request:UUID) -> Bool {
        guard isCurrent(request) else { return false }
        self.request=nil;presentedKey=nil;return true
    }
    public func canDisplay(_ key:ProviderKey?,available:Bool) -> Bool { key != nil && available && presentedKey == key }
    /// Apply suspended native effects only to their still-displayed generation.
    @discardableResult public func publish(_ key:ProviderKey,request:UUID,available:Bool,effect:() -> Void) -> Bool {
        guard accepts(key,request:request,available:available),canDisplay(key,available:available) else { return false }
        effect();return true
    }
    /// Capture before an operation-status callback suspends; admit its result with accepts.
    public func presentationRequest(for key:ProviderKey,available:Bool) -> UUID? { canDisplay(key,available:available) ? request : nil }
}
public enum PRCommentKind:String,Codable,Sendable { case conversation,review }
public enum PRReaction:String,Codable,Sendable,CaseIterable { case thumbsUp="THUMBS_UP",thumbsDown="THUMBS_DOWN",laugh="LAUGH",hooray="HOORAY",confused="CONFUSED",heart="HEART",rocket="ROCKET",eyes="EYES" }
/// Provider node identities for delta writes. Names, logins and slugs are display/REST evidence.
public struct PRLabelRef:Codable,Hashable,Sendable { public let id:String;public let name:String;public init(id:String,name:String) { self.id=id;self.name=name } }
public struct PRUserRef:Codable,Hashable,Sendable { public let id:String;public let login:String;public init(id:String,login:String) { self.id=id;self.login=login } }
public struct PRTeamRef:Codable,Hashable,Sendable { public let id:String;public let slug:String;public init(id:String,slug:String) { self.id=id;self.slug=slug } }
public enum PRSubscriptionState:String,Codable,Sendable,CaseIterable { case subscribed="SUBSCRIBED",unsubscribed="UNSUBSCRIBED",ignored="IGNORED" }
public enum PRMetadataMutation:Codable,Sendable,Equatable {
    case title(String),body(String),base(String),labels([String]),assignees([String]),milestone(Int?),reviewers(users:[String],teams:[String],remove:Bool),draft(Bool),closed(Bool)
    /// Revision-independent deltas by provider node ID. Concurrent unrelated changes survive;
    /// the legacy replace-all `labels`/`assignees`/`reviewers` cases remain for compatibility.
    case labelChanges(add:[PRLabelRef],remove:[PRLabelRef]),assigneeChanges(add:[PRUserRef],remove:[PRUserRef])
    case reviewRequestChanges(addUsers:[PRUserRef],addTeams:[PRTeamRef],removeUsers:[PRUserRef],removeTeams:[PRTeamRef])
}
public enum PRWriteIntent:Codable,Sendable,Equatable {
    case merge(MergeCommand)
    case review(ReviewDecision,String),createPending(String),submitPending(id:String,decision:ReviewDecision,summary:String)
    case thread(ReviewDraftComment,pendingReviewID:String?),reply(threadID:String,body:String,pendingReviewID:String?)
    case conversation(String),editComment(id:String,kind:PRCommentKind,body:String),deleteComment(id:String,kind:PRCommentKind)
    case resolve(threadID:String,resolved:Bool),reaction(subjectID:String,reaction:PRReaction,remove:Bool)
    case moderate(subjectID:String,classifier:String?),metadata(PRMetadataMutation),viewed(path:String,viewed:Bool)
    /// Delete the viewer's PENDING review, on any head; this resolves a stale `pendingExists`.
    case discardPendingReview(reviewID:String)
    case dismissReview(reviewID:String,message:String),subscription(state:PRSubscriptionState)
    /// Label, assignee and review-request deltas and subscription: resending them is harmless (unlike comments
    /// and merges), so a stuck outcome may be settled explicitly with `PRWriteCoordinator.abandonUncertain`.
    public var isIdempotent:Bool {
        switch self {
        case .metadata(.labelChanges),.metadata(.assigneeChanges),.metadata(.reviewRequestChanges),.subscription:true
        default:false
        }
    }
    public var decision:ReviewDecision? { switch self { case .review(let d,_),.submitPending(_,let d,_):d;default:nil } }
    /// Light intents admit and reconcile against a single small provider read; head/base
    /// movement cannot invalidate them, so the command revision is informational only.
    public var isRevisionIndependent:Bool {
        switch self {
        case .metadata(.labelChanges),.metadata(.assigneeChanges),.metadata(.reviewRequestChanges),.subscription,.discardPendingReview,.dismissReview:true
        default:false
        }
    }
    /// Command-intrinsic checks that need no provider read: non-empty, non-contradictory deltas
    /// and a dismissal message.
    public func validateShape() throws {
        func delta(_ add:[String],_ remove:[String]) throws { guard !(add.isEmpty && remove.isEmpty),Set(add).isDisjoint(with:remove),!(add+remove).contains(where:\.isEmpty) else { throw PRWriteFailure.invalidChange } }
        switch self {
        case .metadata(.labelChanges(let add,let remove)):try delta(add.map(\.id),remove.map(\.id))
        case .metadata(.assigneeChanges(let add,let remove)):try delta(add.map(\.id),remove.map(\.id))
        case .metadata(.reviewRequestChanges(let users,let teams,let removeUsers,let removeTeams)):try delta(users.map(\.id)+teams.map(\.id),removeUsers.map(\.id)+removeTeams.map(\.id))
        case .discardPendingReview(let id):guard !id.isEmpty else { throw PRWriteFailure.invalidChange }
        case .dismissReview(let id,let message):
            guard !id.isEmpty else { throw PRWriteFailure.invalidChange }
            guard !message.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw PRWriteFailure.messageRequired }
        default:break
        }
    }
}
public enum PRWriteFailure:Error,LocalizedError,Equatable,Sendable {
    case accountChanged,unavailable,revisionChanged,permissionDenied,ownApproval,pendingExists,uncertain,invalidAnchor,viewedIncomplete,operationInProgress,persistenceBeforeSend,draftChanged,unsentComments
    case invalidChange,messageRequired
    /// The affected current list (labels, assignees or review requests) has more than 100 entries, so the
    /// delta could never be verified. Nothing was sent.
    case listIncomplete
    public var errorDescription:String? { switch self {
    case .listIncomplete:"This pull request has more than 100 labels, assignees or review requests, so MergePro can't verify this change. Nothing was sent; make the change on GitHub."
    case .invalidChange:"This change is empty or adds and removes the same item. Nothing was sent."
    case .messageRequired:"Dismissing a review requires a message. Nothing was sent."
    case .accountChanged:"The active action account changed. Review this command with the selected account."
    case .unavailable:"The selected account can’t take this action on this pull request."
    case .revisionChanged:"The head or comparison base changed. Your original draft is preserved; review relocation explicitly."
    case .permissionDenied:"The selected account no longer has permission for this object."
    case .ownApproval:"You cannot approve your own pull request."
    case .pendingExists:"This account already has a pending review. Open that review before continuing."
    case .uncertain:"GitHub may have received this command. Refresh and reconcile it before retrying."
    case .invalidAnchor:"Only original coordinates in the current pull request diff can receive comments."
    case .viewedIncomplete:"Approval requires a complete current-revision provider read with every file viewed."
    case .operationInProgress:"A write for this pull request is still pending reconciliation."
    case .persistenceBeforeSend:"The command could not be saved locally. No request was sent."
    case .draftChanged:"A newer draft is saved. Reload it before replacing or submitting this editor's older version."
    case .unsentComments:"This draft still has unsent comments or edits. Stage them in its pending review before submitting."
    } }
}
/// A revision-independent light write that SETTLED as not (fully) applied; its operation is terminal
/// (`.rejected`) and releases the pull request. Nothing is resent.
/// - `partial`: every part has a definite outcome but they split, e.g. "Added ‘bug’; removing ‘wontfix’ was refused by GitHub."
/// - `notShown`: after an ambiguous or lost receipt, a complete fresh read does not show the change.
public struct PRWriteRejection:Error,LocalizedError,Sendable {
    public enum Kind:Sendable,Equatable { case partial,notShown }
    public let kind:Kind
    public let summary:String
    /// Raw provider evidence (the receipt of the parts that applied plus the refusal), kept on the operation.
    let response:Data?
    /// The refusal of the failed part, so an authentication failure still reaches the session owner.
    let cause:(any Error)?
    init(kind:Kind,summary:String,response:Data?=nil,cause:(any Error)?=nil) { self.kind=kind;self.summary=summary;self.response=response;self.cause=cause }
    public var errorDescription:String? { summary }
}
public struct PRWriteCommand:Codable,Sendable,Equatable {
    public static func viewed(readPR:PullRequest,actionPR:PullRequest,revision:PRWriteRevision,path:String,viewed:Bool) throws -> Self {
        guard readPR.key.host == actionPR.key.host,readPR.key.repositoryID == actionPR.key.repositoryID,readPR.key.objectID == actionPR.key.objectID,let metadata=actionPR.metadata else { throw PRWriteFailure.unavailable }
        return .init(key:actionPR.key,repository:metadata.repositoryName,number:metadata.number,revision:revision,intent:.viewed(path:path,viewed:viewed))
    }
    /// A light command from the cached action-account row; no detail fetch. Its revision is
    /// cached head/base-tip evidence only (origin is not re-derived) and never gates admission.
    public static func revisionIndependent(actionPR:PullRequest,intent:PRWriteIntent) throws -> Self {
        guard intent.isRevisionIndependent,let metadata=actionPR.metadata else { throw PRWriteFailure.unavailable }
        return .init(key:actionPR.key,repository:metadata.repositoryName,number:metadata.number,revision:.init(head:actionPR.headRevision.rawValue,origin:metadata.baseRevision,target:metadata.baseRevision),intent:intent)
    }
    public static func labelChanges(actionPR:PullRequest,add:[PRLabelRef],remove:[PRLabelRef]) throws -> Self { try revisionIndependent(actionPR:actionPR,intent:.metadata(.labelChanges(add:add,remove:remove))) }
    public var reservedKeys:Set<ProviderKey> {
        if case .merge(let command)=intent { return Set(command.affected.map(\.key)) }
        return [key]
    }
    /// Inventory uses the exact kind prefix; raw IDs are retained for trusted legacy/fixture keys.
    public var gitHubNodeID:String { Self.gitHubNodeID(for:key) }
    static func gitHubNodeID(for key:ProviderKey) -> String { key.objectID.hasPrefix("pull-request:") ? String(key.objectID.dropFirst("pull-request:".count)) : key.objectID }
    public let key:ProviderKey
    public let repository:String
    public let number:Int
    public let revision:PRWriteRevision
    public let intent:PRWriteIntent
    public let requireAllViewed:Bool
    public init(key:ProviderKey,repository:String,number:Int,revision:PRWriteRevision,intent:PRWriteIntent,requireAllViewed:Bool=false) { self.key=key;self.repository=repository;self.number=number;self.revision=revision;self.intent=intent;self.requireAllViewed=requireAllViewed }
    public func validate(truth:PRWriteTruth) throws {
        guard truth.key == key else { throw PRWriteFailure.accountChanged }
        try intent.validateShape()
        guard intent.isRevisionIndependent || truth.revision == revision else { throw PRWriteFailure.revisionChanged }
        if intent.decision == .approve,truth.viewerIsAuthor { throw PRWriteFailure.ownApproval }
        if intent.decision == .approve,requireAllViewed,truth.riskFlagged {
            guard truth.filesComplete,truth.viewed == truth.files else { throw PRWriteFailure.viewedIncomplete }
        }
        switch intent {
        case .merge:throw PRWriteFailure.unavailable
        case .review,.createPending:
            guard truth.canReview,truth.isOpen else { throw PRWriteFailure.permissionDenied }
            guard truth.pendingReviewID == nil else { throw PRWriteFailure.pendingExists }
        case .submitPending(let id,_,_):
            guard truth.canReview,truth.isOpen,truth.pendingReviewID == id,truth.pendingReviewHead == revision.head else { throw PRWriteFailure.permissionDenied }
        case .thread(let comment,let pending):
            guard comment.revision == revision else { throw PRWriteFailure.revisionChanged }
            guard truth.canReview,truth.isOpen,truth.files.contains(comment.providerPath) else { throw PRWriteFailure.permissionDenied }
            if let pending { guard truth.pendingReviewID == pending,truth.pendingReviewHead == revision.head else { throw PRWriteFailure.pendingExists } }
            else if truth.pendingReviewID != nil { throw PRWriteFailure.pendingExists }
            if let anchor=comment.contentAnchor {
                guard let location=truth.document?.providerCommentLocation(for:anchor),location == comment.location else { throw PRWriteFailure.invalidAnchor }
            }
        case .reply(let id,_,let pending):
            guard truth.threadIDs.contains(id),truth.allowedObjectIDs.contains(id),truth.canReview,truth.isOpen else { throw PRWriteFailure.permissionDenied }
            if let pending { guard truth.pendingReviewID == pending,truth.pendingReviewHead == revision.head else { throw PRWriteFailure.pendingExists } }
        case .editComment(let id,_,_),.deleteComment(let id,_):
            guard truth.ownCommentIDs.contains(id),truth.allowedObjectIDs.contains(id) else { throw PRWriteFailure.permissionDenied }
        case .resolve(let id,_),.reaction(let id,_,_),.moderate(let id,_):
            guard truth.allowedObjectIDs.contains(id) else { throw PRWriteFailure.permissionDenied }
        case .conversation:
            guard truth.canComment else { throw PRWriteFailure.permissionDenied }
        case .metadata(.closed(true)):
            guard truth.canClose,truth.isOpen else { throw PRWriteFailure.permissionDenied }
        case .metadata(.draft):
            guard truth.canChangeDraft,truth.isOpen else { throw PRWriteFailure.permissionDenied }
        case .metadata(.closed(false)):
            guard truth.canReopen else { throw PRWriteFailure.permissionDenied }
        case .metadata(.labels):
            guard truth.canLabel else { throw PRWriteFailure.permissionDenied }
        // A delta against an incomplete (>100) current list could never be verified, so it is not admitted.
        case .metadata(.labelChanges):
            guard truth.canLabel else { throw PRWriteFailure.permissionDenied }
            guard truth.labelsComplete else { throw PRWriteFailure.listIncomplete }
        case .metadata(.assigneeChanges):
            guard truth.canAssign else { throw PRWriteFailure.permissionDenied }
            guard truth.assigneesComplete else { throw PRWriteFailure.listIncomplete }
        case .metadata(.reviewRequestChanges):
            guard truth.canRequestReviews else { throw PRWriteFailure.permissionDenied }
            guard truth.requestsComplete else { throw PRWriteFailure.listIncomplete }
        case .subscription:
            guard truth.canSubscribe else { throw PRWriteFailure.permissionDenied }
        case .discardPendingReview(let id),.dismissReview(let id,_):
            guard truth.allowedObjectIDs.contains(id) else { throw PRWriteFailure.permissionDenied }
        case .metadata:
            guard truth.canUpdate else { throw PRWriteFailure.permissionDenied }
        case .viewed(let path,_):
            guard truth.files.contains(path),truth.filesComplete else { throw PRWriteFailure.invalidAnchor }
        }
    }
    /// The provider object a light receipt or read confirms: the review for discard/dismiss, else the PR node.
    var lightTargetID:String {
        switch intent {
        case .discardPendingReview(let id),.dismissReview(let id,_):id
        default:gitHubNodeID
        }
    }
    /// Whether an unmatched light read settles the outcome: the affected list was read completely (discard reads
    /// the viewer's complete PENDING list); a dismissal's review node and the subscription state are single values.
    func lightReadIsDecisive(_ truth:PRWriteTruth) -> Bool {
        guard truth.key == key else { return false }
        switch intent {
        case .metadata(.labelChanges):return truth.labelsComplete
        case .metadata(.assigneeChanges):return truth.assigneesComplete
        case .metadata(.reviewRequestChanges):return truth.requestsComplete
        case .discardPendingReview:return truth.reviewsComplete
        case .dismissReview,.subscription:return true
        default:return false
        }
    }
    public func reconciliation(truth:PRWriteTruth) -> PRWriteOperation.State {
        guard truth.key == key,truth.matchingOperationIDs.count == 1 else { return .uncertain }
        switch intent {
        case .metadata,.conversation,.editComment,.deleteComment,.resolve,.reaction,.moderate,.discardPendingReview,.dismissReview,.subscription:
            return .confirmed
        default:
            if truth.placementOutdated { return .postedOutdated }
            guard truth.placementConfirmed else { return .uncertain }
            return truth.revision == revision ? .confirmed : .postedOutdated
        }
    }
}
/// Credential-free provider truth, including complete current-account viewed evidence.
public struct PRWriteTruth:Sendable {
    public let key:ProviderKey
    public var revision:PRWriteRevision
    public var viewerIsAuthor:Bool
    public var canReview:Bool
    public var canComment:Bool
    public var canUpdate:Bool
    public var canClose=false
    public var canChangeDraft=false
    public var canReopen:Bool
    public var canLabel:Bool
    public var isOpen:Bool
    public var pendingReviewID:String?
    public var pendingReviewHead:String?
    public var files:Set<String>
    public var viewed:Set<String>
    public var filesComplete:Bool
    public var ownCommentIDs:Set<String>
    public var allowedObjectIDs:Set<String>
    public var threadIDs:Set<String>
    public var riskFlagged:Bool = true
    public var threads:[PRWritableThread] = []
    public var conversation:[PRWritableComment] = []
    public var threadsComplete:Bool = false
    public var placementConfirmed:Bool = true
    public var placementOutdated:Bool = false
    public var existingObjectIDs:Set<String> = []
    public var matchingOperationIDs:[String]
    public var document:DiffDocument?
    public var normalized:PullRequest?
    public var requestsComplete:Bool = false
    public var affectedReviewRequestIDs:Set<String> = []
    public var labelsComplete:Bool = false
    public var assigneesComplete:Bool = false
    public var codeOwnerRequirements:String?
    public var canAssign=false
    public var canSubscribe=false
    /// Repository TRIAGE/WRITE/MAINTAIN/ADMIN; PR viewerCanUpdate alone does not grant requests.
    public var canRequestReviews=false
    /// Light-read evidence with provider node IDs. A light truth has no `normalized` PR and its
    /// revision origin is empty (not read); only the fields of its own intent are populated.
    public var labelRefs:[PRLabelRef]=[]
    public var labelColors:[String:String]?
    public var assigneeRefs:[PRUserRef]=[]
    public var requestedUsers:[PRUserRef]=[]
    public var requestedTeams:[PRTeamRef]=[]
    public var viewerSubscription:PRSubscriptionState?
    public var reviews:[PRReviewSummary]=[]
    public var reviewsComplete=false
    public var reviewDecision:String?
    public init(key:ProviderKey,revision:PRWriteRevision,viewerIsAuthor:Bool,canReview:Bool,canComment:Bool,canUpdate:Bool,canReopen:Bool,canLabel:Bool,isOpen:Bool,pendingReviewID:String?=nil,pendingReviewHead:String?=nil,files:Set<String>=[],viewed:Set<String>=[],filesComplete:Bool=false,ownCommentIDs:Set<String>=[],allowedObjectIDs:Set<String>=[],threadIDs:Set<String>=[],matchingOperationIDs:[String]=[],document:DiffDocument?=nil,normalized:PullRequest?=nil,codeOwnerRequirements:String?=nil) {
        self.key=key;self.revision=revision;self.viewerIsAuthor=viewerIsAuthor;self.canReview=canReview;self.canComment=canComment;self.canUpdate=canUpdate;self.canReopen=canReopen;self.canLabel=canLabel;self.isOpen=isOpen;self.pendingReviewID=pendingReviewID;self.pendingReviewHead=pendingReviewHead;self.files=files;self.viewed=viewed;self.filesComplete=filesComplete;self.ownCommentIDs=ownCommentIDs;self.allowedObjectIDs=allowedObjectIDs;self.threadIDs=threadIDs;self.matchingOperationIDs=matchingOperationIDs;self.document=document;self.normalized=normalized;self.codeOwnerRequirements=codeOwnerRequirements
    }
}
