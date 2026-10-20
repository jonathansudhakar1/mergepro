import AppKit
import SwiftUI
import MergeProCore

/// Repositories → Labels: the repository account's label catalog with explicit create, edit and delete.
/// Writes run only as the active account; an unconfirmed mutation is reconciled from a fresh catalog, never resent.
struct RepoLabelsView:View {
    let repository:RepoCatalogEntry
    let service:RepositoryBrowserService
    /// Label writes use the active account, so other accounts' repositories stay read-only here.
    var canWrite=true
    /// Renames, recolors and deletes change PR chips without bumping the PRs; the next cycle's open-PR read picks them up.
    /// Started, never awaited: the editor closes and `busy` clears right after the label write, not after a full poll.
    var labelsChanged:() async -> Void = {}
    enum Sort:String,CaseIterable { case name="Name",mostUsed="Most used" }
    struct EditorTarget:Identifiable { let id=UUID();let label:RepositoryLabel? }
    @State private var catalog:RepositoryLabelCatalog?
    @State private var loading=false
    @State private var error:String?
    @State private var search=""
    @State private var sort=Sort.name
    @State private var editor:EditorTarget?
    @State private var deleteCandidate:RepositoryLabel?
    @State private var pending:[RepositoryLabelMutation]=[]
    @State private var busy=false
    @State private var reconciled:(message:String,applied:Bool)?
    @State private var editingUnavailable=false

    private var canManage:Bool { canWrite && catalog?.canManage == true }
    private var labelsURL:URL { repository.webURL.appendingPathComponent("labels") }
    private var manageHelp:String {
        if !canWrite { return "Switch the active account to \(repository.accountLogin) to manage labels" }
        if catalog?.canManage == false { return "\(repository.accountLogin) needs triage access or higher to manage labels" }
        return "Create a label"
    }
    private var visible:[RepositoryLabel] {
        let query=search.trimmingCharacters(in:.whitespacesAndNewlines)
        let labels=(catalog?.labels ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.description?.localizedCaseInsensitiveContains(query) == true }
        switch sort {
        case .name:return labels.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .mostUsed:return labels.sorted { a,b in
            // Unknown counts sort last rather than being treated as zero.
            let x=a.openPullRequests ?? -1,y=b.openPullRequests ?? -1
            return x != y ? x>y : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        }
    }
    var body:some View {
        VStack(spacing:0) {
            ViewThatFits(in:.horizontal) {
                HStack(spacing:12) { heading;Spacer(minLength:8);actions }
                VStack(alignment:.leading,spacing:10) { heading;actions }
            }.frame(maxWidth:.infinity,alignment:.leading).padding(16).background(Color(nsColor:.windowBackgroundColor))
            notices
            content
        }
        .task(id:repository.key) { await load() }
        .onChange(of:error) { _,message in if let message { AccessibilityNotification.Announcement(message).post() } }
        .confirmationDialog("Delete label “\(deleteCandidate?.name ?? "")”?",isPresented:Binding(get:{ deleteCandidate != nil },set:{ if !$0 { deleteCandidate=nil } }),titleVisibility:.visible) {
            if let label=deleteCandidate { Button("Delete Label",role:.destructive) { Task { await delete(label) } }.accessibilityIdentifier("repoLabelDeleteConfirm") }
            Button("Cancel",role:.cancel) { deleteCandidate=nil }
        } message:{ Text(deleteMessage(deleteCandidate)) }
        .sheet(item:$editor) { target in
            RepoLabelEditorSheet(label:target.label,existing:catalog?.labels ?? [],labelsURL:labelsURL) { await submit($0) }
        }
    }
    private var heading:some View {
        VStack(alignment:.leading,spacing:4) {
            Label("Labels",systemImage:"tag").font(.system(.headline,design:.rounded)).foregroundStyle(DesignTokens.cobalt)
            Text(countText).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var countText:String {
        guard let catalog else { return loading ? "Reading labels…" : "Labels not loaded" }
        let count=catalog.labels.count
        return (count == 1 ? "1 label" : "\(count) labels")+(catalog.complete ? "" : " read · more on GitHub")+(canManage ? " · create, edit and delete" : " · read only")
    }
    private var actions:some View {
        HStack(spacing:8) {
            if loading || busy { ProgressView().controlSize(.small) }
            TextField("Search labels",text:$search).textFieldStyle(.roundedBorder).frame(width:180).accessibilityIdentifier("repoLabelsSearch")
            Picker("Sort",selection:$sort) { ForEach(Sort.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize().help("Sort labels").accessibilityIdentifier("repoLabelsSort")
            Button { Task { await load() } } label:{ Image(systemName:"arrow.clockwise") }.help("Refresh Labels").accessibilityLabel("Refresh labels").disabled(loading)
            Button { editor = .init(label:nil) } label:{ Label("New Label",systemImage:"plus") }
                .buttonStyle(.borderedProminent).tint(DesignTokens.cobalt).disabled(!canManage || busy).help(manageHelp).accessibilityIdentifier("repoLabelsNew")
        }.controlSize(.small).fixedSize(horizontal:true,vertical:false)
    }
    @ViewBuilder private var notices:some View {
        let any=error != nil || reconciled != nil || editingUnavailable || !pending.isEmpty || catalog.map { !$0.complete || !$0.canManage || !canWrite } == true
        if any {
            VStack(alignment:.leading,spacing:8) {
                if let error {
                    HStack(alignment:.top) { WorkspaceNotice(message:error,symbol:"exclamationmark.circle",tint:.red);Button("Dismiss") { self.error=nil }.padding(.top,12) }
                }
                if let reconciled {
                    HStack(alignment:.top) {
                        WorkspaceNotice(message:reconciled.message,symbol:reconciled.applied ? "checkmark.circle" : "exclamationmark.triangle",tint:reconciled.applied ? .green : .orange)
                        Button("Dismiss") { self.reconciled=nil }.padding(.top,12)
                    }
                }
                if editingUnavailable {
                    HStack(alignment:.top) { WorkspaceNotice(message:RepositoryLabelFailure.labelEditingUnavailable.errorDescription ?? "",symbol:"exclamationmark.triangle",tint:.orange);Button("Edit on GitHub") { ExternalLinkPolicy.open(labelsURL) }.buttonStyle(.link).padding(.top,12) }
                }
                ForEach(pending) { mutation in
                    HStack(alignment:.top) {
                        WorkspaceNotice(message:"GitHub did not confirm: "+describe(mutation)+". Reconcile before changing this label again.",symbol:"exclamationmark.triangle",tint:.orange)
                        Button("Reconcile") { Task { await reconcile(mutation) } }.disabled(busy).padding(.top,12).accessibilityIdentifier("repoLabelReconcile")
                    }
                }
                if let catalog {
                    if !catalog.canManage { WorkspaceNotice(message:"\(repository.accountLogin) can view these labels but needs triage access or higher to change them.",symbol:"lock") }
                    else if !canWrite { WorkspaceNotice(message:"Labels are changed with the active account. Switch the active account to \(repository.accountLogin) to edit them.",symbol:"person.crop.circle.badge.exclamationmark") }
                    if !catalog.complete {
                        HStack(alignment:.top) { WorkspaceNotice(message:"This repository has more labels than MergePro reads at once. Labels not listed here are unknown, not absent.",symbol:"info.circle");Button("Open on GitHub") { ExternalLinkPolicy.open(labelsURL) }.buttonStyle(.link).padding(.top,12) }
                    }
                }
            }.padding(.horizontal,16).padding(.top,10)
        }
    }
    @ViewBuilder private var content:some View {
        if catalog == nil {
            if loading { ProgressView("Reading labels…").frame(maxWidth:.infinity,maxHeight:.infinity) }
            else { ContentUnavailableView { Label("Labels Unavailable",systemImage:"tag.slash") } description:{ Text("Refresh to read this repository's labels.") } actions:{ Button("Refresh") { Task { await load() } } }.frame(maxHeight:.infinity) }
        } else if visible.isEmpty {
            ContentUnavailableView(search.isEmpty ? "No Labels" : "No Matching Labels",systemImage:search.isEmpty ? "tag" : "magnifyingglass",description:Text(search.isEmpty ? (canManage ? "Create a label to categorize pull requests and issues." : "This repository has no labels yet.") : "Try a different search.")).frame(maxHeight:.infinity)
        } else {
            List {
                ForEach(visible) { label in row(label).listRowSeparator(.hidden) }
            }.listStyle(.inset).scrollContentBackground(.hidden).accessibilityIdentifier("repoLabelsList")
        }
    }
    private func row(_ label:RepositoryLabel) -> some View {
        HStack(alignment:.center,spacing:12) {
            VStack(alignment:.leading,spacing:6) {
                LabelChip(name:label.name,hex:label.color)
                Text(label.description ?? "No description").font(.callout).foregroundStyle(label.description == nil ? .tertiary : .secondary).lineLimit(2).textSelection(.enabled)
            }
            Spacer(minLength:8)
            WorkspaceStatusBadge(text:openPRText(label.openPullRequests),symbol:"arrow.triangle.pull",tint:(label.openPullRequests ?? 0)>0 ? DesignTokens.cobalt : .secondary)
            HStack(spacing:6) {
                Button("Edit") { editor = .init(label:label) }.disabled(!canManage || busy).help(canManage ? "Edit \(label.name)" : manageHelp).accessibilityIdentifier("repoLabelEdit-\(label.name)")
                Button("Delete",role:.destructive) { deleteCandidate=label }.disabled(!canManage || busy).help(canManage ? "Delete \(label.name)" : manageHelp).accessibilityIdentifier("repoLabelDelete-\(label.name)")
            }.controlSize(.small).fixedSize()
        }
        .padding(12).workspacePanel(radius:12).padding(.vertical,3)
        .contextMenu {
            Button("Edit…") { editor = .init(label:label) }.disabled(!canManage)
            Button("Copy Name") { NSPasteboard.general.clearContents();NSPasteboard.general.setString(label.name,forType:.string) }
            Divider()
            Button("Delete…",role:.destructive) { deleteCandidate=label }.disabled(!canManage)
        }
        .accessibilityElement(children:.contain)
        .accessibilityIdentifier("repoLabelRow-\(label.name)")
    }
    private func openPRText(_ count:Int?) -> String { count.map { $0 == 1 ? "1 open PR" : "\($0) open PRs" } ?? "Open PRs unknown" }
    private func deleteMessage(_ label:RepositoryLabel?) -> String {
        guard let count=label?.openPullRequests else { return "Removes it from every pull request and issue that uses it. This can't be undone." }
        return "Removes it from \(count == 1 ? "1 open PR" : "\(count) open PRs") and all issues. This can't be undone."
    }
    private static func done(_ mutation:RepositoryLabelMutation) -> String {
        switch mutation {
        case .create(let name,_,_):"Created label “\(name)”"
        case .update(_,let name,_,_):"Saved label “\(name)”"
        case .delete(_,let name):"Deleted label “\(name)”"
        }
    }
    private func describe(_ mutation:RepositoryLabelMutation) -> String {
        switch mutation {
        case .create(let name,_,_):"create label “\(name)”"
        case .update(_,let name,_,_):"update label “\(name)”"
        case .delete(_,let name):"delete label “\(name)”"
        }
    }
    private func load() async {
        loading=true;defer { loading=false }
        if catalog == nil,let cached=try? await service.cachedLabels(repository),!Task.isCancelled { catalog=cached }
        do { let fresh=try await service.labels(repository);guard !Task.isCancelled else { return };catalog=fresh;error=nil }
        catch { if !Task.isCancelled { self.error=providerErrorMessage(error) } }
        await loadPending()
    }
    private func loadPending() async {
        do { let values=try await service.pendingLabelMutations(repository);guard !Task.isCancelled else { return };pending=values }
        catch { if !Task.isCancelled { self.error=providerErrorMessage(error) } }
    }
    /// A confirmed receipt patches the cached catalog, so the list updates without another read.
    private func reloadAfterWrite() async {
        if let cached=try? await service.cachedLabels(repository) { catalog=cached } else { await load() }
        await loadPending()
    }
    private func refreshPRs() { let labelsChanged=labelsChanged;Task { await labelsChanged() } }
    private func submit(_ mutation:RepositoryLabelMutation) async -> RepoLabelEditorSheet.Outcome {
        busy=true;defer { busy=false };reconciled=nil
        do {
            _ = try await service.apply(mutation,to:repository);await reloadAfterWrite()
            if case .create = mutation {} else { refreshPRs() }
            AccessibilityNotification.Announcement(Self.done(mutation)).post()
            return .done
        }
        catch RepositoryLabelFailure.labelEditingUnavailable { editingUnavailable=true;return .unavailable }
        catch RepositoryBrowserFailure.unknownWriteOutcome { await loadPending();AccessibilityNotification.Announcement("GitHub did not confirm: "+describe(mutation)+". Reconcile before changing this label again.").post();return .unconfirmed }
        catch { await loadPending();return .failed(providerErrorMessage(error)) }
    }
    private func delete(_ label:RepositoryLabel) async {
        deleteCandidate=nil;busy=true;defer { busy=false };reconciled=nil
        do { _ = try await service.apply(.delete(id:label.id,name:label.name),to:repository);await reloadAfterWrite();refreshPRs();AccessibilityNotification.Announcement(Self.done(.delete(id:label.id,name:label.name))).post() }
        catch RepositoryLabelFailure.labelEditingUnavailable { editingUnavailable=true }
        catch { self.error=providerErrorMessage(error);await loadPending() }
    }
    private func reconcile(_ mutation:RepositoryLabelMutation) async {
        busy=true;defer { busy=false }
        do {
            let result=try await service.reconcileLabel(mutation,in:repository)
            reconciled=result == .applied ? ("GitHub confirms “"+describe(mutation)+"” applied.",true) : ("“"+describe(mutation)+"” did not apply. Review the labels and make the change again if needed.",false)
            AccessibilityNotification.Announcement(reconciled?.message ?? "").post()
            await reloadAfterWrite()
            if result == .applied { if case .create = mutation {} else { refreshPRs() } }
        } catch { self.error=providerErrorMessage(error);await loadPending() }
    }
}

/// Create or edit one repository label with a live preview. Validation mirrors GitHub:
/// 1–50 character names unique without case, a 6-digit hex color and at most 100 characters of description.
struct RepoLabelEditorSheet:View {
    enum Outcome { case done,unconfirmed,unavailable,failed(String) }
    let label:RepositoryLabel?
    let existing:[RepositoryLabel]
    let labelsURL:URL
    let submit:(RepositoryLabelMutation) async -> Outcome
    @Environment(\.dismiss) private var dismiss
    @State private var name:String
    @State private var hex:String
    @State private var text:String
    @State private var busy=false
    @State private var failure:String?
    @State private var unavailable=false
    init(label:RepositoryLabel?,existing:[RepositoryLabel],labelsURL:URL,submit:@escaping (RepositoryLabelMutation) async -> Outcome) {
        self.label=label;self.existing=existing;self.labelsURL=labelsURL;self.submit=submit
        _name=State(initialValue:label?.name ?? "");_hex=State(initialValue:label?.color ?? LabelPalette.random());_text=State(initialValue:label?.description ?? "")
    }
    private var trimmedName:String { name.trimmingCharacters(in:.whitespacesAndNewlines) }
    private var trimmedText:String { text.trimmingCharacters(in:.whitespacesAndNewlines) }
    private var color:String? { RepositoryLabel.normalizedColor(hex) }
    private var duplicate:RepositoryLabel? { let key=trimmedName.lowercased();return existing.first { $0.name.lowercased() == key && $0.id != label?.id } }
    private var nameProblem:String? {
        if name.isEmpty { return nil }
        if !RepositoryLabel.validName(name) { return "Use 1–50 characters without line breaks." }
        if let duplicate { return "A label named “\(duplicate.name)” already exists. Label names aren't case-sensitive." }
        return nil
    }
    private var valid:Bool { RepositoryLabel.validName(name) && duplicate == nil && color != nil && trimmedText.count<=100 }
    private var changed:Bool { label.map { $0.name != trimmedName || $0.color != color || ($0.description ?? "") != trimmedText } ?? true }
    private var colorBinding:Binding<Color> {
        Binding(get:{ Color(labelHex:hex) ?? Color(labelHex:label?.color) ?? .gray },set:{ if let value=LabelPalette.hex($0) { hex=value } })
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Label(label == nil ? "New Label" : "Edit Label",systemImage:"tag").font(.system(.title2,design:.rounded).bold()).foregroundStyle(DesignTokens.cobalt)
            HStack(spacing:10) {
                Text("Preview").font(.caption).foregroundStyle(.secondary)
                LabelChip(name:trimmedName.isEmpty ? "Label preview" : trimmedName,hex:color).accessibilityIdentifier("repoLabelEditorPreview")
                Spacer(minLength:0)
            }
            .padding(12).frame(maxWidth:.infinity,alignment:.leading)
            .background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:10))
            .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(Color(nsColor:.separatorColor).opacity(0.6),lineWidth:1).allowsHitTesting(false))
            Grid(alignment:.leadingFirstTextBaseline,horizontalSpacing:12,verticalSpacing:8) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    TextField("Label name",text:$name).textFieldStyle(.roundedBorder).accessibilityIdentifier("repoLabelEditorName")
                }
                if let nameProblem { GridRow { Color.clear.gridCellUnsizedAxes([.horizontal,.vertical]);warning(nameProblem) } }
                GridRow {
                    Text("Color")
                    HStack(spacing:8) {
                        ColorPicker("Color",selection:colorBinding,supportsOpacity:false).labelsHidden().accessibilityIdentifier("repoLabelEditorColor")
                        TextField("rrggbb",text:$hex).textFieldStyle(.roundedBorder).font(.system(.body,design:.monospaced)).frame(width:96).accessibilityIdentifier("repoLabelEditorHex")
                        Button { hex=LabelPalette.random(excluding:color) } label:{ Label("Random",systemImage:"dice") }.accessibilityIdentifier("repoLabelEditorRandom")
                    }
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal,.vertical])
                    HStack(spacing:5) {
                        ForEach(LabelPalette.swatches,id:\.self) { swatch in
                            Button { hex=swatch } label:{
                                Circle().fill(Color(labelHex:swatch) ?? .gray).frame(width:16,height:16)
                                    .overlay(Circle().strokeBorder(color == swatch ? Color.primary : Color.primary.opacity(0.12),lineWidth:color == swatch ? 2 : 1))
                            }.buttonStyle(.plain).help("#"+swatch).accessibilityLabel("Color #"+swatch)
                        }
                    }
                }
                if color == nil { GridRow { Color.clear.gridCellUnsizedAxes([.horizontal,.vertical]);warning("Enter a 6-digit hex color, like d73a4a.") } }
                GridRow {
                    Text("Description")
                    TextField("Optional",text:$text,axis:.vertical).lineLimit(1...3).textFieldStyle(.roundedBorder).accessibilityIdentifier("repoLabelEditorDescription")
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal,.vertical])
                    HStack {
                        if trimmedText.count>100 { warning("Use at most 100 characters.") }
                        Spacer()
                        Text("\(trimmedText.count)/100").monospacedDigit().foregroundStyle(.secondary).accessibilityLabel("\(trimmedText.count) of 100 characters")
                    }.font(.caption)
                }
            }
            if let failure { WorkspaceNotice(message:failure,symbol:"exclamationmark.circle",tint:.red) }
            if unavailable {
                HStack(alignment:.top) { WorkspaceNotice(message:RepositoryLabelFailure.labelEditingUnavailable.errorDescription ?? "",symbol:"exclamationmark.triangle",tint:.orange);Button("Edit on GitHub") { ExternalLinkPolicy.open(labelsURL) }.buttonStyle(.link).padding(.top,12) }
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(label == nil ? "Create Label" : "Save Changes") { Task { await save() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(DesignTokens.cobalt)
                    .disabled(!valid || !changed || busy || unavailable).accessibilityIdentifier("repoLabelEditorSave")
            }
        }.padding(24).frame(width:480).background { WorkspaceCanvas() }
        .onExitCommand { if !busy { dismiss() } }
        .onChange(of:failure) { _,message in if let message { AccessibilityNotification.Announcement(message).post() } }
    }
    /// Validation text stays readable secondary text; the orange stays on the icon.
    private func warning(_ message:String) -> some View {
        Label { Text(message).foregroundStyle(.secondary) } icon:{ Image(systemName:"exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true) }.font(.caption)
    }
    private func save() async {
        guard valid,changed,!busy,let color else { return }
        let description=trimmedText.isEmpty ? nil : trimmedText
        let mutation:RepositoryLabelMutation=label.map { .update(id:$0.id,name:trimmedName,color:color,description:description) } ?? .create(name:trimmedName,color:color,description:description)
        busy=true;failure=nil
        let outcome=await submit(mutation)
        busy=false
        switch outcome {
        case .done,.unconfirmed:dismiss()
        case .unavailable:unavailable=true
        case .failed(let message):failure=message
        }
    }
}
