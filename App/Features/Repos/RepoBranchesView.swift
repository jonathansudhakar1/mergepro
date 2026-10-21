import SwiftUI
import MergeProCore

struct RepoBranchesView:View {
    @Bindable var model:ReposModel
    var createPR:(String) -> Void
    var openPR:(ProviderKey) -> Void
    /// PR creation writes as the active account, so rows follow the same gate as the repository header.
    var canCreatePR=true
    @State private var newName=""
    @State private var createSheet=false
    @State private var deleteCandidate:RepositoryBranch?
    @State private var compareCandidate:RepositoryBranch?
    @State private var comparison:RepositoryComparison?
    @State private var ahead:[String:RepositoryComparison]=[:]
    @State private var links:[String:[CreatedRepositoryPR]]=[:]
    @State private var messages:[String:String]=[:]
    @State private var pending:[RepositoryBranchMutation]=[]
    @State private var busy=false
    @State private var createError:String?
    @State private var reconciled:(message:String,applied:Bool)?
    var body:some View {
        VStack(spacing:0) {
            ViewThatFits(in:.horizontal) {
                HStack { branchHeading;Spacer();branchActions }
                VStack(alignment:.leading,spacing:10) { branchHeading;branchActions }
            }.padding(16).background(Color(nsColor:.windowBackgroundColor))
            if let reconciled {
                HStack(alignment:.top) {
                    WorkspaceNotice(message:reconciled.message,symbol:reconciled.applied ? "checkmark.circle" : "exclamationmark.triangle",tint:reconciled.applied ? .green : .orange)
                    Button("Dismiss") { self.reconciled=nil }.padding(.top,12)
                }.padding(.horizontal,16).padding(.top,10)
            }
            List {
                ForEach(pending) { mutation in
                    VStack(alignment:.leading,spacing:8) { WorkspaceNotice(message:"Unconfirmed "+mutation.description,symbol:"exclamationmark.triangle",tint:.orange);Button("Reconcile") { Task { await reconcile(mutation) } }.disabled(busy) }
                        .padding(.vertical,4).listRowSeparator(.hidden)
                }
                ForEach(model.branches) { branch in
                    VStack(alignment:.leading,spacing:6) {
                        Text(branch.name).font(.system(.headline,design:.rounded)).textSelection(.enabled)
                        HStack(spacing:8) { if branch.protected { WorkspaceStatusBadge(text:"Protected",symbol:"lock.fill",tint:DesignTokens.violet) };if branch.name==model.repository?.defaultBranch { WorkspaceStatusBadge(text:"Default",tint:DesignTokens.cobalt) };Spacer(minLength:4);Text(String(branch.sha.prefix(8))).font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary) }
                        if branch.name != model.repository?.defaultBranch,let comparison=ahead[branch.name] { Text("\(comparison.ahead) ahead · \(comparison.behind) behind default").font(.caption) }
                        if let message=messages[branch.name] { Text(message).font(.caption).lineLimit(1) }
                        ScrollView(.horizontal) {
                            HStack(spacing:8) {
                                Button("Browse") { model.changeRef(branch.name);model.section="code" }
                                Button("Compare") { compareCandidate=branch;Task { await compare(branch) } }
                                Button("Create PR") { createPR(branch.name) }.disabled(!canCreatePR).help(canCreatePR ? "Create a pull request from this branch" : "Switch the active account to \(model.repository?.accountLogin ?? "this repository's account") to create pull requests")
                                ForEach(links[branch.name] ?? [],id:\.key) { pr in Button("Open PR #\(pr.number)") { openPR(pr.key) } }
                                Spacer()
                                Button("Delete",role:.destructive) { deleteCandidate=branch }.disabled(branch.protected || branch.name==model.repository?.defaultBranch || busy)
                            }.controlSize(.small).fixedSize(horizontal:true,vertical:false).padding(.vertical,2)
                        }.frame(height:34)
                    }.padding(12).workspacePanel(radius:12).padding(.vertical,4)
                    .listRowSeparator(.hidden)
                    .task(id:branch.sha) { await enrich(branch) }
                }
                if model.branchPage != nil { Button("Load More Branches") { Task { await model.moreBranches() } }.listRowSeparator(.hidden) }
            }.listStyle(.inset).scrollContentBackground(.hidden)
        }.task { await loadPending() }
        .onChange(of:createError) { _,message in if let message { AccessibilityNotification.Announcement(message).post() } }
        .confirmationDialog("Delete branch \(deleteCandidate?.name ?? "")?",isPresented:Binding(get:{ deleteCandidate != nil },set:{ if !$0 { deleteCandidate=nil } }),titleVisibility:.visible) {
            if let branch=deleteCandidate { Button("Delete \(branch.name)",role:.destructive) { Task { await delete(branch) } } }
        } message:{ Text("The remote branch will be deleted at its current commit. MergePro refuses if it is the default or a protected branch, or if any open pull request uses it as its head or base. Permissions are checked again before deletion.") }
        .sheet(isPresented:$createSheet) {
            VStack(alignment:.leading,spacing:16) {
                Label("Create Remote Branch",systemImage:"arrow.triangle.branch").font(.system(.title2,design:.rounded).bold()).foregroundStyle(DesignTokens.cobalt)
                if let ref=model.ref { Text("From \(ref.name) · \(String(ref.commitSHA.prefix(8)))").font(.caption).foregroundStyle(.secondary) }
                TextField("New branch name",text:$newName).textFieldStyle(.roundedBorder)
                if !newName.isEmpty,!BranchService.validName(newName) { Text("Enter a valid Git branch name: no spaces, “..”, or ~ ^ : ? * [ \\ characters, and no leading “-” or trailing “/”, “.” or “.lock”.").font(.caption).foregroundStyle(.secondary) }
                if let createError { WorkspaceNotice(message:createError,symbol:"exclamationmark.circle",tint:.red) }
                HStack { Button("Cancel") { createSheet=false }.keyboardShortcut(.cancelAction);Spacer();if busy { ProgressView().controlSize(.small) };Button("Create Branch") { Task { await create() } }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(DesignTokens.cobalt).disabled(!BranchService.validName(newName) || busy || model.ref==nil) }
            }.padding(24).frame(width:440).background { WorkspaceCanvas() }
            .onExitCommand { if !busy { createSheet=false } }
        }
        .sheet(isPresented:Binding(get:{ compareCandidate != nil },set:{ if !$0 { compareCandidate=nil;comparison=nil } })) {
            VStack(alignment:.leading,spacing:16) {
                Label("Compare with Default Branch",systemImage:"arrow.left.arrow.right").font(.system(.title2,design:.rounded).bold()).foregroundStyle(DesignTokens.cobalt)
                if let comparison { Text(ProviderStateText.comparisonStatus(comparison.status)+" · \(comparison.ahead) ahead · \(comparison.behind) behind");ScrollView { VStack(alignment:.leading,spacing:12) { ForEach(comparison.files) { file in Text(file.path+"  +\(file.additions) −\(file.deletions)").font(.system(.caption,design:.monospaced)).accessibilityLabel(file.path+", \(file.additions) additions, \(file.deletions) deletions") } } };if let url=comparison.webURL { Button("Open Full Comparison") { ExternalLinkPolicy.open(url) }.buttonStyle(.link).help(url.absoluteString) } }
                else { ProgressView("Comparing…") }
                Button("Done") { compareCandidate=nil;comparison=nil }.keyboardShortcut(.cancelAction)
            }.padding(24).frame(width:600,height:450).background { WorkspaceCanvas() }
            .onExitCommand { compareCandidate=nil;comparison=nil }
        }
    }
    private var branchHeading:some View {
        VStack(alignment:.leading,spacing:4) {
            Label("Branches",systemImage:"arrow.triangle.branch").font(.system(.headline,design:.rounded)).foregroundStyle(DesignTokens.cobalt)
            Text("\(model.branches.count) loaded · compare, browse and manage remote refs").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var branchActions:some View {
        HStack {
            Button("Create Branch") { createError=nil;createSheet=true }.buttonStyle(.borderedProminent).tint(DesignTokens.cobalt).disabled(model.ref==nil)
            Button { Task { await refresh() } } label:{ Image(systemName:"arrow.clockwise") }.help("Refresh Branches").accessibilityLabel("Refresh branches")
        }.fixedSize(horizontal:true,vertical:false)
    }
    /// Enrichment is keyed by branch name, so a refresh drops it with the list it described.
    private func refresh() async { model.resetBranches();ahead=[:];links=[:];messages=[:];await model.moreBranches();await loadPending() }
    private func loadPending() async { guard let repository=model.repository,let service=model.service else { return };do { pending=try await service.pendingBranchMutations(repository:repository) } catch { model.error=providerErrorMessage(error) } }
    private func create() async { guard let repository=model.repository,let ref=model.ref,let service=model.service else { return };busy=true;defer { busy=false };createError=nil;reconciled=nil;do { try await service.createBranch(repository:repository,name:newName,from:ref);AccessibilityNotification.Announcement("Created branch "+newName).post();createSheet=false;newName="";await refresh() } catch { createError=providerErrorMessage(error);await loadPending() } }
    private func delete(_ branch:RepositoryBranch) async { guard let repository=model.repository,let service=model.service else { return };busy=true;defer { busy=false };reconciled=nil;do { try await service.deleteBranch(repository:repository,branch:branch);deleteCandidate=nil;AccessibilityNotification.Announcement("Deleted branch "+branch.name).post();await refresh() } catch { model.error=providerErrorMessage(error);await loadPending() } }
    private func reconcile(_ mutation:RepositoryBranchMutation) async {
        guard let repository=model.repository,let service=model.service else { return };busy=true;defer { busy=false }
        do { let result=try await service.reconcileBranch(repository:repository,mutation:mutation);reconciled=result == .applied ? ("GitHub confirms the branch operation “"+mutation.description+"” applied.",true) : ("The branch operation “"+mutation.description+"” did not apply. Review the branch's current state and confirm a new operation if needed.",false);AccessibilityNotification.Announcement(reconciled?.message ?? "").post();await refresh() } catch { model.error=providerErrorMessage(error) }
    }
    private func enrich(_ branch:RepositoryBranch) async {
        guard let repository=model.repository,let service=model.service else { return }
        do {
            let value=try await service.compare(repository:repository,base:repository.defaultBranch,head:branch.sha)
            guard !Task.isCancelled else { return };ahead[branch.name]=value
            // try? would turn cancellation into an empty result; a superseded row must not overwrite newer links or messages.
            let linked=(try? await service.linkedPRs(repository:repository,sha:branch.sha)) ?? []
            guard !Task.isCancelled else { return };links[branch.name]=linked
            if let ref=try? await service.resolve(repository:repository,ref:branch.sha),let commit=try? await service.commits(repository:repository,ref:ref).values.first,!Task.isCancelled { messages[branch.name]=commit.message.components(separatedBy:"\n").first }
        } catch { if !Task.isCancelled { messages[branch.name]="Details unavailable: "+providerErrorMessage(error) } }
    }
    private func compare(_ branch:RepositoryBranch) async { guard let repository=model.repository,let service=model.service else { return };do { let result=try await service.compare(repository:repository,base:repository.defaultBranch,head:branch.sha);guard compareCandidate?.sha==branch.sha else { return };comparison=result } catch { guard compareCandidate?.sha==branch.sha else { return };model.error=providerErrorMessage(error);compareCandidate=nil } }
}
