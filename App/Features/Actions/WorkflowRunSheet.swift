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
    @State private var refs:[String]=[]
    @State private var ref=""
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
    private enum Field:Hashable { case input(String),presetName }
    var body:some View {
        VStack(spacing:0) {
            WorkspaceSectionHeader(title:"Run "+workflow.name,subtitle:repository.name,symbol:"play.circle.fill") { EmptyView() }
            Form {
                Section("Workflow revision") {
                    Picker("Branch or tag",selection:$ref) { Text("Choose a ref").tag("");ForEach(refs,id:\.self) { Text($0).tag($0) } }.disabled(sending)
                    if loading { ProgressView("Reading workflow at selected revision") }
                    if let schema { Text("Revision "+String(schema.revision.prefix(12))).font(.caption.monospaced()).foregroundStyle(.secondary) }
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
        .task { do { refs=try await storage.actionsService().refs(repository:repository);ref=preset?.ref ?? refs.first(where:{ $0=="main" }) ?? refs.first ?? "" } catch { self.error=providerErrorMessage(error) } }
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
            case .environment:Picker(label,selection:Binding(get:{ values[input.id]?.string ?? "" },set:{ values[input.id]=$0.isEmpty ? nil : .environment($0) })) { Text("Select…").tag("");ForEach(environments) { Text($0.name+($0.production ? " (production)":"")).tag($0.name) } }
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
            _=try schema.validate(values,environments:environments.map(\.name))
            receipt=try await storage.actionsService().perform(repository:repository,intent:.dispatch(workflow:workflow,schema:schema,inputs:values,productionConfirmed:productionConfirmed))
        } catch { if error as? ActionsFailure == .productionConfirmationRequired { confirmProduction=true } else { self.error=providerErrorMessage(error) } }
    }
    private func savePreset(_ schema:WorkflowInputSchema) async {
        do { _=try schema.validate(values,environments:environments.map(\.name));try await storage.actionsService().savePreset(.init(name:presetName.trimmingCharacters(in:.whitespacesAndNewlines),repository:repository.key,schema:schema,inputs:values));presetName="";error=nil;status="Preset saved. Secret inputs must be entered each time." } catch { status=nil;self.error=providerErrorMessage(error) }
    }
}
