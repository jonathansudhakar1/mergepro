import AppKit
import MergeProCore
import SwiftUI

/// Native explicit commands; all credential/account/budget admission remains in Core.
struct ReviewComposer:View {
    let readPR:PullRequest
    let storage:SetupStorage
    var workspace:PRWorkspaceModel? = nil
    /// The head the PR window shows; nil outside one. The draft is created, submitted and recorded only at this head:
    /// a newer action-account head is refused, pointing to the window's Update.
    var displayedHead:String? = nil
    @State private var loadState=PRActionLoadState()
    @State private var operationRevision=0
    @State private var loadError:String?
    private var actionAvailable:Bool { loadState.key.map { workspace == nil || workspace?.cached($0) != nil } ?? true }
    var initialDecision:ReviewDecision = .comment
    var selection:ReviewDraftComment? = nil
    var didWrite:(@MainActor () -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var pr:PullRequest?
    @State private var snapshot:PRDetailSnapshot?
    @State private var draft:ReviewDraft?
    @State private var saveConflict=false
    @State private var draftSaveBusy=false
    @State private var draftSavePending=false
    @State private var decision:ReviewDecision = .comment
    @State private var summary=""
    @State private var commentBody=""
    @State private var preview=false
    @State private var login=""
    @State private var status:String?
    @State private var busy=false
    @State private var truth:PRWriteTruth?
    @State private var requireViewed=false
    /// A new draft opened before the PR detail arrived carries the board row's revision; the detail replaces it
    /// (not a stale draft) and the draft is saved only from then on.
    @State private var provisional=false
    @State private var provisionalSavePending=false
    @State private var references:[String]=[]
    /// A pending review the user asked to discard; confirmed in a dialog before anything is sent.
    @State private var discardTarget:String?
    /// Return in the summary or selection comment inserts text; it never reaches the submit button. ⌘Return submits.
    @FocusState private var focus:Field?
    private enum Field:Hashable { case summary,selection }
    private var stale:Bool {
        guard let snapshot,!provisional else { return false }
        return draft?.revision != PRWriteRevision(snapshot) || draft?.comments.contains(where:{ $0.revision != draft?.revision }) == true
    }
    var body:some View {
        Group {
            if actionAvailable {
                if loadState.canDisplay(pr?.key,available:true) { content }
                else { replacement }
            }
            else { ContentUnavailableView { Label("Action account unavailable",systemImage:"lock") } description: { Text("Reconnect the selected account. Drafts remain on disk.") } actions: { Button("Try Again") { Task { await load() } } } }
        }.onChange(of:actionAvailable) { if !actionAvailable { invalidateAction() } }
        .task { decision=initialDecision;await load() }
    }
    private var replacement:some View {
        VStack(spacing:12) {
            if busy { ProgressView("Reading selected action account…") }
            else { Text(loadError ?? "Selected account data unavailable") }
            Button("Try Again") { Task { await load() } }.disabled(busy || draftSaveBusy);Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding()
    }
    private var content:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("Review pull request").font(.system(.title2,design:.rounded).bold());Spacer();Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
            HStack(spacing:6) {
                Label("\(login.isEmpty ? "Account unavailable" : login) · \(pr?.key.host ?? readPR.key.host)",systemImage:"person.crop.circle").foregroundStyle(.secondary)
                Button { Task { await load() } } label: { Image(systemName:"arrow.clockwise") }.buttonStyle(.borderless).disabled(busy || draftSaveBusy).help("Reload the pull request and this account's review state")
            }.font(.callout)
            if saveConflict { Text("Another editor saved this draft. Local text remains here; copy or resolve it before explicitly reloading the saved draft.").foregroundStyle(.orange) }
            if let status { Text(status).foregroundStyle(.secondary).textSelection(.enabled) }
            if let draft {
                DisclosureGroup("Revision details") {
                    Text("Reviewed head \(draft.revision.head.prefix(8)) · diff origin \(draft.revision.origin.prefix(8)) · target \(draft.revision.target.prefix(8))").font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                }.font(.caption)
                if !stale,let refusal=headRefusal(draft) { Text(refusal).foregroundStyle(.orange) }
                if stale {
                    Text("This draft belongs to an earlier comparison. Original anchors remain saved. Review each relocation before submitting.").foregroundStyle(.orange)
                    Button("Review summary against current revision") { if var d=self.draft,let snapshot,d.comments.isEmpty,d.pendingReviewID == nil { d.priorRevisions.append(d.revision);d.revision=PRWriteRevision(snapshot);self.draft=d;persist() } }.disabled(!draft.comments.isEmpty || draft.pendingReviewID != nil)
                }
                Picker("Decision",selection:$decision) { Text("Comment").tag(ReviewDecision.comment);Text("Approve").tag(ReviewDecision.approve);Text("Request changes").tag(ReviewDecision.requestChanges) }.pickerStyle(.segmented)
                if decision == .approve,truth?.viewerIsAuthor == true {
                    Text("You cannot approve your own pull request. You can leave a comment instead.").foregroundStyle(.orange)
                }
                if decision == .approve,requireViewed { Text("Settings require all files marked Viewed on GitHub before approving a risky pull request.").font(.caption).foregroundStyle(.secondary) }
                Toggle("Markdown preview",isOn:$preview)
                if preview { ScrollView { MarkdownView(source:summary,webURL:pr?.metadata?.webURL) }.frame(minHeight:150,maxHeight:220) }
                else { TextEditor(text:$summary).font(.body).frame(height:150).border(.separator).focused($focus,equals:.summary).accessibilityLabel("Review summary") }
                HStack {
                    Menu("Insert mention") { ForEach(completions,id:\.self) { value in Button("@"+value) { summary += " @"+value } } }
                    Menu("Reference") { ForEach(references,id:\.self) { value in Button(value) { summary += " "+value } } }
                    Menu("Emoji") { ForEach(["👍","🎉","❤️","🚀","👀"],id:\.self) { value in Button(value) { summary += value } } }
                    Menu("Template") { Button("Review checklist") { summary += "\n## Review\n- [ ] Correctness\n- [ ] Tests\n- [ ] Documentation" };Button("Questions") { summary += "\n## Questions\n\n## Suggestions\n" } }
                }
                if !completionSuggestions.isEmpty { HStack { Text("Complete:").font(.caption);ForEach(completionSuggestions,id:\.self) { value in Button(value) { complete(value) } } } }
                if let selection {
                    Divider();Text(selection.location.map { "Selected \($0.side) \(selection.providerPath):\($0.startLine)–\($0.endLine)" } ?? "File comment: \(selection.providerPath)")
                    TextField("Comment for selection",text:$commentBody,axis:.vertical).lineLimit(3...6).focused($focus,equals:.selection)
                    Button("Add selection to pending draft") { addSelection(selection) }.disabled(busy || commentBody.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
                if !draft.comments.isEmpty { ScrollView { ForEach(draft.comments) { comment in
                    VStack(alignment:.leading) { Text("\(comment.providerPath) · \(comment.postedCommentID == nil ? "Local draft" : comment.hasUnsentEdit ? "Provider comment · newer local edit unsent" : "Provider pending comment")").font(.caption);Text(comment.body).textSelection(.enabled)
                        if let selection,comment.postedCommentID == nil { Button("Relocate this draft to selected current coordinates") { relocate(comment,to:selection) }.disabled(busy) }
                    }.padding(6)
                } }.frame(maxHeight:110) }
                if let pending=truth?.pendingReviewID,draft.pendingReviewID != pending || pendingIsStale { pendingReviewNotice(pending,draft:draft) }
                // Only a draft with inline comments has anything to archive before starting over.
                if truth?.pendingReviewID == nil,!draft.comments.isEmpty,let snapshot {
                    Button("Start next review · archive current draft") { Task { await startNextReview(draft,revision:PRWriteRevision(snapshot)) } }.disabled(busy)
                }
                if !draft.previousDrafts.isEmpty { DisclosureGroup("Saved prior drafts (\(draft.previousDrafts.count))") { ScrollView { ForEach(Array(draft.previousDrafts.enumerated()),id:\.offset) { _,old in Text("\(old.revision.head.prefix(8)) · \(old.summary)").textSelection(.enabled);ForEach(old.comments) { comment in Text("\(comment.providerPath): \(comment.body)").textSelection(.enabled) } } }.frame(maxHeight:100) } }
                Spacer(minLength:0)
                if truth?.codeOwnerRequirements?.contains("true") == true {
                    Label("A code owner must approve before this pull request can merge.",systemImage:"person.badge.shield.checkmark").font(.caption).foregroundStyle(.secondary)
                        .help(truth?.codeOwnerRequirements ?? "")
                }
                operationStatus(draft.key)
                HStack {
                    Button("Save draft") { persist() };Spacer()
                    if busy { ProgressView().controlSize(.small);Text("Sending to GitHub…").font(.callout).foregroundStyle(.secondary) }
                    Button("Post conversation comment") { Task { await conversation() } }.disabled(busy || saveConflict || draftSaveBusy || stale || summary.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    Button(draft.pendingReviewID == nil && draft.comments.isEmpty ? "Submit review" : "Submit pending review") { Task { await submit() } }.keyboardShortcut(focus == nil ? .defaultAction : nil).buttonStyle(.borderedProminent).disabled(!canSubmit(draft)).help("Submit (⌘Return)")
                }
                .background { Button("Submit review") { if canSubmit(draft) { Task { await submit() } } }.keyboardShortcut(.return,modifiers:.command).hidden().accessibilityHidden(true) }
            } else { ProgressView("Resolving selected account…") }
        }.padding(20).frame(width:720,height:640,alignment:.topLeading)
        .confirmationDialog("Discard pending review?",isPresented:Binding(get:{ discardTarget != nil },set:{ if !$0 { discardTarget=nil } }),titleVisibility:.visible,presenting:discardTarget) { id in
            Button("Discard pending review",role:.destructive) { Task { await discardPending(id) } }
            Button("Cancel",role:.cancel) {}
        } message: { _ in Text("GitHub deletes this pending review and its unsubmitted comments. Your local draft text is archived under Saved prior drafts.") }
        .onChange(of:summary) { if var d=draft { d.summary=summary;draft=d;persist() } }
        .onChange(of:commentBody) { if var d=draft { d.texts["selection"]=commentBody;draft=d;persist() } }
    }
    private func canSubmit(_ draft:ReviewDraft) -> Bool { !(busy || saveConflict || draftSaveBusy || stale || provisional || pr == nil || snapshot == nil || truth == nil || decision == .approve && truth?.viewerIsAuthor == true || needsSummary(draft) || blockedByPending(draft) || headRefusal(draft) != nil) }
    /// The window applied Update while this sheet was open: the draft's head is no longer the one on screen.
    private func headRefusal(_ draft:ReviewDraft) -> String? { PRDisplayedHead.refusal(shown:displayedHead,actual:draft.revision.head,acting:"submitting this review") }
    /// Another (or a stale) pending review makes GitHub reject a new review; the notice offers Discard instead.
    private func blockedByPending(_ draft:ReviewDraft) -> Bool { truth?.pendingReviewID != nil && (draft.pendingReviewID != truth?.pendingReviewID || pendingIsStale) }
    /// The account's pending review was started on an older head, so no new review can be submitted until it is discarded.
    private var pendingIsStale:Bool { truth?.pendingReviewID != nil && truth?.pendingReviewHead.map { $0 != snapshot?.headSHA } == true }
    private func pendingReviewNotice(_ pending:String,draft:ReviewDraft) -> some View {
        let head=truth?.pendingReviewHead,stale=pendingIsStale
        let usable = !stale && head != nil && head == draft.revision.head && draft.pendingReviewID == nil
        return VStack(alignment:.leading,spacing:8) {
            Label(stale ? "A pending review on an older head (\(head?.prefix(8) ?? "unknown")) blocks a new review." : head == nil ? "This account has a pending review on an unknown head." : "This account already has pending review \(pending.prefix(12)).",systemImage:stale ? "exclamationmark.triangle.fill" : "clock")
                .font(.callout.weight(.medium)).foregroundStyle(stale ? Color.orange : Color.primary)
            Text(stale ? "GitHub allows one pending review per account. Discard it to review the current head; its unsubmitted comments are deleted on GitHub and this draft is archived." : usable ? "Continue that pending review, or discard it to start over." : "Discard it to start a new review, or finish it on GitHub.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack(spacing:8) {
                if usable { Button("Use existing pending review \(pending.prefix(12))") { if var d=self.draft,truth?.pendingReviewHead == d.revision.head { d.pendingReviewID=pending;self.draft=d;persist() } } }
                Button("Discard pending review…",role:.destructive) { discardTarget=pending }.disabled(busy || saveConflict || draftSaveBusy).accessibilityIdentifier("discardPendingReview")
                if let url=pr?.metadata?.webURL { Button("Open on GitHub") { ExternalLinkPolicy.open(url) }.buttonStyle(.link) }
            }.controlSize(.small)
        }.padding(10).frame(maxWidth:.infinity,alignment:.leading)
        .background((stale ? Color.orange : Color.secondary).opacity(0.08),in:RoundedRectangle(cornerRadius:10))
    }
    /// Discards the account's pending review (any head) with ONE light write. On confirmation the draft that
    /// referenced it is archived through `beginReview` (keeping the summary text), so a new review can start.
    private func discardPending(_ id:String) async {
        guard let capturedPR=pr,let captured=draft,let snapshot,let request=loadState.presentationRequest(for:capturedPR.key,available:actionAvailable) else { return }
        busy=true
        defer { loadState.publish(capturedPR.key,request:request,available:actionAvailable) { busy=false;operationRevision += 1 } }
        do {
            guard !saveConflict,!draftSaveBusy else { throw PRWriteFailure.draftChanged }
            let result=try await storage.performLightWrite(capturedPR,intent:.discardPendingReview(reviewID:id))
            guard result.state == .confirmed else {
                loadState.publish(capturedPR.key,request:request,available:actionAvailable) { status="\(prWriteStateText(result.state)) discarding the pending review. Read the provider result before retrying; nothing was resent." }
                return
            }
            var next:ReviewDraft?
            if captured.pendingReviewID == id || captured.comments.contains(where:{ $0.postedCommentID != nil }) {
                var fresh=try await storage.beginReview(captured.key,revision:PRWriteRevision(snapshot))
                fresh.summary=captured.summary
                try await storage.saveReviewDraft(fresh)
                next=fresh
            }
            loadState.publish(capturedPR.key,request:request,available:actionAvailable) {
                truth?.pendingReviewID=nil;truth?.pendingReviewHead=nil
                if let next { draft=next;summary=next.summary;commentBody="" }
                status="Discarded the pending review on GitHub."+(next == nil ? "" : " The previous draft is archived under Saved prior drafts.")
                didWrite?()
            }
        } catch { loadState.publish(capturedPR.key,request:request,available:actionAvailable) { status=error.localizedDescription } }
    }
    /// GitHub requires a body for Comment and Request changes reviews that carry no inline comments.
    private func needsSummary(_ draft:ReviewDraft) -> Bool { decision != .approve && draft.comments.isEmpty && draft.pendingReviewID == nil && summary.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
    private var completions:[String] { Array(Set(([pr?.metadata?.authorLogin].compactMap { $0 })+(pr?.metadata?.reviewers ?? [])+(pr?.metadata?.assignees ?? []))).sorted() }
    private var completionToken:String { summary.split(whereSeparator:{ $0.isWhitespace }).last.map(String.init) ?? "" }
    private var completionSuggestions:[String] {
        let token=completionToken
        if token.hasPrefix("@") { return completions.map { "@"+$0 }.filter { $0.lowercased().hasPrefix(token.lowercased()) }.prefix(6).map { $0 } }
        if token.hasPrefix("#") { return references.filter { $0.hasPrefix(token) }.prefix(6).map { $0 } }
        return []
    }
    private func complete(_ value:String) { summary.removeLast(completionToken.count);summary += value+" " }
    private func invalidateAction() { loadState.invalidate();busy=false;provisional=false;provisionalSavePending=false;draftSaveBusy=false;draftSavePending=false;pr=nil;snapshot=nil;draft=nil;truth=nil;summary="";commentBody="";login="";references=[];status="Action account unavailable. Drafts retained on disk." }
    private func load() async {
        guard !draftSaveBusy else { return }
        let request=loadState.begin();loadError=nil;busy=true
        var presented=false
        defer { if !presented,loadState.isCurrent(request) { busy=false } }
        do {
            let chosen=try await storage.detailActionPR(readPR);loadState.select(chosen.key,request:request)
            guard loadState.accepts(chosen.key,request:request,available:actionAvailable) else { return }
            guard let m=chosen.metadata else { throw PRWriteFailure.unavailable }
            // GitHub's review-state check starts now, alongside the detail read: a read-only inspection does not use
            // the command's revision (only reconciling a sent write does), so it need not wait for the detail.
            let checking=Task { [storage] in
                try await storage.inspectWrite(.init(key:chosen.key,repository:m.repositoryName,number:m.number,revision:.init(head:chosen.headRevision.rawValue,origin:m.baseRevision ?? "",target:m.baseRevision ?? ""),intent:.review(.comment,"")))
            }
            defer { checking.cancel() }
            // Everything below up to presenting is local: the sheet opens at once, also for a card whose detail was
            // never read (most of the board). The detail and GitHub's review-state check fill in behind it; the
            // spinner this replaced showed for 2–4 s on every card move.
            let cached=try await storage.cachedDetail(chosen)
            let stored=try await storage.reviewDraft(chosen.key)
            let rowRevision=PRWriteRevision(head:chosen.headRevision.rawValue,origin:m.baseRevision ?? "",target:m.baseRevision ?? "")
            let saved=stored ?? ReviewDraft(key:chosen.key,revision:cached.map(PRWriteRevision.init) ?? rowRevision)
            // The action account's row can be at a push the window hasn't applied; no draft is presented for it.
            try refuseUnshown(cached?.headSHA ?? chosen.headRevision.rawValue)
            let accountLogin=try await storage.actionLogin(chosen.key),policy=try await storage.requireAllFilesViewed()
            guard loadState.present(chosen.key,request:request,available:actionAvailable) else { return }
            pr=chosen;snapshot=cached;draft=saved;summary=saved.summary;commentBody=saved.texts["selection"] ?? "";login=accountLogin;requireViewed=policy;truth=nil;references=["#\(String(m.number))"];saveConflict=false
            provisional=stored == nil && cached == nil;provisionalSavePending=false
            status=cached == nil ? "Loading the pull request…" : "Checking the review state with GitHub…";presented=true;busy=false
            var detail:PRDetailSnapshot
            if let cached { detail=cached } else {
                detail=try await storage.detail(chosen)
                try refuseUnshown(detail.headSHA)
                guard loadState.accepts(chosen.key,request:request,available:actionAvailable) else { return }
                snapshot=detail
                if provisional {
                    if var current=draft,current.comments.isEmpty,current.pendingReviewID == nil { current.revision=PRWriteRevision(detail);draft=current }
                    provisional=false
                    if provisionalSavePending { provisionalSavePending=false;persist() }
                }
                status="Checking the review state with GitHub…"
            }
            let value=try await checking.value
            if PRWriteRevision(detail) != value.revision { detail=try await storage.detail(chosen) }
            guard PRWriteRevision(detail) == value.revision else { throw PRWriteFailure.revisionChanged }
            try refuseUnshown(detail.headSHA)
            guard loadState.accepts(chosen.key,request:request,available:actionAvailable) else { return }
            snapshot=detail;truth=value;status=nil
            if let context=try? await storage.detailSection(chosen,tab:.overview).overview,
               loadState.accepts(chosen.key,request:request,available:actionAvailable) {
                references=Array(Set(references+context.issues.map { "#\(String($0.number))" })).sorted()
            }
        } catch { if loadState.fail(request:request) { busy=false;loadError=error.localizedDescription } }
    }
    /// Reviews cover only the head the PR window shows.
    private func refuseUnshown(_ head:String) throws {
        if let refusal=PRDisplayedHead.refusal(shown:displayedHead,actual:head,acting:"reviewing") { throw PRDisplayedHead.Refusal(message:refusal) }
    }
    private func operationStatus(_ key:ProviderKey) -> some View {
        let request=loadState.presentationRequest(for:key,available:actionAvailable)
        return PRWriteStatusView(key:key,storage:storage,changeSignal:operationRevision) {
            guard let request,loadState.accepts(key,request:request,available:actionAvailable),loadState.canDisplay(key,available:actionAvailable) else { return }
            let saved=try? await storage.reviewDraft(key)
            guard loadState.accepts(key,request:request,available:actionAvailable),loadState.canDisplay(key,available:actionAvailable) else { return }
            draft=saved
        }.id(key)
    }
    private func command(_ intent:PRWriteIntent) throws -> PRWriteCommand {
        guard let pr,let m=pr.metadata,let draft else { throw PRWriteFailure.unavailable }
        return .init(key:pr.key,repository:m.repositoryName,number:m.number,revision:draft.revision,intent:intent,requireAllViewed:requireViewed)
    }
    private func persist() { persistDraft() }
    private func persistDraft() {
        guard !saveConflict else { return }
        guard !provisional else { provisionalSavePending=true;return }
        guard !draftSaveBusy else { draftSavePending=true;return }
        guard var value=draft,let request=loadState.presentationRequest(for:value.key,available:actionAvailable) else { return };let expected=value.editVersion;value.editVersion=expected+1;draft=value;draftSaveBusy=true
        Task {
            do { try await storage.saveReviewDraft(value,expectedVersion:expected);loadState.publish(value.key,request:request,available:actionAvailable) { draftSaveBusy=false;if draftSavePending { draftSavePending=false;persistDraft() } } }
            catch { loadState.publish(value.key,request:request,available:actionAvailable) { draftSaveBusy=false;saveConflict=true;status="Local edits retained; draft save conflict/failure: "+error.localizedDescription } }
        }
    }
    private func addSelection(_ selection:ReviewDraftComment) {
        guard var draft,let snapshot,snapshot.document.comparison == .pullRequest,selection.revision == PRWriteRevision(snapshot),draft.revision == PRWriteRevision(snapshot) else { status=PRWriteFailure.invalidAnchor.localizedDescription;return }
        let comment=selection.withBody(commentBody);draft.comments.append(comment);self.draft=draft;commentBody="";persist()
    }
    private func relocate(_ comment:ReviewDraftComment,to selection:ReviewDraftComment) {
        guard var draft,let snapshot,draft.pendingReviewID == nil,let index=draft.comments.firstIndex(where:{ $0.id == comment.id }),selection.revision == PRWriteRevision(snapshot) else { status="Existing provider pending reviews cannot be silently relocated.";return }
        let replacement=comment.relocated(to:selection)
        draft.priorRevisions.append(draft.revision);draft.revision=PRWriteRevision(snapshot);draft.comments[index]=replacement;self.draft=draft;persist();status="Relocated explicitly. Review remaining draft anchors before submission."
    }
    private func startNextReview(_ captured:ReviewDraft,revision:PRWriteRevision) async {
        guard let request=loadState.presentationRequest(for:captured.key,available:actionAvailable) else { return }
        busy=true
        defer { loadState.publish(captured.key,request:request,available:actionAvailable) { busy=false } }
        do {
            let archived=try await storage.beginReview(captured.key,revision:revision)
            loadState.publish(captured.key,request:request,available:actionAvailable) { draft=archived;summary="";commentBody="" }
        } catch { loadState.publish(captured.key,request:request,available:actionAvailable) { status=error.localizedDescription } }
    }
    private func run(_ intent:PRWriteIntent,pr:PullRequest,draft:ReviewDraft,request:UUID,requireViewed:Bool) async throws -> PRWriteOperation {
        guard let metadata=pr.metadata else { throw PRWriteFailure.unavailable }
        let command=PRWriteCommand(key:pr.key,repository:metadata.repositoryName,number:metadata.number,revision:draft.revision,intent:intent,requireAllViewed:requireViewed)
        defer { loadState.publish(pr.key,request:request,available:actionAvailable) { operationRevision += 1 } }
        let result=try await storage.performWrite(command)
        guard result.state == .confirmed else { throw PRWriteFailure.uncertain }
        loadState.publish(pr.key,request:request,available:actionAvailable) { didWrite?() }
        return result
    }
    private func refreshDraft(_ key:ProviderKey,request:UUID) async throws {
        guard let saved=try await storage.reviewDraft(key) else { return }
        guard loadState.accepts(key,request:request,available:actionAvailable),loadState.canDisplay(key,available:actionAvailable) else { return }
        if var local=draft,local.editVersion > saved.editVersion {
            local.pendingReviewID=local.pendingReviewID ?? saved.pendingReviewID
            for index in local.comments.indices {
                if let confirmed=saved.comments.first(where:{ $0.id == local.comments[index].id }),confirmed.postedCommentID != nil { local.comments[index].postedCommentID=confirmed.postedCommentID;local.comments[index].postedBody=confirmed.postedBody }
            }
            draft=local;try await storage.saveReviewDraft(local)
        } else { loadState.publish(key,request:request,available:actionAvailable) { draft=saved;summary=saved.summary } }
    }
    private func submit() async {
        guard let captured=draft,let capturedPR=pr,let request=loadState.presentationRequest(for:captured.key,available:actionAvailable),!stale else { return }
        if let refusal=headRefusal(captured) { status=refusal;return }
        let submittedSummary=summary,submittedDecision=decision,submittedViewed=requireViewed
        busy=true
        defer { loadState.publish(captured.key,request:request,available:actionAvailable) { busy=false;operationRevision += 1 } }
        do {
            guard !saveConflict,!draftSaveBusy else { throw PRWriteFailure.draftChanged }
            try await storage.saveReviewDraft(captured)
            var pending=captured.pendingReviewID
            if !captured.comments.isEmpty {
                if pending == nil {
                    let result=try await run(.createPending(submittedSummary),pr:capturedPR,draft:captured,request:request,requireViewed:submittedViewed)
                    guard let id=result.providerIDs.first else { throw PRWriteFailure.uncertain }
                    pending=id;try await refreshDraft(captured.key,request:request)
                }
                for comment in captured.comments {
                    if let id=comment.postedCommentID {
                        if comment.hasUnsentEdit { _ = try await run(.editComment(id:id,kind:.review,body:comment.body),pr:capturedPR,draft:captured,request:request,requireViewed:submittedViewed);try await refreshDraft(captured.key,request:request) }
                    } else { _ = try await run(.thread(comment,pendingReviewID:pending),pr:capturedPR,draft:captured,request:request,requireViewed:submittedViewed);try await refreshDraft(captured.key,request:request) }
                }
            }
            let intent:PRWriteIntent=pending.map { .submitPending(id:$0,decision:submittedDecision,summary:submittedSummary) } ?? .review(submittedDecision,submittedSummary)
            _ = try await run(intent,pr:capturedPR,draft:captured,request:request,requireViewed:submittedViewed)
            // Provider-confirmed: remember the head this account reviewed for "Changes since your review": the draft's
            // head, which is the head the window showed (never a newer head the action row had reached meanwhile).
            try? await storage.recordReviewedHead(capturedPR.key,head:captured.revision.head)
            try await refreshDraft(captured.key,request:request)
            loadState.publish(captured.key,request:request,available:actionAvailable) {
                status="Provider confirmed the captured review. Newer local text and original anchors remain saved."
                AccessibilityNotification.Announcement(Self.confirmation(submittedDecision)).post()
                dismiss()
            }
        } catch {
            loadState.publish(captured.key,request:request,available:actionAvailable) {
                status=error.localizedDescription
                AccessibilityNotification.Announcement(error as? PRWriteFailure == .uncertain ? "\(Self.noun(submittedDecision)) outcome unknown. Nothing was resent." : "\(Self.noun(submittedDecision)) not submitted").post()
            }
        }
    }
    private func conversation() async {
        guard let captured=draft,let capturedPR=pr,let request=loadState.presentationRequest(for:captured.key,available:actionAvailable) else { return }
        let body=summary,submittedViewed=requireViewed;busy=true
        defer { loadState.publish(captured.key,request:request,available:actionAvailable) { busy=false;operationRevision += 1 } }
        do {
            guard !saveConflict,!draftSaveBusy else { throw PRWriteFailure.draftChanged }
            try await storage.saveReviewDraft(captured)
            _ = try await run(.conversation(body),pr:capturedPR,draft:captured,request:request,requireViewed:submittedViewed)
            loadState.publish(captured.key,request:request,available:actionAvailable) {
                status="Provider confirmed conversation comment."
                // The posted text leaves the draft so reopening can't post it twice; newer typing stays.
                if summary == body,var d=draft { summary="";d.summary="";draft=d;persist() }
                AccessibilityNotification.Announcement("Comment posted").post()
                dismiss()
            }
        } catch {
            loadState.publish(captured.key,request:request,available:actionAvailable) {
                status=error.localizedDescription
                AccessibilityNotification.Announcement(error as? PRWriteFailure == .uncertain ? "Comment outcome unknown. Nothing was resent." : "Comment not posted").post()
            }
        }
    }
    static func noun(_ decision:ReviewDecision) -> String {
        switch decision { case .approve:"Approval";case .requestChanges:"Change request";case .comment:"Review" }
    }
    static func confirmation(_ decision:ReviewDecision) -> String {
        switch decision { case .approve:"Approved";case .requestChanges:"Changes requested";case .comment:"Review submitted" }
    }
}
