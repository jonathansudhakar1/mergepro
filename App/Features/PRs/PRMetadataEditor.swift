import MergeProCore
import SwiftUI

/// Every field opens prefilled with the provider's current value. Lists never use replace-all writes:
/// labels, assignees and review requests are delta pickers by node ID, so unrelated values survive.
struct PRMetadataEditor:View {
    let readPR:PullRequest
    let storage:SetupStorage
    var workspace:PRWorkspaceModel? = nil
    let account:PRDetailAccountModel
    var initialField="Title"
    @State private var loadState=PRActionLoadState()
    @State private var operationRevision=0
    @State private var loadError:String?
    private var actionAvailable:Bool { loadState.key.map { workspace == nil || workspace?.cached($0) != nil } ?? true }
    var didWrite:(@MainActor () -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var pr:PullRequest?
    @State private var revision:PRWriteRevision?
    @State private var field="Title"
    @State private var value=""
    /// Provider values for prefill; a missing key is unknown, not empty.
    @State private var current:[String:String]=[:]
    @State private var removeReviewers=false
    @State private var preview=false
    @State private var labelsPresented=false
    @State private var status:String?
    @State private var login=""
    @State private var busy=false
    @State private var draft:ReviewDraft?
    @State private var saveConflict=false
    @State private var draftSaveBusy=false
    @State private var draftSavePending=false
    /// Return in the description inserts a newline; it must never reach the apply button.
    @FocusState private var bodyFocused:Bool
    private static let textFields:Set<String>=["Title","Body","Base branch","Milestone","Teams"]
    private static let pickerFields:Set<String>=["Labels","Assignees","Reviewers"]
    private let fields=["Title","Body","Base branch","Labels","Assignees","Reviewers","Teams","Milestone","Convert to draft","Ready for review","Close","Reopen"]
    var body:some View {
        Group {
            if actionAvailable {
                if loadState.canDisplay(pr?.key,available:true) { content }
                else { replacement }
            }
            else { ContentUnavailableView { Label("Action account unavailable",systemImage:"lock") } description: { Text("Reconnect the selected account. Drafts remain on disk.") } actions: { Button("Try Again") { Task { await load() } } } }
        }.onChange(of:actionAvailable) { if !actionAvailable { invalidateAction() } }
        .task { field=initialField;await load() }
    }
    private var replacement:some View {
        VStack(spacing:12) {
            if busy { ProgressView("Reading selected action account…") }
            else { Text(loadError ?? "Selected account data unavailable") }
            Button("Try Again") { Task { await load() } }.disabled(busy || draftSaveBusy);Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding()
    }
    private var restored:Bool { Self.textFields.contains(field) && draftText(field) != nil }
    private var writeBlocked:Bool { busy || saveConflict || draftSaveBusy || pr == nil || revision == nil }
    private var content:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(alignment:.firstTextBaseline) {
                Text("Pull request metadata").font(.system(.title2,design:.rounded).bold())
                Spacer()
                Text("as \(login)").font(.callout).foregroundStyle(.secondary)
            }
            if saveConflict { Text("Another editor saved this draft. Local text remains here; copy or resolve it before explicitly reloading the saved draft.").foregroundStyle(.orange) }
            if let status { Text(status).foregroundStyle(.secondary).textSelection(.enabled) }
            if let pr { operationStatus(pr.key) }
            HStack {
                Picker("Change",selection:$field) { ForEach(fields,id:\.self) { Text($0) } }.fixedSize().accessibilityIdentifier("metadataField")
                Spacer()
                Button("Reload saved draft") { Task { await load() } }.disabled(busy || draftSaveBusy).controlSize(.small)
            }.onChange(of:field) { value=fieldValue(field);preview=false }
            Group {
                if Self.pickerFields.contains(field) { picker }
                else if Self.textFields.contains(field) { editor }
                else { Text(stateDescription).foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:80,alignment:.topLeading) }
            }.frame(maxHeight:.infinity,alignment:.top)
            if !Self.pickerFields.contains(field) {
                Text("This changes the selected account's provider object after fresh permission and revision checks.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Close editor") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(field == "Close" ? "Close pull request" : field == "Reopen" ? "Reopen pull request" : "Apply change") { Task { await apply() } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(bodyFocused ? nil : .defaultAction)
                        .disabled(writeBlocked || unchanged || (try? mutation()) == nil).accessibilityIdentifier("applyMetadata")
                }
            } else { HStack { Button("Close editor") { dismiss() }.keyboardShortcut(.cancelAction);Spacer() } }
        }.padding(20).frame(width:660,height:620).onChange(of:value) { saveText() }
    }
    @ViewBuilder private var editor:some View {
        HStack(spacing:8) {
            if restored { Label("Restored unsent draft text",systemImage:"clock.arrow.circlepath").font(.caption).foregroundStyle(.orange) }
            else if current[field] == nil,field != "Teams" { Label("Current value unknown",systemImage:"questionmark.circle").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if let known=current[field],value != known { Button("Reset to current value") { value=known }.controlSize(.small) }
            if field == "Body" { Toggle("Preview",isOn:$preview).toggleStyle(.checkbox).controlSize(.small) }
        }
        switch field {
        case "Body":
            if preview { ScrollView { MarkdownView(source:value,webURL:pr?.metadata?.webURL) }.frame(height:300).border(.separator) }
            else { TextEditor(text:$value).font(.body).frame(height:300).border(.separator).focused($bodyFocused).accessibilityLabel("Description").accessibilityIdentifier("metadataBody") }
        case "Teams":
            TextField("Team slugs to request (comma-separated)",text:$value).textFieldStyle(.roundedBorder).accessibilityIdentifier("metadataValue")
            Toggle("Remove these team requests instead",isOn:$removeReviewers).toggleStyle(.checkbox)
            Text("Team requests add or remove only the named teams; other requests are kept. People are requested in Reviewers.").font(.caption).foregroundStyle(.secondary)
        case "Milestone":
            TextField("Milestone number",text:$value).textFieldStyle(.roundedBorder).accessibilityIdentifier("metadataValue")
            HStack(spacing:8) {
                Text(milestoneDescription).font(.caption).foregroundStyle(.secondary)
                Spacer()
                // The only way to clear: explicit, and only over a milestone known to exist. An empty field never clears.
                if milestoneSet { Button("Clear milestone",systemImage:"xmark.circle") { Task { await apply(clearMilestone:true) } }.controlSize(.small).disabled(writeBlocked).accessibilityIdentifier("clearMilestone") }
            }
        default:
            TextField(field,text:$value,axis:.vertical).lineLimit(1...4).textFieldStyle(.roundedBorder).accessibilityIdentifier("metadataValue")
        }
    }
    @ViewBuilder private var picker:some View {
        switch field {
        case "Labels":
            VStack(alignment:.leading,spacing:10) {
                Text("Labels").font(.headline)
                if let labels=(pr ?? readPR).metadata?.labels,!labels.isEmpty { LabelChipRow(labels:labels,colors:(pr ?? readPR).metadata?.labelColors,limit:12) }
                else { Text((pr ?? readPR).metadata == nil ? "Labels unknown" : "No labels").foregroundStyle(.secondary) }
                Button("Edit labels…",systemImage:"tag") { labelsPresented=true }.accessibilityIdentifier("editLabels")
                    .popover(isPresented:$labelsPresented,arrowEdge:.bottom) { PRLabelPicker(pr:readPR,storage:storage,workspace:workspace,didWrite:{ status="Labels updated.";didWrite?() }) }
                Text("Labels change as one add/remove delta; labels added elsewhere are kept.").font(.caption).foregroundStyle(.secondary)
            }
        case "Assignees":PRAssigneePicker(account:account,didWrite:{ status="Assignees updated.";didWrite?() })
        default:PRReviewerRequestPicker(account:account,author:(pr ?? readPR).metadata?.authorLogin,didWrite:{ status="Review requests updated.";didWrite?() })
        }
    }
    private var stateDescription:String {
        switch field {
        case "Convert to draft":"Converts this pull request to a draft. Reviewers are not notified until it is ready again."
        case "Ready for review":"Marks this draft ready for review and notifies requested reviewers."
        case "Close":"Closes this pull request without merging. It can be reopened."
        default:"Reopens this closed pull request."
        }
    }
    private var milestoneTitle:String? { current["Milestone title"] }
    /// Evidence of a milestone: a known number or the provider's title. Unknown is never "set".
    private var milestoneSet:Bool { current["Milestone"].map { !$0.isEmpty } ?? (milestoneTitle != nil) }
    private var milestoneDescription:String {
        if let milestone=milestoneTitle { return "Current: "+milestone }
        guard let number=current["Milestone"] else { return "Enter a milestone number to set one; an unknown milestone is never cleared." }
        return number.isEmpty ? "No milestone" : "Current: milestone \(number)"
    }
    /// Text fields are disabled while their value equals the provider's current value. Over an unknown current value
    /// nothing applies until a non-empty value is typed; title, description and base are never written over one.
    private var unchanged:Bool {
        guard Self.textFields.contains(field),field != "Teams" else { return false }
        guard let known=current[field] else { return ["Title","Body","Base branch"].contains(field) || value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
        return known == value
    }
    /// A saved draft, except an empty one over an unknown value: that was only ever the empty prefill.
    private func draftText(_ name:String) -> String? { draft?.texts["metadata:"+name].flatMap { $0.isEmpty && current[name] == nil ? nil : $0 } }
    private func fieldValue(_ name:String) -> String { draftText(name) ?? current[name] ?? "" }
    private func operationStatus(_ key:ProviderKey) -> some View {
        let request=loadState.presentationRequest(for:key,available:actionAvailable)
        return PRWriteStatusView(key:key,storage:storage,changeSignal:operationRevision) {
            guard let request,!busy,loadState.accepts(key,request:request,available:actionAvailable),loadState.canDisplay(key,available:actionAvailable) else { return }
            await load()
        }.id(key)
    }
    private func invalidateAction() { loadState.invalidate();busy=false;draftSaveBusy=false;draftSavePending=false;pr=nil;revision=nil;draft=nil;value="";current=[:];login="";status="Action account unavailable. Drafts retained on disk." }
    private func load() async {
        guard !draftSaveBusy else { return }
        let request=loadState.begin();loadError=nil;busy=true;defer { if loadState.isCurrent(request) { busy=false } }
        do {
            let selected=try await storage.detailActionPR(readPR);loadState.select(selected.key,request:request)
            guard loadState.accepts(selected.key,request:request,available:actionAvailable) else { return }
            // The window revalidated moments ago; reuse that read unless it is older than two minutes.
            let detail=try await storage.detail(selected,maxAge:120),accountLogin=try await storage.actionLogin(selected.key),saved=try await storage.reviewDraft(selected.key) ?? ReviewDraft(key:selected.key,revision:PRWriteRevision(detail))
            let overview=try? await storage.cachedDetailSection(selected,tab:.overview)?.overview
            guard loadState.accepts(selected.key,request:request,available:actionAvailable) else { return }
            guard loadState.present(selected.key,request:request,available:actionAvailable) else { return }
            var values:[String:String]=["Title":selected.title]
            if detail.bodyFetchedAt != nil || !detail.cached { values["Body"]=detail.body }
            if let base=selected.metadata?.baseBranch,!base.isEmpty { values["Base branch"]=base }
            if let overview,overview.milestoneKnown {
                if let milestone=overview.milestone {
                    values["Milestone title"]=milestone.title+(milestone.state.map { " · "+$0.lowercased() } ?? "")
                    if let number=milestone.url.flatMap({ Int($0.lastPathComponent) }) { values["Milestone"]=String(number) }
                } else { values["Milestone"]="" }
            }
            // Empty drafts over unknown values are discarded, never restored as unsent text.
            let prefills=saved.texts.filter { $0.key.hasPrefix("metadata:") && $0.value.isEmpty && values[String($0.key.dropFirst("metadata:".count))] == nil }.keys
            var restoredDraft=saved;for key in prefills { restoredDraft.texts[key]=nil }
            pr=selected;revision=PRWriteRevision(detail);login=accountLogin;draft=restoredDraft;current=values;value=fieldValue(field);saveConflict=false;status=nil
            if !prefills.isEmpty { persistDraft() }
        } catch { if loadState.fail(request:request) { busy=false;loadError=error.localizedDescription } }
    }
    /// Only text that differs from the provider value is kept as a draft; prefill never becomes a draft. Over an
    /// unknown value the empty prefill is not a draft either, so switching to such a field saves nothing.
    private func saveText() {
        guard var draft,Self.textFields.contains(field) else { return }
        let key="metadata:"+field,known=current[field] ?? (field == "Teams" ? "" : nil)
        let next:String? = value == known || known == nil && value.isEmpty ? nil : value
        guard draft.texts[key] != next else { return }
        draft.texts[key]=next;self.draft=draft;persistDraft()
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
    private func mutation() throws -> PRMetadataMutation {
        let values=value.split(separator:",").map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty }
        switch field {
        case "Title":guard !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw PRWriteFailure.unavailable };return .title(value)
        case "Body":return .body(value)
        case "Base branch":guard !value.trimmingCharacters(in:.whitespaces).isEmpty else { throw PRWriteFailure.unavailable };return .base(value.trimmingCharacters(in:.whitespaces))
        case "Milestone":guard let number=Int(value.trimmingCharacters(in:.whitespaces)),number>0 else { throw PRWriteFailure.unavailable };return .milestone(number)
        case "Teams":guard !values.isEmpty else { throw PRWriteFailure.unavailable };return .reviewers(users:[],teams:values,remove:removeReviewers)
        case "Convert to draft":return .draft(true)
        case "Ready for review":return .draft(false)
        case "Close":return .closed(true)
        case "Reopen":return .closed(false)
        default:throw PRWriteFailure.unavailable
        }
    }
    private func apply(clearMilestone:Bool=false) async {
        guard let capturedPR=pr,let metadata=capturedPR.metadata,let revision,let request=loadState.presentationRequest(for:capturedPR.key,available:actionAvailable),!clearMilestone || milestoneSet else { return }
        let capturedField=clearMilestone ? "Milestone" : field,capturedValue=clearMilestone ? "" : value
        busy=true
        defer { loadState.publish(capturedPR.key,request:request,available:actionAvailable) { busy=false;operationRevision += 1 } }
        do {
            guard !saveConflict,!draftSaveBusy else { throw PRWriteFailure.draftChanged }
            let command=PRWriteCommand(key:capturedPR.key,repository:metadata.repositoryName,number:metadata.number,revision:revision,intent:.metadata(clearMilestone ? .milestone(nil) : try mutation()))
            let capturedDraft=draft
            if let capturedDraft { try await storage.saveReviewDraft(capturedDraft) }
            let result=try await storage.performWrite(command)
            loadState.publish(capturedPR.key,request:request,available:actionAvailable) {
                status=result.state == .confirmed ? "Provider confirmed metadata change." : "\(prWriteStateText(result.state)). Read the provider result before retrying; nothing was resent."
                guard result.state == .confirmed else { return }
                // The applied text is now the provider value, so it is no longer an unsent draft.
                if Self.textFields.contains(capturedField),capturedField != "Teams" { current[capturedField]=capturedValue;if capturedField == "Milestone" { current["Milestone title"]=nil } }
                // Text typed meanwhile (or a number typed before Clear milestone) differs from what was applied and stays a draft.
                if var saved=draft,saved.texts["metadata:"+capturedField] == capturedValue { saved.texts["metadata:"+capturedField]=nil;draft=saved;persistDraft() }
                if capturedField == "Teams" { value="" }
                didWrite?()
            }
        } catch { loadState.publish(capturedPR.key,request:request,available:actionAvailable) { status=error.localizedDescription } }
    }
}
