import AppKit
import MergeProCore
import SwiftUI

struct PRActionPresentation:Identifiable {
    enum Kind { case merge(MergeAction?),review(ReviewDecision),close,batchMerge,batchApprove,labels }
    let id=UUID()
    let rows:[PullRequest]
    let kind:Kind
    /// Batch merge only: selected rows left out because of a known blocker, listed in the sheet with the reason.
    var skipped:[MergeBatchPlan.Skip]=[]
}
/// A dragged card or handle: the internal token for drops inside MergePro (visible to this process only) and the
/// pull request's https URL for other apps.
struct PRDragItem:Transferable {
    let token:String
    let url:URL
    static var transferRepresentation:some TransferRepresentation {
        ProxyRepresentation(exporting:\.token).visibility(.ownProcess)
        ProxyRepresentation(exporting:\.url)
    }
}
extension PRWorkspaceModel {
    /// The same repository/object under the action account: an indexed cache lookup, not a row scan.
    func actionPRCached(_ pr:PullRequest) -> PullRequest? {
        guard let account=activeActionAccount else { return nil }
        return cached(ProviderKey(host:account.host,accountID:account.accountID,repositoryID:pr.key.repositoryID,objectID:pr.key.objectID))
    }
    /// Fresh evaluation for actions (merge evidence ages out); cards display `cardEligibility`.
    /// Without an action-account row only the displayed row's own blockers are known (closed, draft, conflicts).
    func mergeEligibility(_ pr:PullRequest) -> MergeEligibility {
        actionPRCached(pr).map { MergePolicy.evaluate(pr:$0) } ?? MergePolicy.unverified(pr)
    }
    /// The eligibility cards and table rows show: `mergeEligibility` as of the last projection or evidence expiry
    /// (see `refreshEligibility`), so it agrees with menus and keys; reading it re-renders when it changes.
    func cardEligibility(_ pr:PullRequest) -> MergeEligibility { eligibility[pr.key] ?? mergeEligibility(pr) }
    /// One row's action set as its card or table row shows it, from `cardEligibility`.
    func rowActionState(_ pr:PullRequest) -> PRRowActionState { PRRowActionState(rows:[pr]) { self.cardEligibility($0) } }
    /// The shared action set for the rows an action applies to (one card, the table selection, a menu).
    func actionState(_ rows:[PullRequest]) -> PRRowActionState { PRRowActionState(rows:rows) { self.mergeEligibility($0) } }
    /// Opens the merge sheet unless a known blocker exists; stale or unknown evidence is verified in the sheet.
    /// An explicit `action` (auto-merge, update branch, remove from queue) always opens it; the sheet decides.
    func requestMerge(_ pr:PullRequest,action:MergeAction?=nil) {
        let current=mergeEligibility(pr)
        guard action != nil || current.opensMergeSheet else {
            status=current.blockers.joined(separator:" ");announce(status)
            blockedMerge=(pr,status ?? "")
            return
        }
        present(.init(rows:[pr],kind:.merge(action)))
    }
    func requestReview(_ pr:PullRequest,decision:ReviewDecision) { present(.init(rows:[pr],kind:.review(decision))) }
    /// Labels are edited in the picker; nothing is written until its explicit Apply.
    func requestLabels(_ pr:PullRequest) { present(.init(rows:[pr],kind:.labels)) }
    /// Close asks for confirmation in its own sheet.
    func requestClose(_ pr:PullRequest) {
        guard pr.state == .open else { status="Pull request is not open.";announce(status);return }
        present(.init(rows:[pr],kind:.close))
    }
    /// True while an action sheet is showing. Menu, menu-bar, notification and keyboard commands then present
    /// nothing (the Pull Request menu's commands are disabled): replacing the sheet would dismiss a merge or review
    /// mid-write together with its "Read provider result" controls.
    var isPresentingAction:Bool { actionPresentation != nil }
    /// Presents `presentation` unless a sheet is already showing; that sheet stays, and callers that bring the main
    /// window forward show it. Returns whether it was presented.
    @discardableResult func present(_ presentation:PRActionPresentation) -> Bool {
        guard actionPresentation == nil else {
            status="Finish or cancel the open sheet first.";announce(status)
            return false
        }
        actionPresentation=presentation
        return true
    }
    /// Selected rows in display order, limited to visible rows.
    var selectedRows:[PullRequest] { projection.rows.filter { selection.selected.contains($0.key) } }
    /// One row uses the normal flow (review composer, merge sheet); several open the batch sheet. Batch merge skips
    /// rows with known blockers and lists them; the rest are verified in the sheet before anything is sent.
    func requestBatch(approve:Bool,rows:[PullRequest]?=nil) {
        let selected=rows ?? selectedRows
        guard !selected.isEmpty else { return }
        if approve {
            let open=selected.filter { $0.state == .open }
            if open.count == 1,let pr=open.first { requestReview(pr,decision:.approve);return }
            guard !open.isEmpty else { status="No open pull requests are selected.";announce(status);return }
            present(.init(rows:open,kind:.batchApprove))
            return
        }
        if selected.count == 1,let pr=selected.first { requestMerge(pr);return }
        let plan=MergePolicy.batchPlan(selected) { self.mergeEligibility($0) }
        guard !plan.ready.isEmpty else {
            status="None of the selected pull requests can be merged: "+plan.skipped.map { "#\(String($0.pr.metadata?.number ?? 0)) \($0.reason)" }.joined(separator:" ")
            announce(status);return
        }
        if plan.ready.count == 1,plan.skipped.isEmpty,let pr=plan.ready.first { requestMerge(pr);return }
        present(.init(rows:plan.ready,kind:.batchMerge,skipped:plan.skipped))
    }
    /// Rows a keyboard command, the Pull Request menu, the palette and the list's selection bar act on
    /// (`PRSelection.commandKeys`): in the list the selection alone, so a row ⌘-clicked out of it is never acted on
    /// and an empty selection acts on nothing; on the board a multi-selection, else the focused card.
    var commandRows:[PullRequest] {
        selection.commandKeys(order:projection.rows.map(\.key),visibleFocus:visibleFocus,selectionOnly:state.current.mode == .list)
            .compactMap { cached($0) }
    }
    func keyboardAction(_ action:String) {
        let rows=commandRows
        guard let pr=rows.first else { return }
        switch action {
        case "a":requestBatch(approve:true,rows:rows)
        case "r":if rows.count == 1 { requestReview(pr,decision:.requestChanges) }
        case "c":if rows.count == 1 { requestReview(pr,decision:.comment) }
        case "m":requestBatch(approve:false,rows:rows)
        default:break
        }
    }
    /// Opens the PR window on its Checks tab (the run itself isn't known from the inventory).
    func openChecks(_ pr:PullRequest,open:(ProviderKey) -> Void) {
        requestDetailTab(.checks,for:pr.key)
        open(pr.key)
    }
    func openChecksOnWeb(_ pr:PullRequest) {
        if let url=pr.metadata?.webURL.appending(path:"checks") { ExternalLinkPolicy.open(url) }
    }
    func announce(_ message:String?) {
        guard let message,!message.isEmpty else { return }
        AccessibilityNotification.Announcement(message).post()
    }
    func dragToken(_ pr:PullRequest,merge:Bool) -> String { (merge ? "merge:" : "state:") + ((try? JSONEncoder.stable.encode(pr.key).base64EncodedString()) ?? "") }
    func cardDragToken(_ pr:PullRequest) -> String { "card:" + ((try? JSONEncoder.stable.encode(pr.key).base64EncodedString()) ?? "") }
    /// The drag payload for a card or handle: internal token plus the https URL for other apps.
    func dragItem(_ pr:PullRequest,token:String) -> PRDragItem { PRDragItem(token:token,url:pr.metadata?.webURL ?? pr.key.routeURL) }
    func drop(_ tokens:[String],column:PRColumn?) -> Bool {
        guard tokens.count == 1,let token=tokens.first,let separator=token.firstIndex(of:":"),let data=Data(base64Encoded:String(token[token.index(after:separator)...])),let key=try? JSONDecoder().decode(ProviderKey.self,from:data),let pr=cached(key) else { return false }
        let prefix=String(token[..<separator])
        guard ["card","state","merge"].contains(prefix),pr.state == .open else { return false }
        let merge=prefix == "merge"
        if column == .merged {
            guard merge || prefix == "card" else { return false }
            let current=mergeEligibility(pr)
            guard current.opensMergeSheet else { status=current.blockers.joined(separator:" ");announce(status);return false }
            requestMerge(pr);return true
        }
        guard !merge else { return false }
        switch column {
        case .none:return present(.init(rows:[pr],kind:.close))
        case .approved:requestReview(pr,decision:.approve)
        case .open:
            // With the Draft column hidden, drafts already sit in Open; dropping one there is not "mark ready".
            if pr.isDraft { guard state.current.showDrafts else { return false };Task { await setDraft(pr,false) } }
            else if BoardProjection.column(for:pr,showDrafts:true) == .approved { requestReview(pr,decision:.requestChanges) }
            else { return false }
        case .draft:guard pr.state == .open,!pr.isDraft else { return false };pendingDraftConversion=pr
        case .merged:return false
        }
        return true
    }
    func refreshMergeEvidence(_ read:PullRequest) async {
        let request=UUID(),account=activeActionAccount;stateActionRequest=request;status=nil
        do {
            _ = try await storage.mergeInspection(read)
            guard stateActionRequest == request,activeActionAccount == account,cached(read.key) != nil else { return };await reload()
        } catch { if stateActionRequest == request,activeActionAccount == account,cached(read.key) != nil { status=error.localizedDescription } }
    }
    func setDraft(_ read:PullRequest,_ draft:Bool) async {
        let request=UUID(),account=activeActionAccount;stateActionRequest=request;status=nil
        do {
            let pr=try await storage.actionPR(read),snapshot=try await storage.detail(pr)
            guard stateActionRequest == request,cached(pr.key) != nil,activeActionAccount == pr.key.account,let m=pr.metadata else { return }
            let command=PRWriteCommand(key:pr.key,repository:m.repositoryName,number:m.number,revision:.init(snapshot),intent:.metadata(.draft(draft)))
            let result=try await storage.performWrite(command)
            guard stateActionRequest == request,cached(pr.key) != nil,activeActionAccount == pr.key.account else { return }
            status=result.state == .confirmed ? (draft ? "Converted to draft." : "Marked ready for review.") : ProviderStateText.writeState(result.state)+(result.message.map { ". "+$0 } ?? ". Read the provider result before retrying; nothing was resent.")
            announce(status);await reload()
        } catch { if stateActionRequest == request,activeActionAccount == account,cached(read.key) != nil { status=error.localizedDescription } }
    }
    var stacks:[PRStack] { pipeline.stacks.stacks }
    func stack(for pr:PullRequest) -> PRStack? { pipeline.stacks.stack(for:pr.key) }
    /// Collapsed board cards, stored with each projection (a stack's visible representative owns the lane).
    var boardProjection:BoardProjection { board.cards }
}
struct PRActionSheet:View {
    let presentation:PRActionPresentation
    let workspace:PRWorkspaceModel
    var body:some View {
        if let pr=presentation.rows.first {
            switch presentation.kind {
            case .merge(let action):MergeOptionsSheet(readPR:pr,storage:workspace.storage,workspace:workspace,requestedAction:action)
            // Inbox sheets are presented from view state, so no workspace presentation is current there.
            case .review(let decision):ReviewComposer(readPR:pr,storage:workspace.storage,workspace:workspace,initialDecision:decision,didWrite:{ let request=presentation.id,account=workspace.activeActionAccount;Task { guard workspace.actionPresentation.map({ $0.id == request }) ?? true,workspace.activeActionAccount == account else { return };await workspace.reload() } })
            case .close:PRCloseSheet(readPR:pr,workspace:workspace)
            case .batchMerge:PRBatchActionSheet(rows:presentation.rows,approve:false,workspace:workspace,skipped:presentation.skipped)
            case .batchApprove:PRBatchActionSheet(rows:presentation.rows,approve:true,workspace:workspace)
            case .labels:PRLabelPicker(pr:pr,storage:workspace.storage,workspace:workspace)
            }
        }
    }
}
struct PRCloseSheet:View {
    let readPR:PullRequest
    let workspace:PRWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var identity=PRActionLoadState()
    @State private var command:PRWriteCommand?
    @State private var status:String?
    @State private var busy=false
    private var available:Bool { identity.key.map { workspace.cached($0) != nil && workspace.activeActionAccount == $0.account } ?? true }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Close pull request?").font(.headline)
            if let command,identity.canDisplay(command.key,available:available) {
                Text("\(command.repository) #\(String(command.number)) · Action account \(workspace.login(command.key.account))")
                Text("This closes the PR without merging.")
                Button("Close pull request",role:.destructive) { Task { await close(command) } }.disabled(busy)
            } else { Text("Reading selected account…") }
            if available,let status { Text(status).font(.caption) }
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(20).frame(width:440).task { await load() }.onChange(of:available) { _,available in if !available { identity.invalidate();command=nil;status=nil;busy=false } }
    }
    private func load() async {
        let request=identity.begin()
        do {
            let pr=try await workspace.storage.actionPR(readPR);identity.select(pr.key,request:request)
            let detail=try await workspace.storage.detail(pr)
            guard let m=pr.metadata else { throw PRWriteFailure.unavailable }
            let value=PRWriteCommand(key:pr.key,repository:m.repositoryName,number:m.number,revision:.init(detail),intent:.metadata(.closed(true)))
            let truth=try await workspace.storage.inspectWrite(value);try value.validate(truth:truth)
            guard identity.present(pr.key,request:request,available:available) else { return };command=value
        } catch { if identity.fail(request:request) { status=error.localizedDescription } }
    }
    private func close(_ command:PRWriteCommand) async {
        guard let request=identity.presentationRequest(for:command.key,available:available) else { return };busy=true
        defer { if identity.isCurrent(request) { busy=false } }
        do {
            let result=try await workspace.storage.performWrite(command)
            guard identity.accepts(command.key,request:request,available:available) else { return }
            status=result.state == .confirmed ? "GitHub closed the pull request." : ProviderStateText.writeState(result.state)+". Read the provider result before retrying; nothing was resent."
            workspace.announce(status)
            await workspace.reload()
        } catch { if identity.accepts(command.key,request:request,available:available) { status=error.localizedDescription } }
    }
}
