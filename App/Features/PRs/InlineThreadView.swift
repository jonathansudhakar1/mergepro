import AppKit
import MergeProCore
import SwiftUI

/// One per PR window: the action account's writable review threads at the window's head, read once
/// (one provider read) when a file with threads is shown, so the diff can show thread bubbles at their
/// lines with Reply and Resolve. Writes go through the write ledger; an unknown outcome is reported and
/// never resent. Reply text is kept in the review draft (`reply:<thread>`), shared with Conversation.
@MainActor @Observable final class PRThreadModel {
    let readPR:PullRequest
    let storage:SetupStorage
    private(set) var truth:PRWriteTruth?
    private(set) var loading=false
    private(set) var error:String?
    private(set) var busy:Set<String>=[]
    /// The latest unconfirmed or failed outcome per thread; a confirmed write clears it.
    var messages:[String:String]=[:]
    /// Bumped after every write so the durable status view rereads operations.
    private(set) var operationRevision=0
    private(set) var actionPR:PullRequest?
    /// The reviewer's open/closed choice per thread, kept while switching files; unset threads open while unresolved.
    private(set) var expansion:[String:Bool]=[:]
    @ObservationIgnored private var snapshot:PRDetailSnapshot?
    /// Thread reads: a reset or newer read drops an older read's result, and a write's result when its read was replaced.
    @ObservationIgnored private let reads=LatestRequest()
    /// Per thread, the save of reply text handed over by an editor that went away (`flushReplyText`).
    @ObservationIgnored private var flushes:[String:Task<Void,Never>]=[:]
    init(readPR:PullRequest,storage:SetupStorage) { self.readPR=readPR;self.storage=storage }
    func loadIfNeeded() async { guard truth == nil,error == nil,!loading else { return };await load() }
    func load() async {
        let token=reads.begin();loading=true;error=nil
        defer { if reads.isCurrent(token) { loading=false } }
        do {
            let chosen=try await storage.detailActionPR(readPR)
            // The window revalidated moments ago; reuse that read unless it is older than two minutes.
            let detail=try await storage.detail(chosen,maxAge:120)
            guard let m=chosen.metadata else { throw PRWriteFailure.unavailable }
            let value=try await storage.inspectWrite(PRWriteCommand(key:chosen.key,repository:m.repositoryName,number:m.number,revision:PRWriteRevision(detail),intent:.conversation("")))
            guard reads.isCurrent(token) else { return }
            actionPR=chosen;snapshot=detail;truth=value
        } catch { if reads.isCurrent(token),!(error is CancellationError) { self.error=prDetailErrorMessage(error) } }
    }
    /// Drops every account-bound value, e.g. when the action account changes. Open/closed choices are kept.
    func reset() { reads.cancel();truth=nil;snapshot=nil;actionPR=nil;error=nil;loading=false;busy=[];messages=[:] }
    func threads(for file:DiffFile) -> [PRWritableThread] {
        func order(_ thread:PRWritableThread) -> Int { thread.outdated ? .max : thread.comments.first?.coordinates?.current.endLine ?? .max }
        return (truth?.threads ?? []).filter { $0.path == file.path || $0.path == file.previousPath }
            .sorted { (order($0),$0.id) < (order($1),$1.id) }
    }
    /// Where a thread sits in the PR diff of `head`, from the provider's current coordinates; nil when outdated, unmapped
    /// or anchored to another head. The thread read follows the action account's row, which can be at a push the window
    /// hasn't applied: those line numbers would land on the wrong rows, so such threads stay in the overview.
    nonisolated static func line(_ thread:PRWritableThread,head:String) -> (side:DiffSide,start:Int,end:Int)? {
        line(outdated:thread.outdated,coordinates:thread.comments.first?.coordinates,head:head)
    }
    nonisolated static func line(outdated:Bool,coordinates:PRCommentCoordinates?,head:String) -> (side:DiffSide,start:Int,end:Int)? {
        guard !outdated,let current=coordinates?.current,current.reviewedHeadSHA == head,let end=current.endLine,end > 0,
              let side=current.side.flatMap(DiffSide.init(rawValue:)) else { return nil }
        return (side,min(current.startLine ?? end,end),end)
    }
    func isExpanded(_ thread:PRWritableThread) -> Bool { expansion[thread.id] ?? !thread.resolved }
    func setExpanded(_ ids:[String],_ value:Bool) { for id in ids where expansion[id] != value { expansion[id]=value } }
    /// A gutter click on commented lines: opens their threads if any is closed, otherwise closes them all.
    func toggle(_ threads:[PRWritableThread]) {
        guard !threads.isEmpty else { return }
        setExpanded(threads.map(\.id),threads.contains { !isExpanded($0) })
    }
    /// The account's pending review on this head, which a reply can join.
    var pendingReviewID:String? { truth.flatMap { $0.pendingReviewHead == $0.revision.head ? $0.pendingReviewID : nil } }
    func replyText(_ thread:String) async -> String {
        // A closing editor may still be saving this thread's text; read what it saves, not the older text.
        await flushes[thread]?.value
        guard let key=actionPR?.key else { return "" }
        return (try? await storage.reviewDraft(key))?.texts["reply:"+thread] ?? ""
    }
    /// Reply text a closing editor hands over (its debounced save was still waiting), saved in order per thread.
    func flushReplyText(_ text:String,thread:String) {
        let previous=flushes[thread]
        flushes[thread]=Task { await previous?.value;await saveReplyText(text,thread:thread) }
    }
    /// Saves reply text into the freshly read draft so other editors' fields are never overwritten.
    func saveReplyText(_ text:String,thread:String) async {
        guard let actionPR,let snapshot else { return }
        do {
            var draft=try await storage.reviewDraft(actionPR.key) ?? ReviewDraft(key:actionPR.key,revision:PRWriteRevision(snapshot))
            let value:String?=text.isEmpty ? nil : text
            guard draft.texts["reply:"+thread] != value else { return }
            let expected=draft.editVersion;draft.texts["reply:"+thread]=value;draft.editVersion=expected+1
            try await storage.saveReviewDraft(draft,expectedVersion:expected)
        } catch { messages[thread]="Reply text is still here but wasn't saved: "+error.localizedDescription }
    }
    @discardableResult func reply(_ thread:PRWritableThread,body:String,attachPending:Bool) async -> Bool {
        await send(.reply(threadID:thread.id,body:body,pendingReviewID:attachPending ? pendingReviewID : nil),thread:thread.id)
    }
    @discardableResult func setResolved(_ thread:PRWritableThread,_ resolved:Bool) async -> Bool {
        await send(.resolve(threadID:thread.id,resolved:resolved),thread:thread.id)
    }
    private func send(_ intent:PRWriteIntent,thread:String) async -> Bool {
        guard let actionPR,let m=actionPR.metadata,let snapshot else { messages[thread]="Thread actions need the action account. Reload threads.";return false }
        let token=reads.latest
        busy.insert(thread);defer { busy.remove(thread) }
        do {
            let result=try await storage.performWrite(PRWriteCommand(key:actionPR.key,repository:m.repositoryName,number:m.number,revision:PRWriteRevision(snapshot),intent:intent))
            guard reads.isCurrent(token) else { return false }
            operationRevision += 1
            if result.state == .confirmed { messages[thread]=nil;await load();return true }
            messages[thread]=prWriteStateText(result.state)+". Read the provider result before retrying; nothing was resent."
        } catch { if reads.isCurrent(token) { operationRevision += 1;messages[thread]=prDetailErrorMessage(error) } }
        return false
    }
}

/// Inline threads sit below the last line they cover. The unified pane and both split panes carry one row per displayed
/// diff line in the same order, so one row index places a thread in every layout. The thread's own side supplies the
/// line numbers: an old-side comment on an unchanged line has no old number in the unified pane.
enum InlineThreadPlacement {
    struct Line:Equatable { let id:String;let side:DiffSide;let start:Int;let end:Int }
    /// Row index → lines anchored there (input order kept); lines outside the displayed diff are left out.
    static func rows(_ lines:[Line],left:DiffPresentation,right:DiffPresentation) -> [Int:[Line]] {
        let index=rowIndex(left:left,right:right)
        var result:[Int:[Line]]=[:]
        for line in lines { if let row=index[line.side]?[line.end] { result[row,default:[]].append(line) } }
        return result
    }
    /// Lines whose range includes the diff line shown at `row` (on either side), e.g. a gutter click there.
    static func lines(_ lines:[Line],coveringRow row:Int,left:DiffPresentation,right:DiffPresentation) -> [Line] {
        let numbers:[DiffSide:Int?]=[.left:left.rows.indices.contains(row) ? left.rows[row].line : nil,.right:right.rows.indices.contains(row) ? right.rows[row].line : nil]
        return lines.filter { line in (numbers[line.side] ?? nil).map { line.start <= $0 && $0 <= line.end } ?? false }
    }
    /// A commented row's identity across re-presentations: its new line number, or its old one for a removed line.
    /// Context expansion and hidden whitespace move rows, not line numbers, and another thread on the same line keeps
    /// it, so the hosted bubbles there (and a reply being typed in one) survive all three.
    static func key(row:Int,left:DiffPresentation,right:DiffPresentation) -> String {
        if right.rows.indices.contains(row),let line=right.rows[row].line { return "line:R\(line)" }
        if left.rows.indices.contains(row),let line=left.rows[row].line { return "line:L\(line)" }
        return "row:\(row)"
    }
    /// The row whose text contains `location` in a pane (a gutter mark's range starts inside its row).
    static func row(at location:Int,in presentation:DiffPresentation) -> Int? {
        presentation.rows.lastIndex { $0.contentRange.location <= location }
    }
    private static func rowIndex(left:DiffPresentation,right:DiffPresentation) -> [DiffSide:[Int:Int]] {
        var index:[DiffSide:[Int:Int]]=[.left:[:],.right:[:]]
        for (side,presentation) in [(DiffSide.left,left),(.right,right)] {
            for (row,value) in presentation.rows.enumerated() { if let line=value.line,index[side]?[line] == nil { index[side]?[line]=row } }
        }
        return index
    }
}

/// One review thread: a one-line summary when closed; comments, Reply and Resolve when open. Writes go through
/// `PRThreadModel` (the write ledger); reply text is kept in the review draft while typing.
struct InlineThreadBubble:View {
    let model:PRThreadModel
    let thread:PRWritableThread
    /// The head of the diff shown; a thread anchored to another head has no line here.
    let head:String
    var highlighted=false
    /// Scrolls the diff to the thread's line (the overview); inline bubbles already sit below it.
    var jump:((DiffSide,Int) -> Void)? = nil
    var changed:() -> Void = {}
    @State private var replying=false
    @State private var text=""
    @State private var attachPending=true
    @State private var saveTask:Task<Void,Never>?
    @FocusState private var replyFocused:Bool
    private var line:(side:DiffSide,start:Int,end:Int)? { PRThreadModel.line(thread,head:head) }
    private var unplacedText:String { thread.outdated ? "Outdated" : "Not in this diff" }
    private var lineText:String { line.map { $0.start == $0.end ? "Line \($0.end)" : "Lines \($0.start)–\($0.end)" } ?? unplacedText }
    private var summary:String {
        let first=thread.comments.first
        let body=first.map { $0.minimized ? "Hidden comment" : $0.body.split(whereSeparator:\.isNewline).first.map(String.init) ?? "" } ?? ""
        return [first?.author ?? "Unknown author",body].filter { !$0.isEmpty }.joined(separator:": ")
    }
    var body:some View {
        let expanded=model.isExpanded(thread),busy=model.busy.contains(thread.id)
        VStack(alignment:.leading,spacing:6) {
            HStack(spacing:6) {
                Button { model.setExpanded([thread.id],!expanded) } label: {
                    Image(systemName:expanded ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold)).frame(width:14)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(expanded ? "Collapse thread" : "Expand thread").help(expanded ? "Collapse thread" : "Expand thread")
                if let jump { InlineThreadLineButton(line:line,jump:jump,unplaced:unplacedText) }
                else { Label(lineText,systemImage:"text.bubble.fill").font(.caption.weight(.semibold)).foregroundStyle(DesignTokens.cobalt) }
                if !expanded {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    if thread.comments.count > 1 { Text("+\(thread.comments.count-1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                }
                Spacer(minLength:4)
                Label(thread.resolved ? "Resolved" : "Unresolved",systemImage:thread.resolved ? "checkmark.circle.fill" : "circle")
                    .font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            }
            if expanded {
                if thread.outdated { Text("Outdated · original coordinates kept").font(.caption2).foregroundStyle(.secondary) }
                ForEach(thread.comments) { comment in
                    VStack(alignment:.leading,spacing:2) {
                        Text(comment.author ?? "Unknown author").font(.caption.bold())
                        if comment.minimized { Text("Hidden comment").font(.caption).foregroundStyle(.secondary) }
                        else { MarkdownView(source:comment.body,webURL:comment.url) }
                    }
                }
                if !thread.complete,let url=thread.comments.first?.url {
                    Button("More replies on GitHub") { ExternalLinkPolicy.open(url) }.buttonStyle(.link).font(.caption)
                }
                if replying { replyEditor(busy:busy) }
                else {
                    HStack(spacing:8) {
                        Button("Reply") { Task { await beginReply() } }.disabled(!thread.canReply || busy)
                        Button(thread.resolved ? "Unresolve" : "Resolve") { Task { if await model.setResolved(thread,!thread.resolved) { announce(thread.resolved ? "Thread unresolved" : "Thread resolved");changed() } } }
                            .disabled(busy || (thread.resolved ? !thread.canUnresolve : !thread.canResolve))
                        if busy { ProgressView().controlSize(.mini) }
                    }.controlSize(.small)
                }
            }
            if let message=model.messages[thread.id] { Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
        .padding(10).frame(maxWidth:.infinity,alignment:.leading)
        .background(highlighted ? DesignTokens.cobalt.opacity(0.12) : Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:10))
        .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(highlighted ? DesignTokens.cobalt.opacity(0.5) : Color(nsColor:.separatorColor).opacity(0.7),lineWidth:1))
        .accessibilityElement(children:.contain)
        .accessibilityLabel("Review thread, \(lineText.lowercased()), \(thread.resolved ? "resolved" : "unresolved")")
        // The host can go away with typing still unsaved (file switch, re-presentation): hand the text to the model.
        .onDisappear { flushSave() }
    }
    private func replyEditor(busy:Bool) -> some View {
        VStack(alignment:.leading,spacing:6) {
            TextEditor(text:$text).font(.callout).frame(height:80).border(.separator).focused($replyFocused).accessibilityLabel("Reply")
                .onChange(of:text) { scheduleSave() }
            if model.pendingReviewID != nil { Toggle("Add to my pending review",isOn:$attachPending).toggleStyle(.checkbox).font(.caption) }
            HStack {
                // Every open editor (inline rows and the overview, each its own hosting view) would claim Escape and
                // ⌘Return window-wide, so only the focused one binds them: the shortcut sends the text being typed.
                Button("Cancel") { replying=false }.keyboardShortcut(replyFocused ? .cancelAction : nil)
                Spacer()
                Button("Reply") { Task { await send() } }.buttonStyle(.borderedProminent).keyboardShortcut(replyFocused ? KeyboardShortcut(.return,modifiers:.command) : nil)
                    .disabled(busy || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).help("Send reply (⌘Return)")
            }.controlSize(.small)
        }
    }
    private func beginReply() async {
        replying=true;attachPending=true;text=await model.replyText(thread.id);replyFocused=true
    }
    private func scheduleSave() {
        saveTask?.cancel()
        let value=text,id=thread.id
        saveTask=Task { try? await Task.sleep(for:.milliseconds(400));guard !Task.isCancelled else { return };await model.saveReplyText(value,thread:id) }
    }
    /// Saves now what the debounce would have saved; an unchanged text is a no-op in `saveReplyText`.
    private func flushSave() {
        guard let pending=saveTask else { return }
        pending.cancel();saveTask=nil
        model.flushReplyText(text,thread:thread.id)
    }
    private func send() async {
        let body=text
        saveTask?.cancel();await model.saveReplyText(body,thread:thread.id)
        if await model.reply(thread,body:body,attachPending:attachPending) {
            await model.saveReplyText("",thread:thread.id)
            if replying,text == body { replying=false;text="" }
            announce("Reply posted");changed()
        }
    }
    private func announce(_ message:String) { AccessibilityNotification.Announcement(message).post() }
}

/// "Line 12" / "Lines 3–5" that scrolls the diff there; an outdated thread has no line to show.
struct InlineThreadLineButton:View {
    let line:(side:DiffSide,start:Int,end:Int)?
    let jump:(DiffSide,Int) -> Void
    /// What a thread without a line here says: outdated, or anchored to another head.
    var unplaced="Outdated"
    var body:some View {
        Button { if let line { jump(line.side,line.start) } } label: {
            Label(line.map { $0.start == $0.end ? "Line \($0.end)" : "Lines \($0.start)–\($0.end)" } ?? unplaced,systemImage:"text.bubble.fill")
        }.buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(line == nil ? Color.secondary : DesignTokens.cobalt)
            .disabled(line == nil).help(line == nil ? "This thread's lines aren't in the diff shown." : "Show this line in the diff")
    }
}

/// A provider comment shown read-only while writable threads are unavailable (no action account, or still reading).
struct InlineCommentBubble:View {
    let event:PRDetailEvent
    var line:(side:DiffSide,start:Int,end:Int)?
    var jump:((DiffSide,Int) -> Void)? = nil
    var body:some View {
        VStack(alignment:.leading,spacing:4) {
            if let jump { InlineThreadLineButton(line:line,jump:jump) }
            Text(event.title).font(.caption.weight(.medium))
            MarkdownView(source:event.body,webURL:event.url)
        }.padding(10).frame(maxWidth:.infinity,alignment:.leading)
        .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:10))
        .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(Color(nsColor:.separatorColor).opacity(0.7),lineWidth:1))
        .accessibilityElement(children:.contain)
    }
}

/// The threads below one diff line inside the code, or the read-only provider comments there before threads load.
struct InlineThreadRow:View {
    let model:PRThreadModel
    let threads:[PRWritableThread]
    let head:String
    var comments:[PRDetailEvent]=[]
    var changed:() -> Void = {}
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            // Keyed by thread: a thread added on this line leaves the others' open editors and typing as they are.
            ForEach(threads) { thread in InlineThreadBubble(model:model,thread:thread,head:head,changed:changed) }
            ForEach(comments) { event in InlineCommentBubble(event:event) }
        }
        .frame(maxWidth:720,alignment:.leading)
        .padding(.vertical,6).padding(.trailing,8)
        .accessibilityElement(children:.contain).accessibilityLabel(threads.isEmpty ? "Review comments" : "Review threads")
    }
}

/// Optional overview beside the diff: every thread on the file in line order, including outdated ones that have no
/// line to sit under. Selecting a line highlights its threads; a line button scrolls the diff there. Without the
/// action account the provider comments are still shown read-only.
struct InlineThreadRail:View {
    let model:PRThreadModel
    let file:DiffFile
    /// Provider comment events mapped onto this file (read-only fallback while threads are unavailable).
    let comments:[PRDetailEvent]
    let document:DiffDocument
    let selection:ReviewAnchor?
    let jump:(DiffSide,Int) -> Void
    var changed:() -> Void = {}
    @State private var unresolvedOnly=false
    private var threads:[PRWritableThread] { model.threads(for:file).filter { !unresolvedOnly || !$0.resolved } }
    private var selectedThread:String? {
        guard let selection else { return nil }
        return threads.first { thread in
            guard let line=PRThreadModel.line(thread,head:document.headSHA) else { return false }
            return line.side.rawValue == selection.side && line.start <= selection.endLine && selection.startLine <= line.end
        }?.id
    }
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:6) {
                Label("Threads",systemImage:"text.bubble").font(.caption.weight(.semibold))
                Spacer(minLength:4)
                if model.loading { ProgressView().controlSize(.mini) }
                Toggle("Unresolved only",isOn:$unresolvedOnly).toggleStyle(.checkbox).controlSize(.mini).font(.caption)
            }.padding(.horizontal,10).padding(.vertical,7)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:8) {
                        if let error=model.error {
                            Text("Reply and Resolve unavailable: "+error).font(.caption).foregroundStyle(.orange)
                            Button("Read threads again") { Task { await model.load() } }.controlSize(.small)
                        }
                        if model.truth == nil {
                            if model.loading { Text("Reading threads…").font(.caption).foregroundStyle(.secondary) }
                            ForEach(comments) { event in
                                InlineCommentBubble(event:event,line:event.renderingAnchor(in:document).map { (side:DiffSide(rawValue:$0.side) ?? .right,start:$0.startLine,end:$0.endLine) },jump:jump)
                            }
                        } else {
                            if model.truth?.threadsComplete == false { Text("Partial thread list. Missing threads can't be ruled out; open the pull request on GitHub.").font(.caption).foregroundStyle(.orange) }
                            ForEach(threads) { thread in InlineThreadBubble(model:model,thread:thread,head:document.headSHA,highlighted:thread.id == selectedThread,jump:jump,changed:changed).id(thread.id) }
                            if threads.isEmpty { Text(unresolvedOnly ? "No unresolved threads on this file." : "No review threads on this file.").font(.caption).foregroundStyle(.secondary) }
                        }
                        if let key=model.actionPR?.key,!model.messages.isEmpty {
                            PRWriteStatusView(key:key,storage:model.storage,changeSignal:model.operationRevision) { await model.load();changed() }.font(.caption)
                        }
                    }.padding(8)
                }
                .onChange(of:selectedThread) { _,id in if let id { withAnimation { proxy.scrollTo(id,anchor:.top) } } }
            }
        }
        .accessibilityElement(children:.contain).accessibilityLabel("Review threads for \((file.path as NSString).lastPathComponent)")
        .task { await model.loadIfNeeded() }
    }
}

/// Comment on a diff selection or file from a popover at the button, instead of the full review sheet.
/// The comment joins the action account's pending review draft; nothing is sent until the review is submitted.
struct DiffCommentPopover:View {
    let pr:PullRequest
    let storage:SetupStorage
    let comment:ReviewDraftComment
    /// Opens the full review composer with this selection.
    var openComposer:(() -> Void)? = nil
    var added:(Int) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var text=""
    @State private var busy=false
    @State private var message:String?
    @FocusState private var focused:Bool
    private var location:String {
        comment.location.map { "\($0.path):\($0.startLine == $0.endLine ? "\($0.endLine)" : "\($0.startLine)–\($0.endLine)") · \($0.side == DiffSide.left.rawValue ? "old" : "new") side" } ?? "\(comment.providerPath) · whole file"
    }
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text(comment.location == nil ? "Comment on file" : "Comment on selection").font(.headline)
            Text(location).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            TextEditor(text:$text).font(.body).frame(width:380,height:120).border(.separator).focused($focused).accessibilityLabel("Comment").accessibilityIdentifier("inlineCommentBody")
            Text("Adds to your pending review. It's sent when you submit the review.").font(.caption).foregroundStyle(.secondary)
            if let message { WorkspaceNotice(message:message,symbol:"exclamationmark.triangle",tint:.orange) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if let openComposer { Button("Open review…") { dismiss();openComposer() } }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Add to review") { Task { await add() } }.buttonStyle(.borderedProminent).keyboardShortcut(.return,modifiers:.command)
                    .disabled(busy || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).help("Add to review (⌘Return)").accessibilityIdentifier("addInlineComment")
            }.controlSize(.small)
        }.padding(14).onAppear { focused=true }
    }
    private func add() async {
        busy=true;defer { busy=false }
        do {
            let draft=try await storage.addDraftComment(pr,comment:comment.withBody(text))
            AccessibilityNotification.Announcement("Comment added to your review").post()
            added(draft.comments.count);dismiss()
        } catch {
            message=error as? PRWriteFailure == .revisionChanged ? "Your review draft is on an earlier revision. Open the review to move it to this revision first; nothing was changed." : error.localizedDescription
        }
    }
}
