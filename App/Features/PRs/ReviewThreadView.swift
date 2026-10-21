import MergeProCore
import SwiftUI

/// Failed/partial thread reads stay visible; edits and replies retain their text in SQLite.
struct ReviewThreadView:View {
    let readPR:PullRequest
    let storage:SetupStorage
    var workspace:PRWorkspaceModel? = nil
    @State private var loadState=PRActionLoadState()
    @State private var operationRevision=0
    @State private var loadError:String?
    private var actionAvailable:Bool { loadState.key.map { workspace == nil || workspace?.cached($0) != nil } ?? true }
    var didWrite:(@MainActor () -> Void)?
    @State private var pr:PullRequest?
    @State private var snapshot:PRDetailSnapshot?
    @State private var truth:PRWriteTruth?
    @State private var draft:ReviewDraft?
    @State private var saveConflict=false
    @State private var draftSaveBusy=false
    @State private var draftSavePending=false
    @State private var login=""
    @State private var status:String?
    @State private var busy=false
    @State private var editID:String?
    @State private var text=""
    @State private var replyThread:String?
    @State private var attachPending=true
    @State private var unresolvedOnly=false
    @FocusState private var editorFocused:Bool
    var body:some View {
        Group {
            if actionAvailable {
                if loadState.canDisplay(pr?.key,available:true) { content }
                else { replacement }
            }
            else { ContentUnavailableView { Label("Action account unavailable",systemImage:"lock") } description: { Text("Reconnect the selected account. Drafts remain on disk.") } actions: { Button("Try Again") { Task { await load() } } } }
        }.onChange(of:actionAvailable) { if !actionAvailable { invalidateAction() } }
        .task { await load() }
    }
    private var replacement:some View {
        VStack(spacing:12) {
            if busy { ProgressView("Reading selected action account…") }
            else { Text(loadError ?? "Selected account data unavailable") }
            Button("Try Again") { Task { await load() } }.disabled(busy || draftSaveBusy)
        }.padding()
    }
    private var content:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("Discussion").font(.headline);Text("as \(login)").font(.caption).foregroundStyle(.secondary);Spacer()
                Toggle("Unresolved only",isOn:$unresolvedOnly).toggleStyle(.checkbox).controlSize(.small).accessibilityIdentifier("unresolvedThreadsOnly")
                Button("Reload saved draft and permissions") { Task { await load() } }.disabled(busy || draftSaveBusy)
            }
            if saveConflict { Text("Another editor saved this draft. Local text remains here; copy or resolve it before explicitly reloading the saved draft.").foregroundStyle(.orange) }
            if let status { Text(status).foregroundStyle(.secondary).textSelection(.enabled) }
            if let pr { operationStatus(pr.key) }
            if let truth {
                if !truth.threadsComplete { Text("Partial provider thread/comment read. Missing entries and absence cannot be confirmed. Open the exact thread on GitHub for unavailable replies.").foregroundStyle(.orange) }
                if !unresolvedOnly { ForEach(truth.conversation) { comment in commentRow(comment) } }
                let threads=truth.threads.filter { !unresolvedOnly || !$0.resolved }
                if unresolvedOnly,threads.isEmpty { Text(truth.threadsComplete ? "No unresolved threads." : "No unresolved threads in this partial read.").foregroundStyle(.secondary) }
                ForEach(threads) { thread in
                    GroupBox {
                        VStack(alignment:.leading,spacing:8) {
                            HStack { Text(thread.path);if thread.outdated { Text("Outdated · original coordinates preserved").foregroundStyle(.orange) };Spacer();Label(thread.resolved ? "Resolved" : "Unresolved",systemImage:thread.resolved ? "checkmark.circle.fill" : "circle").foregroundStyle(.secondary) }
                            ForEach(thread.comments) { comment in commentRow(comment) }
                            HStack { Button("Reply") { replyThread=thread.id;editID=nil;text=draft?.texts["reply:"+thread.id] ?? "";editorFocused=true }.disabled(!thread.canReply);Button(thread.resolved ? "Unresolve" : "Resolve") { Task { await send(.resolve(threadID:thread.id,resolved:!thread.resolved)) } }.disabled(thread.resolved ? !thread.canUnresolve : !thread.canResolve) }
                            // The reply editor sits under the thread it answers.
                            if replyThread == thread.id,editID == nil { editor(truth) }
                            if !thread.complete { Text("This thread has more than 100 comments; this native read is partial.").font(.caption);if let url=thread.comments.first?.url { Button("Open full thread") { ExternalLinkPolicy.open(url) }.buttonStyle(.link) } }
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }
                }
            } else if busy { ProgressView("Reading current account permissions…") }
            else { Text("Thread permissions unavailable. Retry the provider read.").foregroundStyle(.secondary) }
        }.padding(12).onChange(of:text) { saveText() }
    }
    /// Reply or own-comment edit, shown under the thread or comment it belongs to. ⌘Return sends.
    private func editor(_ truth:PRWriteTruth) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text(editID == nil ? "Reply" : "Edit your comment").font(.headline)
            TextEditor(text:$text).frame(height:120).border(.separator).focused($editorFocused).accessibilityLabel(editID == nil ? "Reply" : "Edited comment")
            if !text.isEmpty { MarkdownView(source:text,webURL:pr?.metadata?.webURL) }
            if replyThread != nil,truth.pendingReviewID != nil { Toggle("Attach reply to current pending review",isOn:$attachPending) }
            HStack { Button("Cancel editor") { editID=nil;replyThread=nil };Spacer();Button("Send explicit change") { Task { await sendText() } }.keyboardShortcut(.return,modifiers:.command).disabled(busy || saveConflict || draftSaveBusy || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).help("Send (⌘Return)") }
        }.padding(8).background(Color.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:8))
    }
    private func operationStatus(_ key:ProviderKey) -> some View {
        let request=loadState.presentationRequest(for:key,available:actionAvailable)
        return PRWriteStatusView(key:key,storage:storage,changeSignal:operationRevision) {
            guard let request,!busy,loadState.accepts(key,request:request,available:actionAvailable),loadState.canDisplay(key,available:actionAvailable) else { return }
            await load()
        }.id(key)
    }
    private func commentRow(_ comment:PRWritableComment) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Text(comment.author ?? "Unknown author").font(.caption.bold());MarkdownView(source:comment.body,webURL:comment.url)
            if let coordinates=comment.coordinates { Text("Original reviewed commit \(coordinates.original.reviewedHeadSHA?.prefix(8) ?? "unknown") · original lines \(coordinates.original.startLine ?? coordinates.original.endLine ?? 0)–\(coordinates.original.endLine ?? 0) · current line \(coordinates.current.endLine.map(String.init) ?? "unavailable")").font(.caption) }
            HStack {
                if comment.own { Button("Edit") { editID=comment.id;replyThread=nil;text=draft?.texts["edit:"+comment.id] ?? comment.body;editorFocused=true }.disabled(!comment.canEdit);Menu("Delete own comment") { Button("Confirm deletion",role:.destructive) { Task { await send(.deleteComment(id:comment.id,kind:comment.kind)) } } }.disabled(!comment.canDelete) }
                Menu("Reaction") { ForEach(PRReaction.allCases,id:\.self) { value in Button("Add \(PRDetailText.reaction(value))") { Task { await send(.reaction(subjectID:comment.id,reaction:value,remove:false)) } };Button("Remove \(PRDetailText.reaction(value))") { Task { await send(.reaction(subjectID:comment.id,reaction:value,remove:true)) } } } }.disabled(!comment.canReact)
                Menu("Hide") { if comment.minimized { Button("Unhide") { Task { await send(.moderate(subjectID:comment.id,classifier:nil)) } } } else { ForEach(PRDetailText.moderationReasons,id:\.self) { value in Button("Hide as \(PRDetailText.moderationReason(value).lowercased())") { Task { await send(.moderate(subjectID:comment.id,classifier:value)) } } } } }.disabled(comment.minimized ? !comment.canUnminimize : !comment.canModerate).help("Minimize this comment on GitHub")
                if let url=comment.url { Button("Open on GitHub") { ExternalLinkPolicy.open(url) };Button("Apply suggestion / attach file on GitHub") { ExternalLinkPolicy.open(url) } }
            }.disabled(busy)
            if editID == comment.id,let truth { editor(truth) }
        }.padding(8)
    }
    private func invalidateAction() { loadState.invalidate();busy=false;draftSaveBusy=false;draftSavePending=false;pr=nil;snapshot=nil;truth=nil;draft=nil;login="";editID=nil;replyThread=nil;text="";status="Action account unavailable. Drafts retained on disk." }
    private func load() async {
        guard !draftSaveBusy else { return }
        let request=loadState.begin();loadError=nil;busy=true;defer { if loadState.isCurrent(request) { busy=false } }
        do {
            let chosen=try await storage.detailActionPR(readPR);loadState.select(chosen.key,request:request)
            guard loadState.accepts(chosen.key,request:request,available:actionAvailable) else { return }
            // The window revalidated moments ago; reuse that read unless it is older than two minutes.
            let detail=try await storage.detail(chosen,maxAge:120)
            guard let m=chosen.metadata else { throw PRWriteFailure.unavailable }
            let command=PRWriteCommand(key:chosen.key,repository:m.repositoryName,number:m.number,revision:PRWriteRevision(detail),intent:.conversation(""))
            let value=try await storage.inspectWrite(command),accountLogin=try await storage.actionLogin(chosen.key),saved=try await storage.reviewDraft(chosen.key) ?? ReviewDraft(key:chosen.key,revision:PRWriteRevision(detail))
            guard loadState.accepts(chosen.key,request:request,available:actionAvailable) else { return }
            guard loadState.present(chosen.key,request:request,available:actionAvailable) else { return }
            if pr?.key != chosen.key { editID=nil;replyThread=nil;text="";attachPending=true }
            else if let editorKey=editID.map({ "edit:"+$0 }) ?? replyThread.map({ "reply:"+$0 }) { text=saved.texts[editorKey] ?? "" }
            pr=chosen;snapshot=detail;truth=value;login=accountLogin;draft=saved;saveConflict=false;status=nil
        } catch { if loadState.fail(request:request) { busy=false;loadError=error.localizedDescription } }
    }
    private func saveText() {
        guard var draft else { return };let key=editID.map { "edit:"+$0 } ?? replyThread.map { "reply:"+$0 };guard let key else { return };draft.texts[key]=text;self.draft=draft
        persistDraft()
    }
    private func persistDraft() {
        guard !saveConflict else { return }
        guard !draftSaveBusy else { draftSavePending=true;return }
        guard var value=draft,let request=loadState.presentationRequest(for:value.key,available:actionAvailable) else { return };let expected=value.editVersion;value.editVersion=expected+1;draft=value;draftSaveBusy=true
        Task {
            do { try await storage.saveReviewDraft(value,expectedVersion:expected);loadState.publish(value.key,request:request,available:actionAvailable) { draftSaveBusy=false;if draftSavePending { draftSavePending=false;persistDraft() } } }
            catch { loadState.publish(value.key,request:request,available:actionAvailable) { draftSaveBusy=false;saveConflict=true;status="Local edits retained; draft save conflict/failure: "+error.localizedDescription } }
        }
    }
    private func sendText() async {
        if let id=editID,let comment=(truth?.conversation ?? []).first(where:{ $0.id == id }) ?? truth?.threads.flatMap(\.comments).first(where:{ $0.id == id }) { await send(.editComment(id:id,kind:comment.kind,body:text)) }
        else if let id=replyThread { await send(.reply(threadID:id,body:text,pendingReviewID:attachPending ? truth?.pendingReviewID : nil)) }
    }
    private func send(_ intent:PRWriteIntent) async {
        guard let capturedPR=pr,let m=capturedPR.metadata,let snapshot,let request=loadState.presentationRequest(for:capturedPR.key,available:actionAvailable) else { return }
        let capturedDraft=draft,capturedEdit=editID,capturedReply=replyThread,capturedText=text
        let command=PRWriteCommand(key:capturedPR.key,repository:m.repositoryName,number:m.number,revision:PRWriteRevision(snapshot),intent:intent)
        busy=true
        defer { loadState.publish(capturedPR.key,request:request,available:actionAvailable) { busy=false;operationRevision += 1 } }
        do {
            guard !saveConflict,!draftSaveBusy else { throw PRWriteFailure.draftChanged }
            if let capturedDraft { try await storage.saveReviewDraft(capturedDraft) }
            let result=try await storage.performWrite(command)
            loadState.publish(capturedPR.key,request:request,available:actionAvailable) {
                status=result.state == .confirmed ? "Provider confirmed change." : "\(prWriteStateText(result.state)). Read the provider result before retrying; nothing was resent."
                if result.state == .confirmed {
                    if editID == capturedEdit,replyThread == capturedReply,text == capturedText { editID=nil;replyThread=nil }
                    didWrite?()
                }
            }
        } catch { loadState.publish(capturedPR.key,request:request,available:actionAvailable) { status=error.localizedDescription } }
    }
}
