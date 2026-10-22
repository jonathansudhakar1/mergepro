import SwiftUI
import MergeProCore
struct WorkflowRunSheet:View {
    let storage:SetupStorage
    let repository:Repository
    let workflow:ActionsWorkflow
    let environments:[ActionsEnvironment]
    var preset:WorkflowPreset?=nil
    var environmentError:String?=nil
    @Environment(\.dismiss) private var dismiss
    @State private var ref=""
    /// The ref search field; it differs from `ref` while the user is typing a new branch or tag name.
    @State private var refQuery=""
    @State private var matches:WorkflowRefMatches?
    @State private var searchingRefs=false
    @State private var browsingRefs=false
    /// Read live when the form has an environment input, since dispatch admission validates against the live list.
    @State private var liveEnvironments:[ActionsEnvironment]?
    @State private var schema:WorkflowInputSchema?
    @State private var values:[String:WorkflowInputValue]=[:]
    @State private var error:String?
    @State private var loading=false
    @State private var sending=false
    @State private var confirmProduction=false
    @State private var presetName=""
    @State private var receipt:ActionsWriteOperation?
    @State private var status:String?
    /// Number fields keep the typed text, since re-rendering a parsed Double would drop a trailing "." or "0" while typing.
    @State private var numberDrafts:[String:String]=[:]
    /// Return in an input moves to the next text input (and in the preset name does nothing); it never runs the
    /// workflow. Return runs it only when no text input has focus; ⌘Return runs it from anywhere.
    @FocusState private var focus:Field?
    private enum Field:Hashable { case input(String),presetName,ref }
    var body:some View {
        VStack(spacing:0) {
            WorkspaceSectionHeader(title:"Run "+workflow.name,subtitle:repository.name,symbol:"play.circle.fill") { EmptyView() }
            Form {
                Section("Use workflow from") {
                    HStack {
                        TextField("Branch or tag",text:$refQuery,prompt:Text("Search branches and tags")).focused($focus,equals:.ref).onSubmit { chooseTypedRef() }.disabled(sending)
                        if searchingRefs { ProgressView().controlSize(.small) }
                        Button { browsingRefs.toggle() } label: { Image(systemName:showsRefResults ? "chevron.up":"chevron.down") }.buttonStyle(.borderless).help(showsRefResults ? "Hide branches and tags":"Browse branches and tags").disabled(sending)
                    }
                    if showsRefResults { refResults }
                    if loading { ProgressView("Reading the workflow at "+ref).controlSize(.small) }
                    if let schema { Text(schema.ref+" · revision "+String(schema.revision.prefix(12))).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
                if let schema {
                    Section("Inputs") {
                        if schema.inputs.isEmpty { Text("This workflow has no manual inputs.").foregroundStyle(.secondary) }
                        ForEach(schema.inputs) { input in field(input) }
                    }
                    Section("Save a reusable preset") {
                        HStack { TextField("Preset name",text:$presetName).focused($focus,equals:.presetName);Button("Save preset") { Task { await savePreset(schema) } }.disabled(presetName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || sending) }
                    }
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden).frame(minHeight:220,idealHeight:460,maxHeight:560)
            VStack(alignment:.leading,spacing:10) {
                if let environmentError { WorkspaceNotice(message:environmentError,symbol:"exclamationmark.triangle",tint:.orange) }
                if let error { WorkspaceNotice(message:error,symbol:"exclamationmark.triangle",tint:.orange) }
                if let status { WorkspaceNotice(message:status,symbol:"checkmark.circle",tint:.green) }
                if let receipt {
                    WorkspaceNotice(message:receipt.message ?? ProviderStateText.actionsWrite(receipt.state),tint:receipt.state == .uncertain ? .orange:.secondary)
                    if receipt.state == .uncertain { Button("Reconcile outcome") { Task { do { self.receipt=try await storage.actionsService().reconcile(receipt.id) } catch { self.error=providerErrorMessage(error) } } } }
                }
                HStack {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction);Spacer()
                    if sending { ProgressView().controlSize(.small) }
                    Button("Run workflow") { Task { await dispatch(productionConfirmed:false) } }.buttonStyle(.borderedProminent).keyboardShortcut(focus == nil ? .defaultAction : nil).disabled(!canRun).help("Run (⌘Return)")
                        .background { Button("Run workflow") { if canRun { Task { await dispatch(productionConfirmed:false) } } }.keyboardShortcut(.return,modifiers:.command).hidden().accessibilityHidden(true) }
                }.padding(.top,6)
            }.padding(.horizontal,24).padding(.bottom,24)
        }.background { WorkspaceCanvas() }
        .onExitCommand { dismiss() }
        // The form opens on the preset's ref or the default branch at once; other refs are searched only on demand.
        .task { if let preset { select(preset.ref) } else { await searchRefs(""); if ref.isEmpty,let branch=matches?.defaultBranch { select(branch) } } }
        .task(id:refSearch) { guard let refSearch else { return };try? await Task.sleep(for:.milliseconds(250));guard !Task.isCancelled else { return };await searchRefs(refSearch) }
        .task(id:ref) { await loadSchema() }
        .confirmationDialog("Run workflow in production?",isPresented:$confirmProduction,titleVisibility:.visible) { Button("Run in production") { Task { await dispatch(productionConfirmed:true) } };Button("Cancel",role:.cancel) {} } message: { Text("This workflow targets a production environment at "+ref+". Review its inputs before continuing.") }
    }
    @ViewBuilder private func field(_ input:WorkflowInput) -> some View {
        let label=input.id+(input.required ? " *":"")
        VStack(alignment:.leading,spacing:4) {
            Group {
            switch input.kind {
            case .boolean:Toggle(label,isOn:Binding(get:{ if case .boolean(let value)=values[input.id] { return value };return false },set:{ values[input.id] = .boolean($0) }))
            case .choice:Picker(label,selection:Binding(get:{ values[input.id]?.string ?? "" },set:{ values[input.id]=$0.isEmpty ? nil : .choice($0) })) { Text("Select…").tag("");ForEach(input.options,id:\.self) { Text($0).tag($0) } }
            case .environment:Picker(label,selection:Binding(get:{ values[input.id]?.string ?? "" },set:{ values[input.id]=$0.isEmpty ? nil : .environment($0) })) {
                Text(environmentChoices.isEmpty ? "No environments":"Select…").tag("")
                ForEach(environmentChoices) { Text($0.name+($0.production ? " (production)":"")).tag($0.name) }
                // A default or preset naming an environment that is gone stays visible, so validation can explain it.
                if let current=values[input.id]?.string,!current.isEmpty,!environmentChoices.contains(where:{ $0.name==current }) { Text(current+" (not found)").tag(current) }
            }
            case .number:TextField(label,text:Binding(get:{ numberDrafts[input.id] ?? values[input.id]?.string ?? "" },set:{ numberDrafts[input.id]=$0;let text=$0.trimmingCharacters(in:.whitespaces);values[input.id]=text.isEmpty ? nil : Double(text).map(WorkflowInputValue.number) ?? .text(text) }))
                    .focused($focus,equals:.input(input.id)).onSubmit { focusNextInput(after:input.id) }
            case .string:
                if input.secret { SecureField(label,text:Binding(get:{ values[input.id]?.string ?? "" },set:{ values[input.id] = .text($0) })).focused($focus,equals:.input(input.id)).onSubmit { focusNextInput(after:input.id) } }
                else { TextField(label,text:Binding(get:{ values[input.id]?.string ?? "" },set:{ values[input.id] = .text($0) })).focused($focus,equals:.input(input.id)).onSubmit { focusNextInput(after:input.id) } }
            }
            }.accessibilityLabel(Text(label)).accessibilityIdentifier(input.id)
            if !input.description.isEmpty { Text(input.description).font(.caption).foregroundStyle(.secondary) }
            if input.secret { Text("This value is excluded from presets and operation records.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var canRun:Bool { schema != nil && !sending && receipt == nil }
    private var environmentChoices:[ActionsEnvironment] { liveEnvironments ?? environments }
    private var showsRefResults:Bool { browsingRefs || (focus == .ref && refQuery != ref) }
    /// The search to run for the ref field: what the user typed, or everything while browsing the selected ref.
    private var refSearch:String? { showsRefResults ? (refQuery == ref ? "" : refQuery.trimmingCharacters(in:.whitespaces)) : nil }
    @ViewBuilder private var refResults:some View {
        let tags=matches?.tags ?? []
        // The default branch leads the list whenever the search includes it, wherever it sorts alphabetically.
        let typed=refSearch ?? "",listed=matches?.branches ?? []
        let pinned=matches?.defaultBranch.flatMap { typed.isEmpty || $0.localizedCaseInsensitiveContains(typed) ? $0 : nil }
        let branches=(pinned.map { [$0] } ?? [])+listed.filter { $0 != pinned }
        if branches.isEmpty && tags.isEmpty { Text(searchingRefs ? "Searching…":"No branch or tag matches “"+refQuery+"”.").font(.caption).foregroundStyle(.secondary) }
        else {
            ScrollView {
                VStack(alignment:.leading,spacing:2) {
                    if !branches.isEmpty { refHeader("Branches") }
                    ForEach(branches,id:\.self) { refRow($0,symbol:"arrow.triangle.branch",isDefault:$0==matches?.defaultBranch) }
                    if !tags.isEmpty { refHeader("Tags (newest first)") }
                    ForEach(tags,id:\.self) { refRow($0,symbol:"tag",isDefault:false) }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.frame(maxHeight:200)
        }
    }
    private func refHeader(_ title:String) -> some View { Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top,4) }
    private func refRow(_ name:String,symbol:String,isDefault:Bool) -> some View {
        Button { select(name) } label: {
            HStack(spacing:6) {
                Image(systemName:symbol).foregroundStyle(.secondary).frame(width:14)
                Text(name).lineLimit(1).truncationMode(.middle)
                if isDefault { Text("default").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                if name==ref { Image(systemName:"checkmark").foregroundStyle(.tint) }
            }.padding(.vertical,3).padding(.horizontal,4).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(Text((symbol=="tag" ? "Tag ":"Branch ")+name))
    }
    private func select(_ name:String) { ref=name;refQuery=name;browsingRefs=false;if focus == .ref { focus=nil } }
    /// Return in the ref field picks the exact match, else the only or first result; a name GitHub has not listed
    /// is still tried, since the workflow read reports a ref that does not exist.
    private func chooseTypedRef() {
        let typed=refQuery.trimmingCharacters(in:.whitespaces);guard !typed.isEmpty else { return }
        let found=(matches?.branches ?? [])+(matches?.tags ?? [])
        select(found.contains(typed) ? typed : found.first ?? typed)
    }
    private func searchRefs(_ query:String) async {
        searchingRefs=true;defer { searchingRefs=false }
        do { let found=try await storage.actionsService().refs(repository:repository,matching:query);guard !Task.isCancelled else { return };matches=found }
        catch { if !Task.isCancelled,!(error is CancellationError) { self.error=providerErrorMessage(error) } }
    }
    /// The next number or text input after `id`, if any; Return in the last one leaves focus where it is.
    private func focusNextInput(after id:String) {
        let typed=(schema?.inputs ?? []).filter { $0.kind == .number || $0.kind == .string }.map(\.id)
        guard let index=typed.firstIndex(of:id),index+1<typed.count else { return }
        focus = .input(typed[index+1])
    }
    private func loadSchema() async {
        // Clearing the ref must also clear the schema, or Run would dispatch to the previously loaded revision.
        guard !ref.isEmpty else { schema=nil;values=[:];numberDrafts=[:];loading=false;return };let selected=ref;loading=true;schema=nil;error=nil;status=nil;receipt=nil
        do {
            let observed=try await storage.actionsService().schema(repository:repository,workflow:workflow,ref:selected)
            guard ref==selected,!Task.isCancelled else { return }
            schema=observed;values=observed.defaults;numberDrafts=[:]
            if liveEnvironments == nil,observed.inputs.contains(where:{ $0.kind == .environment }) {
                do { liveEnvironments=try await storage.actionsService().environments(repository:repository) } catch { self.error="Environments could not be read. "+providerErrorMessage(error) }
                guard ref==selected,!Task.isCancelled else { return }
            }
            for input in observed.inputs where input.kind == .boolean && values[input.id]==nil { values[input.id] = .boolean(false) }
            let operations=try await storage.actionsService().operations(repository:repository.key)
            guard ref==selected,!Task.isCancelled else { return }
            receipt=operations.first { operation in guard [.uncertain,.sending].contains(operation.state),case .dispatch(let workflow,let schema,_,_)=operation.intent else { return false };return workflow.id==self.workflow.id && schema.ref==selected }
            if let preset,preset.ref==selected { if preset.matches(observed) { values.merge(preset.inputs) { _,saved in saved } } else { error="The preset belongs to a different workflow revision. Review the current inputs before running." } }
        } catch { if ref==selected { self.error=(error as? ActionsFailure) == .noManualTrigger ? "This workflow does not declare workflow_dispatch at the selected ref.":providerErrorMessage(error) } }
        if ref==selected { loading=false }
    }
    private func dispatch(productionConfirmed:Bool) async {
        guard let schema,!sending else { return };sending=true;error=nil;status=nil
        defer { sending=false }
        do {
            _=try schema.validate(values,environments:environmentChoices.map(\.name))
            receipt=try await storage.actionsService().perform(repository:repository,intent:.dispatch(workflow:workflow,schema:schema,inputs:values,productionConfirmed:productionConfirmed))
        } catch { if error as? ActionsFailure == .productionConfirmationRequired { confirmProduction=true } else { self.error=providerErrorMessage(error) } }
    }
    private func savePreset(_ schema:WorkflowInputSchema) async {
        do { _=try schema.validate(values,environments:environmentChoices.map(\.name));try await storage.actionsService().savePreset(.init(name:presetName.trimmingCharacters(in:.whitespacesAndNewlines),repository:repository.key,schema:schema,inputs:values));presetName="";error=nil;status="Preset saved. Secret inputs must be entered each time." } catch { status=nil;self.error=providerErrorMessage(error) }
    }
}
