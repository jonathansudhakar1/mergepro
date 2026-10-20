import SwiftUI
import MergeProCore
struct DeploymentApprovalSheet:View {
    let storage:SetupStorage
    let run:WorkflowRun
    let environments:[ActionsEnvironment]
    @Environment(\.dismiss) private var dismiss
    @State private var selected:Set<Int64>=[]
    @State private var comment=""
    @State private var sending=false
    @State private var error:String?
    @State private var receipt:ActionsWriteOperation?
    @State private var productionApproval:Bool?
    var body:some View {
        VStack(spacing:0) {
            WorkspaceSectionHeader(title:"Review deployments",subtitle:run.name+" · attempt \(run.attempt)",symbol:"shippingbox.fill",tint:DesignTokens.violet) { EmptyView() }
            Form {
                Section("Pending environments") {
                    ForEach(environments) { environment in
                        Toggle(isOn:Binding(get:{ selected.contains(environment.id) },set:{ if $0 { selected.insert(environment.id) } else { selected.remove(environment.id) } })) {
                            VStack(alignment:.leading,spacing:6) {
                                Text(environment.name).font(.headline)
                                if environment.production { WorkspaceStatusBadge(text:"Production",symbol:"exclamationmark.shield",tint:.orange) }
                                if !environment.canApprove { Text("Your current account cannot review this environment.").font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical,4)
                        }.disabled(!environment.canApprove || sending)
                    }
                }
                Section("Review comment") { TextField("Required review comment",text:$comment,axis:.vertical).lineLimit(3...6) }
            }.formStyle(.grouped).scrollContentBackground(.hidden).frame(minHeight:200,maxHeight:380)
            VStack(alignment:.leading,spacing:10) {
                if let error { WorkspaceNotice(message:error,symbol:"exclamationmark.triangle",tint:.orange) }
                if let receipt {
                    WorkspaceNotice(message:receipt.message ?? ProviderStateText.actionsWrite(receipt.state),tint:receipt.state == .uncertain ? .orange:.secondary)
                    if receipt.state == .uncertain { WorkspaceNotice(message:"The review outcome is unknown. Refresh this run and review its environment status before taking another action.",symbol:"exclamationmark.triangle",tint:.orange) }
                }
                HStack {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction);Spacer()
                    if sending { ProgressView().controlSize(.small) }
                    HStack { Button("Reject",role:.destructive) { Task { await review(approve:false) } };Button("Approve") { Task { await review(approve:true) } }.buttonStyle(.borderedProminent) }
                        .disabled(sending || selected.isEmpty || comment.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || receipt != nil)
                }.padding(.top,6)
            }.padding(.horizontal,24).padding(.bottom,24)
        }.background { WorkspaceCanvas() }
        .onExitCommand { dismiss() }
        .confirmationDialog("Review production deployments?",isPresented:Binding(get:{ productionApproval != nil },set:{ if !$0 { productionApproval=nil } }),titleVisibility:.visible) {
            Button(productionApproval == true ? "Approve production":"Reject production",role:productionApproval == true ? nil:.destructive) { let approve=productionApproval ?? false;productionApproval=nil;Task { await review(approve:approve,productionConfirmed:true) } }
            Button("Cancel",role:.cancel) { productionApproval=nil }
        } message: { Text("The selected environments include production. Confirm this deployment review.") }
    }
    private func review(approve:Bool,productionConfirmed:Bool=false) async {
        if !productionConfirmed,environments.contains(where:{ selected.contains($0.id) && $0.production }) { productionApproval=approve;return }
        sending=true;error=nil;defer { sending=false }
        do { receipt=try await storage.actionsService().perform(repository:run.repository,intent:.deployment(runID:run.runID,attempt:run.attempt,environmentIDs:selected.sorted(),approve:approve,comment:comment,productionConfirmed:productionConfirmed)) } catch { if error as? ActionsFailure == .productionConfirmationRequired { productionApproval=approve } else { self.error=providerErrorMessage(error) } }
    }
}
