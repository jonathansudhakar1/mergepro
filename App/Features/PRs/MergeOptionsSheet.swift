import MergeProCore
import SwiftUI

/// One native confirmation. Opening, changing options and cancelling are read-only.
struct MergeOptionsSheet:View {
    let readPR:PullRequest
    let storage:SetupStorage
    let workspace:PRWorkspaceModel?
    var requestedAction:MergeAction?
    /// The head the PR window shows; nil outside one. Merging, queueing and enabling auto-merge run only at this head:
    /// a newer action-account head is refused (pointing to the window's Update) instead of landing unseen commits.
    var displayedHead:String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var identity=MergeOptionsPresentationState()
    /// Return in the commit fields edits text; it must never reach the merge button.
    @FocusState private var commitField:CommitField?
    private enum CommitField:Hashable { case title,message }
    @State private var values:[MergeInspection]=[]
    @State private var selected:MergeInspection?
    @State private var login=""
    @State private var method:MergeMethod = .squash
    @State private var savedDefault:MergeMethod?
    @State private var keepTrailers=true
    @State private var updateMethod:MergeUpdateMethod = .merge
    @State private var loadingDefaults=false
    @State private var contentHeight:CGFloat=0
    @State private var status:String?
    @State private var error:String?
    @State private var operations:[PRWriteOperation]=[]
    @State private var busy=false
    private var available:Bool { identity.key.map { key in workspace == nil || (workspace?.cached(key) != nil && workspace?.activeActionAccount == key.account) } ?? true }
    private var displayed:Bool { identity.canDisplay(selected?.pr.key,available:available) }
    private var policy:MergeEligibility { MergePolicy.evaluate(selected?.evidence) }
    private var action:MergeAction { requestedAction ?? policy.action }
    private var label:String {
        switch action { case .direct:"Merge";case .queue:"Add to merge queue";case .enableAutoMerge:"Enable auto-merge";case .disableAutoMerge:"Disable auto-merge";case .removeQueue:"Remove from queue";case .updateBranch:"Update branch" }
    }
    private var heading:String { action == .direct ? "Merge pull request" : label }
    private var confirmLabel:String {
        guard action == .direct else { return label }
        switch method { case .merge:return "Merge pull request";case .squash:return "Squash and merge";case .rebase:return "Rebase and merge" }
    }
    private var symbol:String {
        switch action { case .direct:"arrow.triangle.merge";case .queue:"list.number";case .enableAutoMerge:"clock.arrow.circlepath";case .disableAutoMerge:"clock.badge.xmark";case .removeQueue:"minus.circle";case .updateBranch:"arrow.triangle.2.circlepath" }
    }
    private var tint:Color { action == .updateBranch ? DesignTokens.cobalt : DesignTokens.violet }
    /// Direct merge and auto-merge choose a method; a queue (configured or required) fixes it.
    private var choosesMethod:Bool { [.direct,.enableAutoMerge].contains(action) }
    private var queueGoverned:Bool { action == .queue || (choosesMethod && selected?.evidence.queueRequired == true) }
    private var methodOptions:[MergeMethodOption] { MergePolicy.methodOptions(selected?.evidence,action:action) }
    private var acceptsText:Bool { choosesMethod && !queueGoverned && identity.text.acceptsText }
    private var edited:Bool { identity.text.titleEdited || identity.text.messageEdited }
    /// Co-author trailers from GitHub's squash default that the user's edited body no longer carries.
    private var droppedTrailers:[String] {
        let text=identity.text
        guard text.method == .squash,text.messageEdited,let wanted=text.defaults?.coAuthorTrailers else { return [] }
        return wanted.filter { MergeMessageComposer.ensuring(trailers:[$0],in:text.message) != text.message }
    }
    /// Six to twelve monospaced lines, growing with the message.
    private var editorHeight:CGFloat { CGFloat(min(max(identity.text.message.components(separatedBy:"\n").count,6),12))*16+14 }
    /// Why the inspected head can't be acted on from this window (the window's head changed while the sheet was open).
    private var headRefusal:String? {
        guard PRDisplayedHead.guards(action),let selected else { return nil }
        return PRDisplayedHead.refusal(shown:displayedHead,actual:selected.evidence.head,acting:Self.acting(action))
    }
    private static func acting(_ action:MergeAction?) -> String {
        switch action { case .queue?:"adding it to the merge queue";case .enableAutoMerge?:"enabling auto-merge";default:"merging" }
    }
    private var canSubmit:Bool {
        guard let selected,!busy,status == nil,headRefusal == nil,operations.allSatisfy({ ![.prepared,.sending,.uncertain].contains($0.state) }) else { return false }
        if [.direct,.queue,.enableAutoMerge].contains(action),!methodOptions.contains(where:{ $0.method == method && $0.enabled }) { return false }
        switch action {
        case .direct,.queue:return values.allSatisfy { MergePolicy.evaluate($0.evidence).eligible } && policy.eligible
        case .enableAutoMerge:return selected.stack == nil && selected.evidence.canEnableAutoMerge && !selected.evidence.autoMergeEnabled
        case .disableAutoMerge:return selected.evidence.canDisableAutoMerge && selected.evidence.autoMergeEnabled
        case .removeQueue:return selected.evidence.canRemoveQueue && selected.evidence.queued
        case .updateBranch:return selected.evidence.canUpdateBranch
        }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            header
            ScrollView {
                VStack(alignment:.leading,spacing:14) { content }
                    .frame(maxWidth:.infinity,alignment:.leading)
                    .onGeometryChange(for:CGFloat.self) { $0.size.height } action:{ contentHeight=$0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height:min(max(contentHeight,1),500))
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("cancelMerge")
                Button("Refresh") { Task { await load() } }.disabled(busy)
                Spacer()
                if busy || loadingDefaults { ProgressView().controlSize(.small) }
                Button(confirmLabel) { Task { await confirm() } }.keyboardShortcut(commitField == nil ? KeyboardShortcut(.return, modifiers: .command) : nil).help("Merge (⌘Return)").buttonStyle(.borderedProminent).disabled(!canSubmit || !displayed).accessibilityIdentifier("confirmMerge")
            }
        }.padding(20).frame(width:640).task { await load() }
        .onChange(of:available) { _,value in if !value { identity.invalidate();values=[];selected=nil;login="";status=nil;error=nil;operations=[];busy=false;loadingDefaults=false } }
        .accessibilityIdentifier("mergeOptionsSheet")
    }
    // MARK: Sections
    private var header:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(alignment:.center,spacing:12) {
                Image(systemName:symbol).font(.title2.weight(.semibold)).foregroundStyle(tint)
                    .frame(width:40,height:40).background(tint.opacity(0.12),in:RoundedRectangle(cornerRadius:11)).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:2) {
                    Text(heading).font(.system(.title2,design:.rounded).bold())
                    if displayed,let selected { Text("\(selected.pr.metadata?.repositoryName ?? "") #\(String(selected.pr.metadata?.number ?? 0)) · \(selected.pr.title)").font(.headline).lineLimit(2) }
                }
            }
            if displayed,let selected {
                HStack(spacing:6) {
                    Image(systemName:"person.crop.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("Action account: \(login) · \(selected.pr.key.host)").accessibilityIdentifier("mergeActionAccount")
                }.font(.callout)
                HStack(spacing:6) {
                    Image(systemName:"number").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("Expected head: \(selected.evidence.head)").textSelection(.enabled)
                }.font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private var content:some View {
        if displayed,let selected {
            if choosesMethod { methodSection }
            if acceptsText { commitTextSection }
            notices(selected)
            if action == .updateBranch { updateSection(selected) }
            if let stack=selected.stack { stackSection(stack) }
            if [.direct,.queue].contains(action) { requirementsSection(selected) }
            else if action == .enableAutoMerge { WorkspaceNotice(message:"Waits for future requirements. Enabling auto-merge does not mark this PR ready or merged.") }
            ForEach(operations.filter { [.prepared,.sending,.uncertain].contains($0.state) }) { operation in
                HStack {
                    Image(systemName:"exclamationmark.arrow.triangle.2.circlepath").foregroundStyle(.orange).accessibilityHidden(true)
                    Text(ProviderStateText.mergeOperation(operation)).font(.caption)
                    Spacer()
                    Button(operation.state == .prepared ? "Release unsent" : "Read provider result") { Task { await recover(operation) } }.disabled(busy)
                }.padding(10).workspacePanel(radius:10)
            }
            if let status {
                Text(status).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(12)
                    .background(DesignTokens.cobalt.opacity(0.07),in:RoundedRectangle(cornerRadius:12))
                    .accessibilityIdentifier("mergeOutcome")
            }
            if let headRefusal { WorkspaceNotice(message:headRefusal,symbol:"arrow.down.circle",tint:.orange) }
            if available,let error { WorkspaceNotice(message:error,symbol:"exclamationmark.circle",tint:.orange) }
        } else if busy { ProgressView("Reading selected account and requirements…").frame(maxWidth:.infinity).padding(.vertical,24) }
        else { WorkspaceNotice(message:available ? (error ?? "Read the selected account again.") : "Action account changed or unavailable.",symbol:"exclamationmark.triangle",tint:.orange) }
    }
    private func sectionTitle(_ title:String,symbol:String) -> some View {
        Label(title,systemImage:symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }
    private var methodSection:some View {
        VStack(alignment:.leading,spacing:8) {
            sectionTitle("Merge method",symbol:"arrow.triangle.merge")
            // Frozen while a write runs, so the method shown is the one sent.
            MergeMethodSelector(options:methodOptions,method:Binding(get:{ method },set:{ choose($0) }),savedDefault:savedDefault,repository:selected?.pr.metadata?.repositoryName).disabled(busy)
        }.padding(14).workspacePanel(radius:12)
    }
    private var commitTextSection:some View {
        let defaults=identity.text.defaults
        return VStack(alignment:.leading,spacing:8) {
            HStack(spacing:8) {
                sectionTitle("Commit message",symbol:"text.alignleft")
                WorkspaceStatusBadge(text:edited ? "Edited" : "GitHub default",symbol:edited ? "pencil" : "checkmark.seal",tint:edited ? DesignTokens.cobalt : .secondary)
                if loadingDefaults { ProgressView().controlSize(.mini) }
                Spacer()
                Button("Reset to GitHub default",systemImage:"arrow.counterclockwise") { identity.text.resetToDefault();keepTrailers=true }
                    .buttonStyle(.borderless).controlSize(.small).disabled(!edited)
                    .help("Restore GitHub's default title and message for this method").accessibilityIdentifier("resetMergeCommitText")
            }
            TextField("Commit title",text:$identity.text.title,prompt:Text(identity.text.defaultTitle.isEmpty ? "Commit title (GitHub default)" : identity.text.defaultTitle))
                .textFieldStyle(.roundedBorder).focused($commitField,equals:.title).onSubmit { commitField = .message }.accessibilityIdentifier("mergeCommitTitle")
            if identity.text.titleEdited,identity.text.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                Text("A blank title uses GitHub's default.").font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text:$identity.text.message).font(.system(.body,design:.monospaced))
                .scrollContentBackground(.hidden).padding(.horizontal,4).padding(.vertical,6).frame(height:editorHeight)
                .background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:8))
                .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(Color(nsColor:.separatorColor),lineWidth:1).allowsHitTesting(false))
                // Without readable defaults an unedited message sends nothing, and GitHub composes its own.
                .overlay(alignment:.topLeading) {
                    if identity.messageUsesProviderDefault,identity.text.message.isEmpty {
                        Text("GitHub will use its default message").font(.system(.body,design:.monospaced)).foregroundStyle(.tertiary)
                            .padding(.horizontal,9).padding(.vertical,6).allowsHitTesting(false)
                    }
                }
                .focused($commitField,equals:.message).accessibilityLabel("Commit message").accessibilityIdentifier("mergeCommitMessage")
            if !droppedTrailers.isEmpty {
                Toggle("Keep \(droppedTrailers.count) Co-authored-by trailer\(droppedTrailers.count == 1 ? "" : "s")",isOn:$keepTrailers).toggleStyle(.checkbox)
                    .help(droppedTrailers.joined(separator:"\n")).accessibilityIdentifier("keepCoAuthorTrailers")
            }
            if defaults?.commitsComplete == false {
                Label("This pull request has more commits than were read; the co-author list may be incomplete.",systemImage:"info.circle").font(.caption).foregroundStyle(.secondary)
            }
            if defaults == nil,!loadingDefaults {
                Label("GitHub's default text could not be read. Leave the fields unchanged to let GitHub apply it.",systemImage:"info.circle").font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(busy).padding(14).workspacePanel(radius:12)
    }
    @ViewBuilder private func notices(_ selected:MergeInspection) -> some View {
        if queueGoverned {
            let queue=selected.evidence.queueMethod.map { MergeMethodSelector.shortName($0).lowercased() } ?? "an unknown method"
            WorkspaceNotice(message:"Merge queue on \(selected.evidence.branch) uses \(queue); commit text is set by the queue.",symbol:"list.number",tint:DesignTokens.cobalt)
        } else if choosesMethod,method == .rebase {
            WorkspaceNotice(message:"Rebase merges don't create a merge commit message. Each commit is replayed onto \(selected.evidence.branch) unchanged.",symbol:"arrow.triangle.branch",tint:DesignTokens.cobalt)
        }
        if selected.evidence.autoMergeEnabled { autoMergePanel(selected.autoMergeRequest) }
    }
    private func autoMergePanel(_ request:MergeAutoMergeRequest?) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Label { Text(request?.method.map { "Auto-merge is already enabled · "+MergeMethodOption(method:$0,enabled:true,reason:nil).label } ?? "Auto-merge is already enabled; its method could not be read.") } icon: { Image(systemName:"clock.badge.checkmark").foregroundStyle(DesignTokens.cobalt) }
                .font(.callout.weight(.semibold))
            if let headline=request?.commitHeadline,!headline.isEmpty { Text(headline).font(.callout.monospaced()).textSelection(.enabled) }
            if let body=request?.commitBody,!body.isEmpty { Text(body).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(8).textSelection(.enabled) }
            if request != nil,request?.commitHeadline == nil,request?.commitBody == nil { Text("Commit text follows GitHub's default.").font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth:.infinity,alignment:.leading).padding(12)
        .background(DesignTokens.cobalt.opacity(0.07),in:RoundedRectangle(cornerRadius:12))
        .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(DesignTokens.cobalt.opacity(0.16),lineWidth:1).allowsHitTesting(false))
    }
    private func updateSection(_ selected:MergeInspection) -> some View {
        VStack(alignment:.leading,spacing:8) {
            sectionTitle("Update method",symbol:"arrow.triangle.2.circlepath")
            Picker("Update method",selection:$updateMethod) {
                Text("Merge base into branch").tag(MergeUpdateMethod.merge)
                Text("Rebase branch").tag(MergeUpdateMethod.rebase)
            }.pickerStyle(.radioGroup).labelsHidden().accessibilityIdentifier("mergeUpdateMethod")
            Text(updateMethod == .merge ? "Nonforce merge of the captured base into the branch. Acceptance stays pending until the resulting parents are verified."
                 : "Replays the branch's commits onto the captured base. Acceptance stays pending until a complete linear history on that base is verified.").font(.caption).foregroundStyle(.secondary)
            if updateMethod == .rebase {
                WorkspaceNotice(message:"Rebasing rewrites the history of \(selected.pr.metadata.map(\.headBranch).flatMap { $0.isEmpty ? nil : $0 } ?? "this branch"). Collaborators with local copies must force-update them, and pending work based on the old commits must be rebased.",symbol:"exclamationmark.triangle.fill",tint:.orange)
            }
        }.padding(14).workspacePanel(radius:12)
    }
    private func stackSection(_ stack:PRStack) -> some View {
        VStack(alignment:.leading,spacing:6) {
            sectionTitle("Native stack #\(String(stack.number ?? 0)) · affected layers",symbol:"square.stack.3d.up")
            ForEach(values,id:\.pr.key) { value in
                HStack(spacing:6) {
                    Text("#\(String(value.pr.metadata?.number ?? 0))").font(.callout.monospacedDigit().weight(.semibold))
                    Text(value.pr.title).font(.callout).lineLimit(1)
                    Spacer(minLength:8)
                    Text(value.evidence.head.prefix(10)).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            Text(stack.guardExplanation).font(.caption).foregroundStyle(.secondary)
            ForEach(stack.warnings,id:\.self) { warning in Label { Text(warning) } icon: { Image(systemName:"exclamationmark.triangle").foregroundStyle(.orange) }.font(.caption) }
            if action == .enableAutoMerge { Label { Text("Native stack future auto-merge effects are unverified; this action is unavailable.") } icon: { Image(systemName:"exclamationmark.triangle").foregroundStyle(.orange) }.font(.caption) }
        }.padding(14).workspacePanel(radius:12)
    }
    private func requirementsSection(_ selected:MergeInspection) -> some View {
        let listed=Set(selected.evidence.requirements.map { "\($0.name): \($0.state.rawValue)" })
        let other=policy.reasons.filter { !listed.contains($0) }
        return VStack(alignment:.leading,spacing:8) {
            sectionTitle("Requirements",symbol:"checklist")
            if policy.reasons.isEmpty {
                Label { Text("Current actor, checks, reviews and configured rules satisfy this action.") } icon: { Image(systemName:"checkmark.seal.fill").foregroundStyle(.green) }.font(.callout)
            } else if !other.isEmpty {
                WorkspaceNotice(message:other.joined(separator:"\n"),symbol:"exclamationmark.triangle",tint:.orange)
            }
            ForEach(selected.evidence.requirements,id:\.name) { requirement in
                HStack(spacing:8) {
                    Image(systemName:icon(requirement.state)).foregroundStyle(color(requirement.state)).accessibilityHidden(true)
                    Text(requirement.name).font(.callout)
                    Spacer(minLength:8)
                    Text(requirementText(requirement.state)).font(.caption).foregroundStyle(.secondary)
                }.accessibilityElement(children:.combine)
            }
            if !selected.evidence.optionalFailures.isEmpty {
                Text("Optional failures: "+selected.evidence.optionalFailures.joined(separator:", ")).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth:.infinity,alignment:.leading).padding(14).workspacePanel(radius:12)
    }
    private func icon(_ state:MergeRequirementState) -> String { switch state { case .satisfied:"checkmark.circle.fill";case .pending:"xmark.circle.fill";case .unknown:"questionmark.circle.fill" } }
    private func color(_ state:MergeRequirementState) -> Color { switch state { case .satisfied:.green;case .pending:.red;case .unknown:.orange } }
    private func requirementText(_ state:MergeRequirementState) -> String { switch state { case .satisfied:"Satisfied";case .pending:"Not yet satisfied";case .unknown:"Unknown" } }
    // MARK: Actions
    /// Method changes re-apply the head-bound defaults; user edits are never overwritten.
    private func choose(_ value:MergeMethod) {
        method=value
        identity.applyDefaults(identity.text.defaults,method:value,evidence:selected?.evidence)
    }
    private func load() async {
        let request=identity.begin(account:workspace == nil ? identity.key?.account : workspace?.activeActionAccount);busy=true;error=nil;loadingDefaults=false
        guard let current=await inspect(request) else { return }
        await prefill(current,request:request)
    }
    private func inspect(_ request:UUID) async -> MergeInspection? {
        defer { if identity.isCurrent(request) { busy=false } }
        do {
            let pr=try await storage.actionPR(readPR);identity.select(pr.key,request:request)
            let loaded=try await storage.prepareMerge(pr,action:requestedAction)
            let current=try loaded.first(where:{ $0.pr.key == pr.key }).unwrap()
            // The action account's row (or GitHub, ahead of every stored row) can be at a push the window hasn't
            // applied. The inspection just stored that head, so reloading lets the window offer Update.
            if PRDisplayedHead.guards(requestedAction),let refusal=PRDisplayedHead.refusal(shown:displayedHead,actual:current.evidence.head,acting:Self.acting(requestedAction)) {
                await workspace?.reload()
                throw PRDisplayedHead.Refusal(message:refusal)
            }
            let actor=try await storage.actionLogin(pr.key),saved=try await storage.mergeDefault(pr.key.repository),ops=try await storage.writeOperations(pr.key)
            guard identity.present(pr.key,request:request,available:available) else { return nil }
            // A refresh keeps the user's still-allowed choice; otherwise the saved default, then the first allowed method.
            let prior=selected?.pr.key == pr.key ? method : nil
            selected=current;values=loaded;login=actor;operations=ops;status=nil;savedDefault=saved
            let enabled=methodOptions.filter(\.enabled).map(\.method)
            choose([prior,saved].compactMap { $0 }.first(where:enabled.contains) ?? enabled.first ?? current.evidence.methods.first ?? .squash)
            return current
        } catch { if identity.fail(request:request) { busy=false;self.error=error.localizedDescription };return nil }
    }
    /// Read-only prefill after the presentation is current. A failure keeps any same-head defaults (or none).
    private func prefill(_ current:MergeInspection,request:UUID) async {
        let key=current.pr.key
        guard choosesMethod,!current.evidence.queueRequired,identity.accepts(key,request:request,available:available) else { return }
        loadingDefaults=true
        let fetched=try? await storage.mergeMessageDefaults(current.pr)
        guard identity.accepts(key,request:request,available:available) else { return }
        loadingDefaults=false
        identity.applyDefaults(fetched ?? identity.text.defaults,method:method,evidence:current.evidence)
    }
    private func confirm() async {
        guard canSubmit,let selected,let request=identity.presentationRequest(for:selected.pr.key,available:available) else { return }
        let key=selected.pr.key,sent=action;busy=true
        defer { if identity.isCurrent(request) { busy=false } }
        var outcome:PRWriteOperation?
        do {
            let text=acceptsText ? identity.overrides(keepTrailers:keepTrailers,action:action) : (title:nil,message:nil)
            let command=try MergeCommand(selected:selected,affected:values,method:method,action:action,title:text.title,message:text.message,updateMethod:action == .updateBranch ? updateMethod : nil),choseMethod=choosesMethod
            let result=try await storage.performMerge(command);outcome=result
            guard identity.accepts(key,request:request,available:available),identity.canDisplay(key,available:available) else { return }
            operations=[result];status=ProviderStateText.mergeOperation(result)
            announce(result,action:sent)
            // The repository default is the method this command carried, not whatever the selector shows now.
            if choseMethod,let sent=MergeMethod(rawValue:command.method) { try await storage.saveMergeDefault(sent,key:key.repository) }
            guard identity.accepts(key,request:request,available:available) else { return }
            await workspace?.reload()
            closeIfConfirmed(result,key:key,request:request)
        } catch { if identity.accepts(key,request:request,available:available) { self.error=error.localizedDescription;if outcome == nil { announceFailure(Self.actionName(sent)+" failed",error) } } }
    }
    private func recover(_ operation:PRWriteOperation) async {
        let key = operation.command.key
        guard let request = identity.presentationRequest(for:key,available:available) else { return }
        busy = true
        defer { if identity.isCurrent(request) { busy = false } }
        do {
            if operation.state == .prepared {
                try await storage.releaseUnsentWrite(operation.id)
                guard identity.accepts(key,request:request,available:available) else { return }
                await workspace?.reload()
                guard identity.accepts(key,request:request,available:available) else { return }
                await load()
            } else {
                let recovered = try await storage.reconcileWrite(operation.id)
                guard identity.accepts(key,request:request,available:available) else { return }
                // Keep the captured presentation and show the durable outcome, including
                // revision drift. A fresh prepare can legitimately fail once it is merged.
                operations = [recovered]
                status = ProviderStateText.mergeOperation(recovered)
                announce(recovered,action:action)
                await workspace?.reload()
                closeIfConfirmed(recovered,key:key,request:request)
            }
        } catch {
            if identity.accepts(key,request:request,available:available) { self.error = error.localizedDescription;announceFailure(operation.state == .prepared ? "Releasing the unsent request failed" : "Reading the provider result failed",error) }
        }
    }
}
extension MergeOptionsSheet {
    /// VoiceOver hears every outcome (merged, queued, auto-merge enabled or disabled, removed from the queue, branch
    /// updated, not merged) and uncertain ones that stay on screen with their reconcile controls.
    private func announce(_ operation:PRWriteOperation,action:MergeAction) {
        AccessibilityNotification.Announcement(Self.outcomeAnnouncement(operation.mergeOutcome,state:operation.state,message:operation.message,action:action,number:selected?.pr.metadata?.number)).post()
    }
    /// A request that failed without a recorded outcome (e.g. "Enable auto-merge failed"); the error also stays on screen.
    private func announceFailure(_ what:String,_ error:any Error) {
        AccessibilityNotification.Announcement(Self.failureAnnouncement(what,number:selected?.pr.metadata?.number,reason:error.localizedDescription)).post()
    }
    /// "Pull request #12: Added to the merge queue", or, before GitHub reports an outcome, "Pull request #12: Enable
    /// auto-merge — Outcome unknown".
    static func outcomeAnnouncement(_ outcome:MergeOutcome?,state:PRWriteOperation.State,message:String?,action:MergeAction,number:Int?) -> String {
        let result=outcome.map(ProviderStateText.mergeOutcome) ?? actionName(action)+" — "+ProviderStateText.writeState(state)
        return subject(number)+[result,message].compactMap { $0 }.joined(separator:". ")
    }
    static func failureAnnouncement(_ what:String,number:Int?,reason:String) -> String { subject(number)+what+". "+reason }
    static func actionName(_ action:MergeAction) -> String {
        switch action { case .direct:"Merge";case .queue:"Add to merge queue";case .enableAutoMerge:"Enable auto-merge";case .disableAutoMerge:"Disable auto-merge";case .removeQueue:"Remove from merge queue";case .updateBranch:"Update branch" }
    }
    private static func subject(_ number:Int?) -> String { number.map { "Pull request #\($0): " } ?? "" }
    /// A provider-confirmed outcome closes the sheet (the workspace keeps the result in its status line); pending,
    /// uncertain, rejected or outdated results stay visible with the reconcile controls.
    private func closeIfConfirmed(_ operation:PRWriteOperation,key:ProviderKey,request:UUID) {
        guard operation.state == .confirmed,identity.accepts(key,request:request,available:available) else { return }
        workspace?.status=(selected.map { "#\(String($0.pr.metadata?.number ?? 0)): " } ?? "")+ProviderStateText.mergeOperation(operation)
        dismiss()
    }
}
private extension Optional { func unwrap() throws -> Wrapped { guard let value=self else { throw PRWriteFailure.unavailable };return value } }
