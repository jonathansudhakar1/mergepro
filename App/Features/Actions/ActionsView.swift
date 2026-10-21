import SwiftUI
import MergeProCore

struct ActionsView:View {
    let storage:SetupStorage
    let repositories:[Repository]
    var accountFilter:AccountScope? = nil
    var repositoryFilter:RepositoryKey? = nil
    /// Embedded views (repository tabs, PR sheets) omit the page header and keep its controls in the filter bar.
    var embedded=false
    var runID:Int64? = nil
    var workflowID:Int64? = nil
    var presetID:UUID? = nil
    var initialSection:String? = nil
    var headSHA:String? = nil
    var onOpenAnnotation:((Repository,String,String,Int)->Void)? = nil
    var refreshID:UUID = UUID(uuidString:"00000000-0000-0000-0000-000000000000")!
    @State private var model=ActionsWorkspaceModel()
    @State private var section="running"
    @State private var selectedRun:WorkflowRun?
    @State private var selectedWorkflow:ActionsWorkflowSelection?
    @State private var savedViewName=""
    @State private var saveRule=false
    @State private var showFilters=false
    @State private var showRepositories=false
    @State private var repositorySearch=""
    /// Cancelling stops running jobs, so the context-menu command asks first.
    @State private var cancelling:WorkflowRun?
    @State private var rerunning:(run:WorkflowRun,failedOnly:Bool)?
    @FocusState private var repositorySearchFocused:Bool
    private var scoped:[Repository] { repositories.filter { (accountFilter==nil || $0.key.account==accountFilter) && (repositoryFilter==nil || $0.key==repositoryFilter) } }
    private var routeIdentity:String {
        scoped.map { [$0.key.account.host,$0.key.account.accountID,$0.key.repositoryID,$0.name].joined(separator:"|") }.sorted().joined(separator:";") + [String(runID ?? 0),String(workflowID ?? 0),presetID?.uuidString ?? "",initialSection ?? "",headSHA ?? ""].joined(separator:"|")
    }
    var body:some View {
        VStack(spacing:0) {
            if embedded { Color.clear.frame(height:16) }
            else {
                WorkspaceSectionHeader(title:"Actions",subtitle:"Workflow runs, dispatches, and deployment reviews across your repositories.",symbol:"play.rectangle.fill") { headerControls }
            }
            ViewThatFits(in:.horizontal) {
                HStack(spacing:16) { sectionPicker; searchControls; if embedded { headerControls } }
                VStack(alignment:.leading,spacing:12) { sectionPicker; HStack(spacing:10) { searchControls; if embedded { headerControls } } }
            }
            .padding(12).workspaceGlass().padding(.horizontal,24).padding(.bottom,16)
            if !model.errors.isEmpty {
                VStack(alignment:.leading,spacing:8) {
                    ForEach(model.errors.keys.sorted(),id:\.self) { key in
                        WorkspaceNotice(message:key+": "+(model.errors[key] ?? ""),symbol:"exclamationmark.triangle",tint:.orange)
                    }
                }.padding(.horizontal,24).padding(.bottom,12)
            }
            if let message=model.message { WorkspaceNotice(message:message).padding(.horizontal,24).padding(.bottom,12) }
            if model.loading && model.catalogs.isEmpty { ProgressView("Loading Actions").frame(maxWidth:.infinity,maxHeight:.infinity) }
            else { content.frame(maxWidth:.infinity,maxHeight:.infinity) }
        }
        .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
        .background { WorkspaceCanvas() }
        .task(id:routeIdentity) {
            selectedRun=nil;selectedWorkflow=nil;showRepositories=false
            section=initialSection ?? (workflowID==nil ? "running":"workflows")
            // The account's saved filter belongs to the Actions page; a repository- or PR-scoped view must not inherit or overwrite it.
            let persistsFilter = !embedded && repositoryFilter==nil
            if model.persistsFilter != persistsFilter { model.persistsFilter=persistsFilter;if !persistsFilter { model.state.filter = .init() } }
            await model.load(storage:storage,repositories:scoped)
            guard !Task.isCancelled else { return }
            if let id=runID { selectedRun=model.runs.first { $0.runID==id } }
            if let presetID,let preset=model.presets.first(where:{ $0.id==presetID }),let catalog=model.catalogs[preset.repository],let workflow=catalog.workflows.first(where:{ $0.id==preset.workflowID }) { selectedWorkflow = .init(repository:catalog.repository,workflow:workflow,preset:preset) }
            else if let id=workflowID { for catalog in model.catalogs.values { if let workflow=catalog.workflows.first(where:{ $0.id==id }) { selectedWorkflow = .init(repository:catalog.repository,workflow:workflow,preset:nil);break } } }
        }
        // After each poll cycle; a newer cycle or leaving the page cancels the cached re-read.
        .onChangeTask(of:refreshID) { _ in
            await model.refreshCached(repositories:scoped)
            guard !Task.isCancelled else { return }
            if let selectedRun,let updated=model.runs.first(where:{ $0.key==selectedRun.key }) { self.selectedRun=updated }
        }
        .onChange(of:model.state) { _,_ in Task { await model.persist() } }
        // The page loads only a few repositories live; one picked in the filter is read live right away.
        .onChange(of:model.state.filter.repositoryKey) { _,key in
            guard let key,let repository=scoped.first(where:{ $0.key==key }) else { return }
            Task { await model.refresh(repository:repository) }
        }
        .sheet(item:$selectedRun,onDismiss:{ Task { await model.load(storage:storage,repositories:scoped) } }) { run in
            RunDetailView(storage:storage,run:run,onOpenAnnotation:onOpenAnnotation,refreshID:refreshID)
                .frame(minWidth:900,idealWidth:1280,maxWidth:.infinity,minHeight:600,idealHeight:840,maxHeight:.infinity)
                .presentationSizing(.fitted)
                .background { WindowFrameMemory(role:"actions-run",defaultSize:CGSize(width:1280,height:840),minimumSize:CGSize(width:900,height:600),sheet:true) }
        }
        .sheet(item:$selectedWorkflow,onDismiss:{ Task { await model.load(storage:storage,repositories:scoped) } }) { selection in WorkflowRunSheet(storage:storage,repository:selection.repository,workflow:selection.workflow,environments:model.catalogs[selection.repository.key]?.environments ?? [],preset:selection.preset,environmentError:model.catalogs[selection.repository.key]?.unavailableSections["environments"]).frame(minWidth:460,idealWidth:620,maxWidth:680) }
        .confirmationDialog("Cancel this workflow run?",isPresented:Binding(get:{ cancelling != nil },set:{ if !$0 { cancelling=nil } }),titleVisibility:.visible,presenting:cancelling) { run in
            Button("Cancel run",role:.destructive) { cancelling=nil;Task { await model.perform(run:run,intent:.cancel(runID:run.runID,attempt:run.attempt)) } }
            Button("Keep running",role:.cancel) { cancelling=nil }
        } message: { run in Text(ActionsRunConfirmation.cancelMessage(run)) }
        .confirmationDialog(rerunning?.failedOnly == true ? "Re-run failed jobs?" : "Re-run all jobs?",isPresented:Binding(get:{ rerunning != nil },set:{ if !$0 { rerunning=nil } }),titleVisibility:.visible,presenting:rerunning) { request in
            Button(request.failedOnly ? "Re-run failed jobs" : "Re-run all jobs") {
                rerunning=nil
                let run=request.run
                Task { await model.perform(run:run,intent:request.failedOnly ? .rerunFailed(runID:run.runID,attempt:run.attempt) : .rerunAll(runID:run.runID,attempt:run.attempt)) }
            }
            Button("Don’t re-run",role:.cancel) { rerunning=nil }
        } message: { request in Text(ActionsRunConfirmation.rerunMessage(request.run,failedOnly:request.failedOnly)) }
    }
    private func catalogTitle(_ catalog:ActionsCatalog) -> String {
        guard model.availableAccounts.count>1 else { return catalog.repository.name }
        return catalog.repository.name+" · "+(model.accountNames[catalog.repository.key.account] ?? catalog.repository.key.account.accountID)
    }
    @ViewBuilder private var headerControls:some View {
        if model.loading { ProgressView().controlSize(.small) }
        if section=="recent" { Button("Load full history") { Task { await model.loadHistory() } }.disabled(model.loading) }
        // Embedded hosts (the Repositories page) already own ⌘R.
        Button("Refresh",systemImage:"arrow.clockwise") { Task { await model.load(storage:storage,repositories:scoped) } }.disabled(model.loading).keyboardShortcut(embedded ? nil : KeyboardShortcut("r"))
    }
    private var sectionPicker:some View {
        Picker("Actions",selection:$section) {
            Text("Running").tag("running");Text("Recent").tag("recent")
            Text("Workflows").tag("workflows");Text("Deployments").tag("deployments")
        }.pickerStyle(.segmented).labelsHidden().fixedSize()
    }
    private var searchControls:some View {
        HStack(spacing:10) {
            if repositoryFilter==nil { repositoryDropdown }
            if section=="running" || section=="recent" {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search runs",text:$model.state.filter.query).textFieldStyle(.plain).frame(minWidth:110,maxWidth:.infinity)
            } else { Spacer(minLength:0) }
            Button("Filters",systemImage:"line.3.horizontal.decrease") { showFilters.toggle() }
                .popover(isPresented:$showFilters) { filterControls.padding().frame(width:400) }
        }
    }
    private var selectedRepository:Repository? {
        scoped.first { repository in
            model.state.filter.repositoryKey.map { repository.key==$0 } ?? (!model.state.filter.repositoryID.isEmpty && repository.key.repositoryID==model.state.filter.repositoryID)
        }
    }
    private var repositoryFilterTitle:String {
        selectedRepository?.name ?? (model.state.filter.repositoryKey != nil || !model.state.filter.repositoryID.isEmpty ? "Unavailable repository":"All repositories")
    }
    private var repositoryDropdown:some View {
        Button {
            repositorySearch="";showRepositories.toggle()
        } label: {
            HStack(spacing:7) {
                Image(systemName:"shippingbox")
                Text(repositoryFilterTitle).lineLimit(1).truncationMode(.middle)
                Image(systemName:"chevron.down").font(.caption)
            }
        }
        .help(selectedRepository.map { $0.name+" · "+$0.key.account.host+" · "+(model.accountNames[$0.key.account] ?? $0.key.account.accountID) } ?? "Filter Actions by repository")
        .accessibilityLabel("Repository filter")
        .accessibilityValue(repositoryFilterTitle)
        .accessibilityIdentifier("actionsRepositoryFilter")
        .frame(maxWidth:260)
        .popover(isPresented:$showRepositories) {
            VStack(alignment:.leading,spacing:12) {
                Text("Filter by repository").font(.headline)
                TextField("Search repositories",text:$repositorySearch)
                    .textFieldStyle(.roundedBorder).focused($repositorySearchFocused)
                    .accessibilityIdentifier("actionsRepositorySearch")
                List {
                    repositoryOption(nil)
                    let matches=scoped.filter { repositorySearch.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || $0.name.localizedCaseInsensitiveContains(repositorySearch.trimmingCharacters(in:.whitespacesAndNewlines)) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    ForEach(matches,id:\.key) { repository in repositoryOption(repository) }
                    if matches.isEmpty { Text(repositorySearch.isEmpty ? "No repositories in this scope":"No matching repositories").foregroundStyle(.secondary) }
                }.listStyle(.plain)
            }.padding(16).frame(width:380,height:420)
            .onAppear { repositorySearchFocused=true }
        }
    }
    private func repositoryOption(_ repository:Repository?) -> some View {
        let selected=repository.map { $0.key==selectedRepository?.key } ?? (model.state.filter.repositoryKey==nil && model.state.filter.repositoryID.isEmpty)
        return Button {
            model.state.filter.repositoryKey=repository?.key
            model.state.filter.repositoryID=""
            showRepositories=false
        } label: {
            HStack(spacing:10) {
                VStack(alignment:.leading,spacing:3) {
                    Text(repository?.name ?? "All repositories").lineLimit(1).truncationMode(.middle)
                    if let repository,model.availableAccounts.count>1 {
                        Text((model.accountNames[repository.key.account] ?? repository.key.account.accountID)+" · "+repository.key.account.host).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength:4)
                if selected { Image(systemName:"checkmark").foregroundStyle(DesignTokens.cobalt).accessibilityHidden(true) }
            }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,4).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityValue(selected ? "Selected":"")
    }
    @ViewBuilder private var content:some View {
        switch section {
        case "workflows":workflowList
        case "deployments":deploymentList
        default:
            let runs=model.filteredRuns.filter { (headSHA==nil || $0.headSHA==headSHA) }.filter { section=="running" ? $0.isActive:!$0.isActive }
            if runs.isEmpty { ContentUnavailableView(section=="running" ? "No running workflows":"No recent runs",systemImage:"play.rectangle",description:Text("Runs appear here for tracked repositories matching these filters.")) }
            else {
                List(runs) { run in
                    Button { selectedRun=run } label: { runRow(run) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if run.isActive {
                                Button("Cancel…") { cancelling=run }
                            } else {
                                Button("Re-run all jobs…") { rerunning=(run,false) }
                                Button("Re-run failed jobs…") { rerunning=(run,true) }
                            }
                        }
                }.listStyle(.inset).scrollContentBackground(.hidden).padding(.horizontal,12).padding(.bottom,12)
            }
        }
    }
    private func runRow(_ run:WorkflowRun) -> some View {
        HStack(alignment:.top,spacing:12) {
            Image(systemName:run.conclusion=="success" ? "checkmark.circle.fill":run.conclusion=="failure" ? "xmark.circle.fill":run.isActive ? "clock.fill":"circle")
                .font(.title3).foregroundStyle(actionsStatusTint(run.conclusion ?? run.status)).padding(.top,2)
            VStack(alignment:.leading,spacing:6) {
                Text(run.name).font(.headline)
                Text(run.repository.name+" · "+run.branch+" · "+run.event+" · "+run.actor).font(.caption).foregroundStyle(.secondary)
                Text("Attempt \(run.attempt) · "+String(run.headSHA.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
            }.frame(maxWidth:.infinity,alignment:.leading)
            VStack(alignment:.trailing,spacing:7) {
                WorkspaceStatusBadge(text:ProviderStateText.actionsStatus(run.conclusion ?? run.status),tint:actionsStatusTint(run.conclusion ?? run.status))
                if run.isActive { TimelineView(.periodic(from:.now,by:1)) { _ in Text("Running for \(Text((run.startedAt ?? run.createdAt),style:.relative))").font(.caption).foregroundStyle(.secondary) } }
                else { Text(Duration.seconds(run.duration).formatted(.time(pattern:.hourMinuteSecond))).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
        }.padding(.vertical,10).contentShape(Rectangle())
    }
    private var workflowList:some View {
        List {
            if !visiblePresets.isEmpty { Section("Presets") { ForEach(visiblePresets,id:\.preset.id) { item in Button { selectedWorkflow = .init(repository:item.catalog.repository,workflow:item.workflow,preset:item.preset) } label: { HStack { Image(systemName:"play.fill");Text(item.preset.name);Spacer();Text(item.preset.ref).foregroundStyle(.secondary) } } } } }
            ForEach(model.visibleCatalogs,id:\.repository.key) { catalog in
                Section(catalogTitle(catalog)) {
                    ForEach(catalog.workflows.filter { model.state.filter.workflow.isEmpty || $0.name.localizedCaseInsensitiveContains(model.state.filter.workflow) }.sorted { a,b in if model.state.pinnedWorkflows.contains(ActionsViewState.workflowKey(a.id,repository:catalog.repository.key)) != model.state.pinnedWorkflows.contains(ActionsViewState.workflowKey(b.id,repository:catalog.repository.key)) { return model.state.pinnedWorkflows.contains(ActionsViewState.workflowKey(a.id,repository:catalog.repository.key)) };return a.name<b.name }) { workflow in
                        ViewThatFits(in:.horizontal) {
                            HStack(spacing:12) { workflowHeading(workflow,catalog:catalog); Spacer(minLength:8); workflowControls(workflow,catalog:catalog) }
                            VStack(alignment:.leading,spacing:10) { workflowHeading(workflow,catalog:catalog); HStack { workflowControls(workflow,catalog:catalog);Spacer(minLength:0) } }
                        }.padding(.vertical,8)
                    }
                }
            }
        }.listStyle(.inset).scrollContentBackground(.hidden).padding(.horizontal,12).padding(.bottom,12)
        .overlay { if model.visibleCatalogs.allSatisfy({ catalog in catalog.workflows.filter { model.state.filter.workflow.isEmpty || $0.name.localizedCaseInsensitiveContains(model.state.filter.workflow) }.isEmpty }) && visiblePresets.isEmpty { ContentUnavailableView("No workflows",systemImage:"play.rectangle",description:Text("Workflows appear here for tracked repositories matching these filters.")) } }
    }
    /// Presets are stored across accounts; only those whose repository and workflow are visible here can run.
    private var visiblePresets:[(preset:WorkflowPreset,catalog:ActionsCatalog,workflow:ActionsWorkflow)] {
        let visible=Set(model.visibleCatalogs.map(\.repository.key))
        return model.presets.compactMap { preset in
            guard visible.contains(preset.repository),let catalog=model.catalogs[preset.repository],let workflow=catalog.workflows.first(where:{ $0.id==preset.workflowID }) else { return nil }
            return (preset,catalog,workflow)
        }
    }
    private func workflowHeading(_ workflow:ActionsWorkflow,catalog:ActionsCatalog) -> some View {
        let pinned=model.state.pinnedWorkflows.contains(ActionsViewState.workflowKey(workflow.id,repository:catalog.repository.key))
        return HStack(spacing:12) {
            Button {
                let key=ActionsViewState.workflowKey(workflow.id,repository:catalog.repository.key)
                if model.state.pinnedWorkflows.contains(key) { model.state.pinnedWorkflows.remove(key) }
                else { model.state.pinnedWorkflows.insert(key) }
            } label: { Image(systemName:pinned ? "pin.fill":"pin") }
                .buttonStyle(.borderless).foregroundStyle(DesignTokens.cobalt).help(pinned ? "Unpin workflow":"Pin workflow")
                .accessibilityLabel("Pin "+workflow.name)
                .accessibilityValue(pinned ? "Pinned":"Not pinned")
                .accessibilityAddTraits(pinned ? .isSelected:[])
            VStack(alignment:.leading,spacing:4) { Text(workflow.name).font(.headline);Text(workflow.path).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func workflowControls(_ workflow:ActionsWorkflow,catalog:ActionsCatalog) -> some View {
        HStack(spacing:10) {
            if let last=catalog.runs.first(where:{ $0.workflowID==workflow.id }) { WorkspaceStatusBadge(text:ProviderStateText.actionsStatus(last.conclusion ?? last.status),tint:actionsStatusTint(last.conclusion ?? last.status)) }
            Button("History") { model.state.filter.workflow=String(workflow.id);section="recent" }
            Button(workflow.manualTrigger == true ? "Run…":"Inspect inputs…") { selectedWorkflow = .init(repository:catalog.repository,workflow:workflow,preset:nil) }
                .disabled(workflow.state != "active" || workflow.manualTrigger == false)
        }
    }
    private var deploymentList:some View {
        List {
            ForEach(model.visibleCatalogs,id:\.repository.key) { catalog in Section(catalogTitle(catalog)) {
                ForEach(catalog.deployments.filter { model.state.filter.environment.isEmpty || $0.environment==model.state.filter.environment }) { deployment in
                    ViewThatFits(in:.horizontal) {
                        HStack(spacing:12) { deploymentHeading(deployment);Spacer();deploymentControls(deployment) }
                        VStack(alignment:.leading,spacing:10) { deploymentHeading(deployment);deploymentControls(deployment) }
                    }.padding(.vertical,8)
                }
                ForEach(catalog.runs.filter { $0.status=="waiting" || $0.status=="pending" }) { run in Button { selectedRun=run } label: { Label(run.name+" · Review pending environments",systemImage:"hand.raised") } }
            } }
        }.listStyle(.inset).scrollContentBackground(.hidden).padding(.horizontal,12).padding(.bottom,12)
        .overlay { if model.visibleCatalogs.allSatisfy({ catalog in catalog.deployments.filter { model.state.filter.environment.isEmpty || $0.environment==model.state.filter.environment }.isEmpty && !catalog.runs.contains { $0.status=="waiting" || $0.status=="pending" } }) { ContentUnavailableView("No deployments",systemImage:"shippingbox",description:Text("Deployments and pending environment reviews appear here.")) } }
    }
    private func deploymentHeading(_ deployment:ActionsDeployment) -> some View {
        VStack(alignment:.leading,spacing:5) { Text(deployment.environment).font(.headline);Text(deployment.ref+" · "+String(deployment.sha.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary) }
    }
    private func deploymentControls(_ deployment:ActionsDeployment) -> some View {
        HStack(spacing:10) {
            if deployment.production { WorkspaceStatusBadge(text:"Production",symbol:"exclamationmark.shield",tint:.orange) }
            WorkspaceStatusBadge(text:ProviderStateText.actionsStatus(deployment.state),tint:actionsStatusTint(deployment.state))
            if let url=deployment.webURL { Link("Open",destination:url) }
        }
    }
    private var filterControls:some View {
        Form {
            TextField("Organization",text:$model.state.filter.organization)
            TextField("Workflow name or ID",text:$model.state.filter.workflow);TextField("Branch",text:$model.state.filter.branch);TextField("Event",text:$model.state.filter.event);TextField("Actor",text:$model.state.filter.actor)
            Picker("Status",selection:$model.state.filter.status) { Text("Any").tag("");ForEach(["queued","in_progress","waiting","completed","success","failure","cancelled"],id:\.self) { Text(ProviderStateText.actionsStatus($0)).tag($0) } }
            TextField("Environment",text:$model.state.filter.environment)
            // Day pickers select whole days: From starts at midnight and To includes runs created later that day.
            Toggle("Date range",isOn:Binding(get:{ model.state.filter.after != nil },set:{ if $0 { model.state.filter.after=Calendar.current.date(byAdding:.day,value:-7,to:Calendar.current.startOfDay(for:Date()));model.state.filter.before=endOfDay(Date()) } else { model.state.filter.after=nil;model.state.filter.before=nil } }))
            if model.state.filter.after != nil { DatePicker("From",selection:Binding(get:{ model.state.filter.after ?? Date() },set:{ model.state.filter.after=Calendar.current.startOfDay(for:$0) }),displayedComponents:.date);DatePicker("To",selection:Binding(get:{ model.state.filter.before ?? Date() },set:{ model.state.filter.before=endOfDay($0) }),displayedComponents:.date) }
            Toggle("Oldest first",isOn:$model.state.filter.oldestFirst)
            if !model.state.savedViews.isEmpty { LabeledContent("Saved view") { Menu("Apply…") { ForEach(model.state.savedViews) { view in Button(view.name) { model.state.filter=view.filter } } }.fixedSize() } }
            // A repository filter fixes the owner: the view, and its notification rule, belong to that repository's account.
            if let owner=model.state.filter.repositoryKey?.account {
                if model.availableAccounts.count>1 { LabeledContent("Save view for account",value:model.accountNames[owner] ?? owner.accountID) }
            } else if model.availableAccounts.count>1 { Picker("Save view for account",selection:$model.newViewsAccount) { ForEach(model.availableAccounts,id:\.self) { account in Text(model.accountNames[account] ?? account.accountID).tag(Optional(account)) } } }
            TextField("Save view as",text:$savedViewName);Toggle("Notify for matching runs",isOn:$saveRule)
            HStack { Button("Save view") { model.state.savedViews.append(.init(name:savedViewName.trimmingCharacters(in:.whitespacesAndNewlines),filter:model.state.filter,notificationRule:saveRule));savedViewName="" }.disabled(savedViewName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !model.canSaveView);Button("Reset filters") { model.state.filter = .init() } }
            ForEach(model.state.savedViews) { view in HStack { Text(view.name);Spacer();Button("Remove") { model.state.savedViews.removeAll { $0.id==view.id } } } }
        }.formStyle(.grouped).scrollContentBackground(.hidden).frame(maxHeight:560)
    }
    private func endOfDay(_ date:Date) -> Date { let start=Calendar.current.startOfDay(for:date);return Calendar.current.date(byAdding:DateComponents(day:1,second:-1),to:start) ?? date }
}
struct ActionsWorkflowSelection:Identifiable { let repository:Repository;let workflow:ActionsWorkflow;let preset:WorkflowPreset?;var id:String { repository.name+repository.key.account.accountID+String(workflow.id)+(preset?.id.uuidString ?? "") } }
@MainActor @Observable final class ActionsWorkspaceModel {
    var catalogs:[RepositoryKey:ActionsCatalog]=[:]
    var presets:[WorkflowPreset]=[]
    var state=ActionsViewState()
    var availableAccounts:[AccountScope]=[]
    var accountNames:[AccountScope:String]=[:]
    var newViewsAccount:AccountScope?
    /// Scoped views (repository tabs, PR sheets) keep filters transient; saved views and pins still persist per account.
    var persistsFilter=true
    var loading=false
    var errors:[String:String]=[:]
    var message:String?
    private var service:ActionsService?
    private var accounts:[AccountScope]=[]
    private var accountStates:[AccountScope:ActionsViewState]=[:]
    private var presentedState=ActionsViewState()
    private var persistingState=false
    private var generation=UUID()
    var runs:[WorkflowRun] { catalogs.values.flatMap(\.runs).sorted { $0.createdAt>$1.createdAt } }
    /// A view is stored with its owning account, which must have loaded its saved views.
    var canSaveView:Bool { ActionsViewState.owner(of:state.filter,newViewsAccount:newViewsAccount).map { accountStates[$0] != nil } ?? false }
    var filteredRuns:[WorkflowRun] { runs.filter { state.filter.matches($0,catalog:catalogs[$0.repository.key]) }.sorted { state.filter.oldestFirst ? $0.createdAt<$1.createdAt:$0.createdAt>$1.createdAt } }
    var visibleCatalogs:[ActionsCatalog] { catalogs.values.filter { state.filter.matches(repository:$0.repository) }.sorted { $0.repository.name<$1.repository.name } }
    func load(storage:SetupStorage,repositories:[Repository]) async {
        let token=UUID();generation=token;loading=true;errors=[:];accounts=Array(Set(repositories.map { $0.key.account }));catalogs=catalogs.filter { entry in repositories.contains { $0.key==entry.key } };presets=[]
        defer { if generation==token { loading=false } }
        do {
            let service=try await storage.actionsService();guard generation==token,!Task.isCancelled else { return };self.service=service
            if Set(accountStates.keys) != Set(accounts) {
                var restored:[AccountScope:ActionsViewState]=[:]
                for account in accounts { do { restored[account]=try await service.viewState(account:account) } catch { errors[account.accountID]="Saved Actions views are unavailable for this account." };guard generation==token,!Task.isCancelled else { return } }
                accountStates=restored;availableAccounts=accounts.sorted { $0.accountID<$1.accountID };newViewsAccount=availableAccounts.first
                let snapshots=try await storage.load().0;guard generation==token,!Task.isCancelled else { return }
                accountNames=Dictionary(snapshots.compactMap { $0.account.map { ($0.scope,$0.login) } },uniquingKeysWith:{ _,last in last })
                state=ActionsViewState.aggregate(restored);if !persistsFilter { state.filter = .init() };presentedState=state
            }
            // Cached catalogs first, for every repository: the background poller keeps their runs current, so the
            // page fills at once. A live catalog costs several requests, so only the filtered repository (or the
            // most recently active ones) is read live; picking another repository reads it then (`refresh(repository:)`).
            for repository in repositories {
                if let cached=await AppLog.value(AppLog.actions,"Cached Actions could not be read",fallback:nil,{ try await service.cachedCatalog(repository:repository.key) }),generation==token { catalogs[repository.key]=cached }
            }
            for repository in liveTargets(repositories) {
                guard generation==token,!Task.isCancelled else { return }
                await refreshLive(repository,service:service,token:token)
            }
            guard generation==token else { return };let restoredPresets=try await service.presets();guard generation==token,!Task.isCancelled else { return };presets=restoredPresets;catalogs=catalogs.filter { entry in repositories.contains { $0.key==entry.key } }
        } catch { if generation==token,!Task.isCancelled { errors["Actions"]=providerErrorMessage(error) } }
    }
    /// Repositories read live when the page loads: the filtered one, else the `liveLimit` with the newest cached runs.
    static let liveLimit=12
    private func liveTargets(_ repositories:[Repository]) -> [Repository] {
        let filtered=repositories.filter { state.filter.matches(repository:$0) }
        if filtered.count<=Self.liveLimit { return filtered }
        func newest(_ repository:Repository) -> Date { catalogs[repository.key]?.runs.map(\.createdAt).max() ?? .distantPast }
        return Array(filtered.sorted { newest($0)>newest($1) }.prefix(Self.liveLimit))
    }
    private func refreshLive(_ repository:Repository,service:ActionsService,token:UUID) async {
        do { let catalog=try await service.catalog(repository:repository);guard generation==token,!Task.isCancelled else { return };catalogs[repository.key]=catalog;for section in catalog.unavailableSections.keys.sorted() { errors[repository.name+" · "+section]=catalog.unavailableSections[section] } }
        catch { guard generation==token else { return };errors[repository.name]="Actions could not refresh. "+providerErrorMessage(error) }
    }
    /// Reads one repository live, e.g. after it is picked in the repository filter.
    func refresh(repository:Repository) async {
        guard let service else { return };let token=generation;loading=true;defer { if token==generation { loading=false } }
        await refreshLive(repository,service:service,token:token)
    }
    func refreshCached(repositories:[Repository]) async {
        guard let service else { return };let token=generation
        for repository in repositories {
            do { let cached=try await service.cachedCatalog(repository:repository.key);guard generation==token,!Task.isCancelled else { return };if let cached { catalogs[repository.key]=cached } }
            catch { if generation==token { errors[repository.name]="Cached Actions are unavailable for this account." } }
        }
    }
    func loadHistory() async {
        guard let service else { return };let token=generation;loading=true;defer { if token==generation { loading=false } }
        for catalog in visibleCatalogs {
            do { let history=try await service.history(repository:catalog.repository);guard token==generation,!Task.isCancelled else { return };catalogs[catalog.repository.key]=history }
            catch { if token==generation { errors[catalog.repository.name]="Workflow history could not load completely." } }
        }
    }
    func persist() async {
        guard let service,!persistingState else { return }
        persistingState=true;defer { persistingState=false }
        let token=generation
        while presentedState != state {
            let previous=presentedState,before=accountStates
            var edited=state;if !persistsFilter { edited.filter=previous.filter }
            let changed=ActionsViewState.distributingEdits(from:previous,to:edited,states:before,newViewsAccount:newViewsAccount)
            presentedState=state;accountStates=changed
            var failed=false
            for (account,value) in changed where before[account] != value {
                do { try await service.saveViewState(value,account:account);guard generation==token else { return } }
                catch { if generation==token { accountStates[account]=before[account];errors[account.accountID]="Changes to this account's Actions views could not be saved.";failed=true } }
            }
            if failed { presentedState=previous;return }
            guard generation==token,!Task.isCancelled else { return }
        }
    }
    /// The refreshed catalog only replaces a repository still in scope; a reload for another scope may have dropped it meanwhile.
    func perform(run:WorkflowRun,intent:ActionsIntent) async {
        guard let service else { return }
        do { let operation=try await service.perform(repository:run.repository,intent:intent);message=operation.message ?? ProviderStateText.actionsWrite(operation.state);if let catalog=await AppLog.value(AppLog.actions,"Actions could not be re-read after a command",fallback:nil,{ try await service.catalog(repository:run.repository) }),catalogs[run.repository.key] != nil { catalogs[run.repository.key]=catalog } } catch { message=providerErrorMessage(error) }
    }
}

func actionsStatusTint(_ status:String) -> Color {
    switch status {
    case "success", "approved", "active": .green
    case "failure", "error", "rejected": .red
    case "action_required", "waiting", "pending": .orange
    case "in_progress", "queued", "requested": DesignTokens.cobalt
    default: .secondary
    }
}
