import MergeProCore
import SwiftUI

private struct BatchMergeItem:Identifiable {
    enum Prefill { case idle,loading,loaded,unavailable }
    var selected:MergeInspection
    var affected:[MergeInspection]
    /// Switching method re-applies this item's head-bound defaults; edits survive.
    var method:MergeMethod { didSet { text.applyDefaults(text.defaults,method:method) } }
    var text:MergeCommitText
    var keepTrailers=true
    var prefill=Prefill.idle
    var expanded=false
    var dependency:InferredMergeDependency?
    init(selected:MergeInspection,affected:[MergeInspection],method:MergeMethod) { self.selected=selected;self.affected=affected;self.method=method;text=MergeCommitText(method:method) }
    var id:ProviderKey { selected.pr.key }
    var action:MergeAction { MergePolicy.evaluate(selected.evidence).action }
    var options:[MergeMethodOption] { MergePolicy.methodOptions(selected.evidence,action:action) }
    var queueGoverned:Bool { action == .queue || selected.evidence.queueRequired }
    var acceptsText:Bool { action == .direct && !queueGoverned && text.acceptsText }
    var edited:Bool { text.titleEdited || text.messageEdited }
    var droppedTrailers:[String] {
        guard text.method == .squash,text.messageEdited,let wanted=text.defaults?.coAuthorTrailers else { return [] }
        return wanted.filter { MergeMessageComposer.ensuring(trailers:[$0],in:text.message) != text.message }
    }
    /// Prefill for another head is ignored; a failed read keeps whatever was already applied.
    mutating func applyDefaults(_ defaults:MergeMessageDefaults?) {
        guard let defaults,defaults.head == selected.evidence.head else { return }
        text.applyDefaults(defaults,method:method)
    }
    func command() throws -> MergeCommand {
        let overrides=acceptsText ? text.overrides(keepTrailers:keepTrailers,action:action) : (title:nil,message:nil)
        var command = try MergeCommand(selected:selected,affected:affected,method:method,action:action,title:overrides.title,message:overrides.message)
        command.inferredDependency = dependency
        return command
    }
}
struct PRBatchActionSheet:View {
    let rows:[PullRequest]
    let approve:Bool
    let workspace:PRWorkspaceModel
    /// Selected rows left out before the sheet opened because of a known blocker.
    var skipped:[MergeBatchPlan.Skip]=[]
    /// Rows whose fresh GitHub read isn't ready to merge; left out of this batch and listed with the reason.
    @State private var notReady:[MergeBatchPlan.Skip]=[]
    @Environment(\.dismiss) private var dismiss
    @State private var identity=PRActionLoadState()
    @State private var commands:[PRWriteCommand]=[]
    @State private var merges:[BatchMergeItem]=[]
    /// Return in a commit field edits text; it must never reach the confirm button.
    @FocusState private var commitField:String?
    @State private var reviewFacts:[ProviderKey:String]=[:]
    @State private var status:String?
    @State private var progress:PRBatchProgress?
    @State private var busy=false
    private var available:Bool {
        guard let key=identity.key else { return true }
        return workspace.cached(key) != nil && workspace.activeActionAccount == key.account && (commands.map(\.key)+merges.flatMap { $0.affected.map { $0.pr.key } }).allSatisfy { workspace.cached($0) != nil }
    }
    private var presented:Bool { identity.canDisplay(identity.key,available:available) }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(approve ? (rows.count == 1 ? "Approve pull request" : "Approve \(rows.count) pull requests") : "Merge selected pull requests").font(.system(.title2,design:.rounded).bold())
            Text("Every item is reviewed below and processed one at a time. The batch stops at the first incomplete or failed result.").font(.caption)
            if !approve,available,!(skipped+notReady).isEmpty { skippedList }
            if presented {
                Text("Action account: \(identity.key.flatMap { key in workspace.accounts.first { $0.scope == key.account }?.login } ?? identity.key?.accountID ?? "")")
                if !approve,merges.count>1 {
                    HStack(alignment:.firstTextBaseline,spacing:10) {
                        Text("Method for all").font(.callout.weight(.semibold))
                        MergeMethodSelector(options:commonOptions,selection:commonMethod,compact:true) { method in for index in merges.indices { merges[index].method=method } }
                            .disabled(busy || progress != nil).accessibilityIdentifier("batchMergeMethodAll")
                    }.padding(10).frame(maxWidth:.infinity,alignment:.leading).workspacePanel(radius:12)
                }
                ScrollView {
                  // Explicit leading stack: ScrollView's implicit stack centers rows of differing widths.
                  VStack(alignment:.leading,spacing:0) {
                    if approve {
                        ForEach(Array(commands.enumerated()),id:\.element.key) { index,command in
                            VStack(alignment:.leading) {
                                Text("\(index+1). \(command.repository) #\(command.number) · \(command.revision.head.prefix(10))")
                                Text(reviewFacts[command.key] ?? "Review facts unavailable").font(.caption)
                                switch command.intent {
                                case .review(_,let summary),.submitPending(_,_,let summary):if !summary.isEmpty { Text(summary).font(.callout) }
                                default:EmptyView()
                                }
                            }.padding(.bottom,8)
                        }
                    } else {
                        ForEach($merges) { $item in
                            VStack(alignment:.leading,spacing:8) {
                                HStack(alignment:.firstTextBaseline,spacing:8) {
                                    Text("\(item.selected.pr.metadata?.repositoryName ?? "") #\(item.selected.pr.metadata?.number ?? 0)").font(.headline)
                                    Text(item.selected.pr.title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer(minLength:8)
                                    if item.queueGoverned { WorkspaceStatusBadge(text:"Merge queue",symbol:"list.number",tint:DesignTokens.cobalt) }
                                }
                                MergeMethodSelector(options:item.options,method:$item.method,compact:true).disabled(busy || progress != nil)
                                if item.queueGoverned {
                                    Text("Merge queue on \(item.selected.evidence.branch) uses \(item.selected.evidence.queueMethod.map { MergeMethodSelector.shortName($0).lowercased() } ?? "an unknown method"); commit text is set by the queue.").font(.caption).foregroundStyle(.secondary)
                                } else if item.method == .rebase {
                                    Text("Rebase merges don't create a merge commit message.").font(.caption).foregroundStyle(.secondary)
                                } else if item.acceptsText {
                                    let key=item.id
                                    DisclosureGroup(isExpanded:$item.expanded) { commitEditor($item).padding(.top,6) } label: {
                                        HStack(spacing:6) {
                                            Text("Commit message").font(.callout)
                                            if item.edited { WorkspaceStatusBadge(text:"Edited",symbol:"pencil",tint:DesignTokens.cobalt) }
                                        }
                                    }
                                    .disabled(busy || progress != nil)
                                    // Collapsing the editor or closing the sheet cancels a prefill still loading.
                                    .onChangeTask(of:item.expanded) { open in if open { await loadDefaults(key) } }
                                }
                                ForEach(item.affected,id:\.pr.key) { value in Text("Affected #\(value.pr.metadata?.number ?? 0) · \(value.evidence.head.prefix(10))").font(.caption).foregroundStyle(.secondary) }
                                if let stack=item.selected.stack { Text(stack.guardExplanation).font(.caption).foregroundStyle(.secondary) }
                                if let dependency=item.dependency {
                                    Text("Inferred dependency: "+dependency.parentBranch+". After the lower layer lands, this batch stops for retargeting/restacking and fresh review.").font(.caption)
                                    Link("Review dependency on GitHub",destination:dependency.providerURL)
                                }
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(12).workspacePanel(radius:12).padding(.bottom,10)
                        }
                    }
                  }.frame(maxWidth:.infinity,alignment:.leading)
                }.frame(maxHeight:420)
                if let progress {
                    Text("Completed: \(progress.completed.count) · Remaining: \(progress.remaining.count)").accessibilityIdentifier("batchProgress")
                    if let stopped=progress.stopped { Label { Text(stopped) } icon: { Image(systemName:"exclamationmark.triangle.fill").foregroundStyle(.orange) } }
                    if let url=progress.providerURL { Link("Review restacking on GitHub",destination:url) }
                }
            } else if busy { ProgressView("Reading every selected account, revision and permission…") }
            if available,let status { Label { Text(status) } icon: { Image(systemName:"exclamationmark.triangle.fill").foregroundStyle(.orange) }.font(.caption) }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy && presented)
                Spacer()
                Button(approve ? "Approve all listed" : "Confirm listed operations") { Task { await run() } }.keyboardShortcut(commitField == nil ? KeyboardShortcut(.return, modifiers: .command) : nil).help("Confirm (⌘Return)").buttonStyle(.borderedProminent).disabled(!presented || busy || progress != nil || status != nil || (approve ? commands.isEmpty : merges.isEmpty))
            }
        }.padding(20).frame(width:640).task { await load() }
        .onChange(of:available) { _,value in if !value { identity.invalidate();commands=[];merges=[];notReady=[];reviewFacts=[:];status=nil;progress=nil;busy=false } }
    }
    /// Pull requests left out of this batch, each with why; nothing is sent for them.
    private var skippedList:some View {
        VStack(alignment:.leading,spacing:4) {
            Label("Skipped",systemImage:"minus.circle").font(.callout.weight(.semibold))
            ForEach(skipped+notReady) { item in
                Text("\(item.pr.metadata?.repositoryName ?? "") #\(item.pr.metadata?.number ?? 0) · \(item.reason)").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth:.infinity,alignment:.leading).padding(10).workspacePanel(radius:12)
        .accessibilityElement(children:.combine).accessibilityIdentifier("batchSkipped")
    }
    /// Methods every listed item allows; a disabled segment names the items that block it.
    private var commonOptions:[MergeMethodOption] {
        MergeMethod.allCases.map { method in
            let blocked=merges.filter { !$0.options.contains { $0.method == method && $0.enabled } }
            return .init(method:method,enabled:blocked.isEmpty,reason:blocked.isEmpty ? nil : "Not allowed for "+blocked.map { "#\($0.selected.pr.metadata?.number ?? 0)" }.joined(separator:", "))
        }
    }
    private var commonMethod:MergeMethod? { let methods=Set(merges.map(\.method));return methods.count == 1 ? methods.first : nil }
    private func commitEditor(_ item:Binding<BatchMergeItem>) -> some View {
        let value=item.wrappedValue
        return VStack(alignment:.leading,spacing:6) {
            if value.prefill == .loading { ProgressView("Reading GitHub's default commit text…").controlSize(.small).font(.caption) }
            HStack(spacing:6) {
                TextField("Commit title",text:item.text.title,prompt:Text(value.text.defaultTitle.isEmpty ? "Commit title (GitHub default)" : value.text.defaultTitle)).textFieldStyle(.roundedBorder)
                    .focused($commitField,equals:"title-\(value.id)").onSubmit { commitField="message-\(value.id)" }
                Button("Reset to GitHub default",systemImage:"arrow.counterclockwise") { item.wrappedValue.text.resetToDefault();item.wrappedValue.keepTrailers=true }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(!value.edited).help("Reset to GitHub default")
            }
            TextEditor(text:item.text.message).font(.system(.callout,design:.monospaced))
                .scrollContentBackground(.hidden).padding(.horizontal,4).padding(.vertical,5).frame(height:96)
                .background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:8))
                .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(Color(nsColor:.separatorColor),lineWidth:1).allowsHitTesting(false))
                .focused($commitField,equals:"message-\(value.id)").accessibilityLabel("Commit message")
            if !value.droppedTrailers.isEmpty {
                Toggle("Keep \(value.droppedTrailers.count) Co-authored-by trailer\(value.droppedTrailers.count == 1 ? "" : "s")",isOn:item.keepTrailers).toggleStyle(.checkbox).font(.caption)
                    .help(value.droppedTrailers.joined(separator:"\n"))
            }
            if value.text.defaults?.commitsComplete == false { Text("More commits than were read; the co-author list may be incomplete.").font(.caption).foregroundStyle(.secondary) }
            if value.prefill == .unavailable { Text("GitHub's default text could not be read. Leave the fields unchanged to let GitHub apply it.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    /// Lazy, read-only prefill for one item when its editor first opens.
    private func loadDefaults(_ key:ProviderKey) async {
        guard let primary=identity.key,let request=identity.presentationRequest(for:primary,available:available),let index=merges.firstIndex(where:{ $0.id == key }),merges[index].prefill == .idle else { return }
        merges[index].prefill = .loading
        let pr=merges[index].selected.pr
        // No prefill only means the editor starts empty.
        let fetched=await AppLog.value(AppLog.workspace,"Merge message defaults could not be read",fallback:nil) { try await workspace.storage.mergeMessageDefaults(pr) }
        guard identity.accepts(primary,request:request,available:available),let current=merges.firstIndex(where:{ $0.id == key }) else { return }
        // A cancelled read is no answer: the next expansion asks again.
        guard !Task.isCancelled else { merges[current].prefill = .idle; return }
        merges[current].prefill=fetched == nil ? .unavailable : .loaded
        merges[current].applyDefaults(fetched)
    }
    private func load() async {
        let request=identity.begin();busy=true;commands=[];merges=[];notReady=[];reviewFacts=[:]
        defer { if identity.isCurrent(request) { busy=false } }
        do {
            var prepared:[PRWriteCommand]=[],items:[BatchMergeItem]=[],primary:ProviderKey?
            var facts:[ProviderKey:String]=[:],unready:[MergeBatchPlan.Skip]=[]
            for read in rows {
                let pr=try await workspace.storage.actionPR(read)
                if primary == nil { primary=pr.key;identity.select(pr.key,request:request) }
                guard identity.isCurrent(request),available,pr.key.account == primary?.account,let m=pr.metadata else { throw PRWriteFailure.accountChanged }
                if approve {
                    let snapshot=try await workspace.storage.detail(pr),draft=try await workspace.storage.reviewDraft(pr.key)
                    guard draft?.comments.contains(where:{ $0.postedCommentID == nil || $0.hasUnsentEdit }) != true else { throw PRWriteFailure.unsentComments }
                    if let draft { guard draft.revision == PRWriteRevision(snapshot) else { throw PRWriteFailure.revisionChanged } }
                    let intent:PRWriteIntent=draft?.pendingReviewID.map { .submitPending(id:$0,decision:.approve,summary:draft?.summary ?? "") } ?? .review(.approve,draft?.summary ?? "")
                    let command=PRWriteCommand(key:pr.key,repository:m.repositoryName,number:m.number,revision:.init(snapshot),intent:intent,requireAllViewed:try await workspace.storage.requireAllFilesViewed())
                    let truth=try await workspace.storage.inspectWrite(command);try command.validate(truth:truth);prepared.append(command)
                    facts[pr.key]="\(ProviderStateText.checks(pr.metadata?.checks).text) · \(truth.files.subtracting(truth.viewed).count) unviewed files · Risk: \(truth.riskFlagged ? "flagged or unknown" : "no flags")"
                } else {
                    let values=try await workspace.storage.prepareMerge(pr)
                    guard let selected=values.first(where:{ $0.pr.key == pr.key }) else { throw PRWriteFailure.unavailable }
                    // Verified now: an item GitHub doesn't report ready is left out (and listed), not the whole batch.
                    if let blocked=values.lazy.map({ MergePolicy.evaluate($0.evidence) }).first(where:{ !$0.eligible }) {
                        unready.append(.init(pr:pr,reason:blocked.reasons.first ?? "Not ready to merge."));continue
                    }
                    let methods=MergePolicy.evaluate(selected.evidence).methods,preferred=try await workspace.storage.mergeDefault(pr.key.repository)
                    items.append(.init(selected:selected,affected:values,method:preferred.flatMap { methods.contains($0) ? $0 : nil } ?? methods.first ?? .squash))
                }
            }
            // One native selected-layer command includes its disclosed downstack. Keep the
            // largest affected set and display all included selections under that operation.
            var covered:Set<ProviderKey>=[],distinct:[BatchMergeItem]=[]
            for (_,item) in items.enumerated().sorted(by:{ $0.element.affected.count == $1.element.affected.count ? $0.offset < $1.offset : $0.element.affected.count > $1.element.affected.count }) {
                if covered.contains(item.id) { continue }
                covered.formUnion(item.affected.map { $0.pr.key });distinct.append(item)
            }
            if !approve {
                // Use every current inferred chain, replacing selected cached rows with
                // freshly inspected identities before freezing dependency constraints.
                let freshRows = items.map { $0.selected.pr }
                let selectedKeys = Set(freshRows.map(\.key))
                let sourceRows = workspace.rows.filter { !selectedKeys.contains($0.key) } + freshRows
                let inferred = StackGraph.inferred(sourceRows)
                let captured = try StackMergeCoordinator.captureDependencies(distinct.map { try $0.command() },stacks:inferred)
                distinct = captured.compactMap { command in
                    guard var item = distinct.first(where:{ $0.id == command.pr }) else { return nil }
                    item.dependency = command.inferredDependency
                    return item
                }
            }
            await workspace.reload()
            guard let primary,identity.present(primary,request:request,available:available) else { return }
            commands=prepared;merges=distinct;notReady=unready;reviewFacts=facts
            status = !approve && distinct.isEmpty ? "None of the listed pull requests is ready to merge." : nil
        } catch { if identity.fail(request:request) { busy=false;status=error.localizedDescription } }
    }
    private func run() async {
        guard let key=identity.key,let request=identity.presentationRequest(for:key,available:available) else { return };busy=true
        defer { if identity.isCurrent(request) { busy=false } }
        let storage=workspace.storage
        let publish:@Sendable (PRBatchProgress) async -> Void = { value in
            await MainActor.run { if identity.accepts(key,request:request,available:available) { progress=value } }
        }
        if approve { _ = await StackMergeCoordinator.approve(commands,perform:{ try await storage.performWrite($0) },progress:publish) }
        else {
            do { let captured=try merges.map { try $0.command() };_ = await StackMergeCoordinator.merge(captured,perform:{ try await storage.performMerge($0) },progress:publish) }
            catch { if identity.accepts(key,request:request,available:available) { status=error.localizedDescription } }
        }
        guard identity.accepts(key,request:request,available:available) else { return }
        if let progress {
            let done=approve ? "Approved" : "Merged or queued"
            workspace.announce("\(done) \(progress.completed.count) of \(progress.completed.count+progress.remaining.count).\(progress.stopped.map { " Stopped: "+$0 } ?? "")")
        } else if let status { workspace.announce(status) }
        await workspace.reload()
    }
}
