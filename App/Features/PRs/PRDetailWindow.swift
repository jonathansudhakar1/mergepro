import AppKit
import MergeProCore
import SwiftUI

struct PRDetailWindow:View {
    let pr:PullRequest
    let storage:SetupStorage
    let workspace:PRWorkspaceModel?
    @Environment(SetupModel.self) private var setup:SetupModel?
    @Environment(\.openWindow) private var openWindow
    var didLoad:(@MainActor () async -> Void)?
    /// A newer head waiting for the explicit Update; the window keeps its tab, file and search when applied.
    var update:PRDetailPendingUpdate?
    /// Next/Previous through the main workspace's order and in-place stack layers.
    var navigation:PRDetailNavigation?
    /// Loading, paging, comparison, review and merge state and their async work; this view is layout plus bindings.
    @State private var model:PRDetailModel
    @State private var editingMetadata=false
    @State private var actionsPresented=false
    @State private var actionsRunID:Int64?
    @State private var actionVisibilityID=UUID()
    @State private var standaloneActionsRefresh=UUID()
    @FocusState private var searchFocused:Bool
    @State private var fileQuery=""
    @State private var filePicker=false
    /// Highlighted ⌘P result: ↑/↓ move it, Return opens it.
    @State private var jumpHighlight:String?
    @FocusState private var jumpFocused:Bool
    @State private var labelsPresented=false
    @State private var reverting=false
    @State private var revertURL:URL?
    @State private var approving=false
    /// A different action account, or an applied update (new head), rereads everything account-bound.
    private var actionAccountIdentity:String { (workspace?.activeActionAccount.map { $0.host+":"+$0.accountID } ?? "none")+":"+model.pr.headRevision.rawValue }
    /// The action account's row and light reads, shared by header, reviewers, pickers and viewed controls.
    private var account:PRDetailAccountModel { model.account }
    private var accountAvailable:Bool { account.actionPR.map { workspace == nil || workspace?.cached($0.key) != nil } ?? true }
    init(pr:PullRequest,storage:SetupStorage,workspace:PRWorkspaceModel?=nil,didLoad:(@MainActor () async -> Void)? = nil,update:PRDetailPendingUpdate? = nil,navigation:PRDetailNavigation? = nil) {
        self.pr=pr;self.storage=storage;self.workspace=workspace;self.didLoad=didLoad;self.update=update;self.navigation=navigation
        let model=PRDetailModel(pr:pr,storage:storage,link:.workspace(workspace))
        storage.dependencies.fixtures?.detailInstrumentation?.windowWillOpen(model)
        _model=State(initialValue:model)
    }
    var body:some View { presentations(observers(loads(layout))) }
    /// Split into groups so the type checker handles the window quickly.
    private var layout:some View {
        HStack(spacing:0) {
          // Ambiguous inferred chains (e.g. many PRs into a deploy branch) aren't a reviewable stack.
          if let stack=workspace?.stack(for:pr),!stack.isAmbiguousChain { StackSidebar(stack:stack,current:pr.key,workspace:workspace,combined:{ Task { await model.combinedStack(stack) } },navigate:navigation?.open);Divider() }
          VStack(spacing:0) {
            updateBanner
            header.padding(.horizontal,20).padding(.top,14).padding(.bottom,12)
            Divider()
            ScrollView(.horizontal) {
                Picker("Section",selection:$model.tab) { ForEach(PRDetailTab.allCases,id:\.self) { Text(PRDetailText.title($0)).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .padding(.horizontal,20).padding(.vertical,8)
                    .help("Switch sections with ⌃⌘1–⌃⌘6")
            }.scrollIndicators(.hidden).frame(maxWidth:.infinity,alignment:.leading)
            reReviewBanner
            if let loadError=model.loadError { WorkspaceNotice(message:loadError,symbol:"exclamationmark.triangle",tint:.orange).padding(.horizontal,20).padding(.bottom,8) }
            if let comparisonStatus=model.comparisonStatus { WorkspaceNotice(message:comparisonStatus).padding(.horizontal,20).padding(.bottom,8) }
            if let pagingStatus=model.pagingStatus { WorkspaceNotice(message:pagingStatus,symbol:"exclamationmark.triangle",tint:.orange).padding(.horizontal,20).padding(.bottom,8) }
            switch model.tab {
            case .overview: overview()
            case .files:
                if let document=model.shownDocument { files(document) }
                else if model.loading { ProgressView("Loading revision \(pr.headRevision.rawValue.prefix(8))…").frame(maxWidth:.infinity,maxHeight:.infinity) }
                else { ContentUnavailableView("Diff unavailable",systemImage:"doc.questionmark",description:Text("Refresh or open the pull request on GitHub.")) }
            case .commits:
                VStack(alignment:.leading,spacing:0) {
                    commitComparisonControls.padding(.horizontal,20).padding(.vertical,12)
                    Divider()
                    PRCommitsView(pr:pr,storage:storage,section:model.sectionTab == .commits ? model.section : nil,sectionError:model.sectionTab == .commits ? model.sectionError : nil,sectionLoading:model.sectionReadLoading || model.sectionTab != .commits || model.section == nil && model.sectionError == nil,available:workspace == nil || workspace?.cached(pr.key) != nil,refresh:model.refresh,retrySection:{ model.retryContext(.commits) },sources:model.sources)
                }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            default: events
            }
            Divider()
            HStack {
                Text(accountLine).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let navigation {
                    ControlGroup {
                        // ⌥⌘↑/⌥⌘↓ come from the Pull Request menu through this window's command target.
                        Button("Previous pull request",systemImage:"chevron.up") { navigation.previous?() }.disabled(navigation.previous == nil)
                            .help("Previous pull request in the workspace order (⌥⌘↑)")
                        Button("Next pull request",systemImage:"chevron.down") { navigation.next?() }.disabled(navigation.next == nil)
                            .help("Next pull request in the workspace order (⌥⌘↓)")
                    }.labelStyle(.iconOnly).fixedSize().accessibilityIdentifier("prDetailNavigation")
                    if let position=navigation.position { Text(position).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
                Button("Refresh") { refreshAll() }
                Button("Open on web") { openOnWeb() }
            }.padding(.horizontal,20).padding(.vertical,10)
        }
        }
        .background { WorkspaceCanvas() }
        .navigationTitle(pr.title)
        .navigationSubtitle("\(pr.metadata?.repositoryName ?? pr.key.repositoryID) #\(pr.metadata?.number ?? 0)")
        .environment(\.codeAppearance,model.appearance)
    }
    private func loads<V:View>(_ view:V) -> some View {
        view
        .task(id:model.loadIdentity) { await load() }
        .task(id:model.contextIdentity(.checks)) { await model.loadContext(.checks) }
        .task(id:model.contextIdentity(.conversation)) { await model.loadContext(.conversation) }
        .task(id:model.contextIdentity(.overview)) { await model.loadContext(.overview) }
        .task(id:model.sectionIdentity) { await model.loadSection() }
        .task(id:model.pageRequest) { if model.pageRequest != nil,await model.loadMore() { await didLoad?() } }
        .task(id:model.snapshotIdentity) { await model.loadSnapshotFile() }
        .task(id:model.compareRequest) { if let request=model.compareRequest { await model.compare(request:request) } }
        .task(id:model.riskInput) { await model.computeRisks() }
        .task(id:model.prefetchIdentity) { await model.prefetchNextFile() }
        // A different action account rereads everything; an unavailable one is dropped until reselected.
        .task(id:actionAccountIdentity) { await model.actionAccountChanged() }
        .task(id:actionAccountIdentity+":"+model.reReviewIdentity) { await model.loadReReview() }
    }
    private func observers<V:View>(_ view:V) -> some View {
        view
        // An explicit Update applied a new head: same window, tab, file and search; account-bound reads start over.
        .onChange(of:pr) { _,new in model.show(new) }
        // The route switched the workspace serving this row (main or repository-scoped); the window keeps its identity.
        .onChange(of:workspace.map(ObjectIdentifier.init)) { model.link = .workspace(workspace) }
        // Review and merge actions wait for the explicit Update while a newer head is pending.
        .onChange(of:update?.head,initial:true) { old,head in
            model.pendingHead=head
            if head != nil,old != head { AccessibilityNotification.Announcement("New commits available. Choose Update to review them.").post() }
        }
        .onChange(of:pr.state) { old,new in
            if new == .merged,old != .merged { AccessibilityNotification.Announcement("Pull request #\(pr.metadata?.number ?? 0) merged").post() }
        }
        .task(id:actionAccountIdentity+account.epoch.uuidString+String(model.loading)) {
            guard !model.loading,account.administration == nil,accountAvailable else { return }
            await account.loadAdministration()
        }
        .onChange(of:accountAvailable) { if !accountAvailable { account.invalidate() } }
        // "Open Failing Checks" and similar commands ask this window for a section.
        .onChange(of:workspace?.requestedDetailTabs[pr.key],initial:true) { if let requested=workspace?.takeRequestedDetailTab(pr.key) { model.tab=requested } }
        .focusedSceneValue(\.prCommandTarget,commandTarget)
    }
    private func presentations<V:View>(_ view:V) -> some View {
        view
        // Both act only on the head this window shows; a newer action-account head is refused, pointing to Update.
        .sheet(isPresented:$model.merging) { MergeOptionsSheet(readPR:pr,storage:storage,workspace:workspace,requestedAction:model.mergeAction,displayedHead:pr.headRevision.rawValue) }
        .sheet(isPresented:$model.composing) { ReviewComposer(readPR:pr,storage:storage,workspace:workspace,displayedHead:pr.headRevision.rawValue,initialDecision:model.composeDecision,selection:model.composeSelection,didWrite:{ reviewWritten() }) }
        .sheet(isPresented:$editingMetadata) { PRMetadataEditor(readPR:pr,storage:storage,workspace:workspace,account:account,didWrite:{ model.refreshDetail() }) }
        .sheet(isPresented:$reverting) { PRRevertSheet(pr:pr,account:account) { result in revertURL=result.webURL;openWindow(id:"pr-detail",value:result.key) } }
        .sheet(isPresented:$actionsPresented) {
            VStack(spacing:0) {
                HStack { Label("Actions · \(pr.metadata?.repositoryName ?? pr.key.repositoryID)",systemImage:"play.rectangle.fill").font(.headline);Spacer();Button("Close") { actionsPresented=false }.keyboardShortcut(.cancelAction) }.padding(.horizontal,24).padding(.top,16)
                ActionsView(storage:storage,repositories:actionRepositories,accountFilter:pr.key.account,repositoryFilter:pr.key.repository,embedded:true,runID:actionsRunID,initialSection:model.tab == .deployments ? "deployments" : "recent",headSHA:pr.headRevision.rawValue,refreshID:setup?.pollRevision ?? standaloneActionsRefresh)
            }.frame(minWidth:900,idealWidth:1280,maxWidth:.infinity,minHeight:600,idealHeight:840,maxHeight:.infinity)
            .presentationSizing(.fitted)
            .background { WindowFrameMemory(role:"pr-actions",defaultSize:CGSize(width:1280,height:840),minimumSize:CGSize(width:900,height:600),sheet:true) }
            .task { await storage.registerVisibleActions(actionVisibilityID,repository:pr.key.repository) }
            .onAppear { setup?.visibleActionViews += 1 }
            .onDisappear { if let setup { setup.visibleActionViews=max(0,setup.visibleActionViews-1) };Task { await storage.registerVisibleActions(actionVisibilityID,repository:nil) } }
        }
        .sheet(isPresented:$filePicker) { jumpSheet }
        .background {
            WindowKeyMonitor { handleKey($0) }
            Button("Jump to file") { fileQuery="";filePicker=true }.keyboardShortcut("p",modifiers:.command).hidden()
            // ⌃⌘1…⌃⌘6 select the sections in order; the main menu owns ⌘1/⌘2/⌘F/⌘K/⌘R and ⌥⌘1…⌥⌘6.
            ForEach(PRDetailTab.allCases,id:\.self) { value in
                Button(PRDetailText.title(value)) { model.tab=value }.keyboardShortcut(PRDetailText.shortcut(value)).hidden().accessibilityHidden(true)
            }
        }
        .frame(minWidth:900,minHeight:540)
    }
    private var actionRepositories:[Repository] {
        if let repository=workspace?.repositories.first(where:{ $0.key == pr.key.repository }) { return [repository] }
        guard let name=pr.metadata?.repositoryName else { return [] }
        return [.init(key:pr.key.repository,name:name,isPrivate:true,capabilities:[.readWorkflows])]
    }
    private var header:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:10) {
                Image("AppLogo").resizable().scaledToFit().frame(width:32,height:32).accessibilityLabel("MergePro logo")
                Text(pr.title).font(.system(size: 22, weight: .bold, design: .rounded)).lineLimit(2).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                WorkspaceStatusBadge(text: PRDetailText.state(pr),
                    symbol: pr.isDraft ? "pencil.circle" : pr.state == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull",
                    tint: pr.isDraft ? .secondary : pr.state == .merged ? DesignTokens.violet : pr.state == .closed ? .red : .green)
                Text("\(pr.metadata?.repositoryName ?? pr.key.repositoryID) #\(pr.metadata?.number ?? 0)").font(.callout.weight(.semibold)).textSelection(.enabled)
                Label {
                    Text("\(pr.metadata?.headBranch ?? "Unknown") → \(pr.metadata?.baseBranch ?? "Unknown")").font(.system(.callout,design:.monospaced))
                } icon: { Image(systemName:"arrow.triangle.branch") }
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Label(pr.metadata?.authorLogin ?? "Unknown author",systemImage:"person.crop.circle").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing:8) {
                if let metadata=pr.metadata {
                    if metadata.labels.isEmpty { Text("No labels").font(.caption).foregroundStyle(.secondary) }
                    else { LabelChipRow(labels:metadata.labels,colors:metadata.labelColors,limit:8) }
                } else { Text("Labels unknown").font(.caption).foregroundStyle(.secondary) }
                Button("Labels",systemImage:"tag") { labelsPresented=true }.controlSize(.small).accessibilityIdentifier("detailLabels")
                    .popover(isPresented:$labelsPresented,arrowEdge:.bottom) { PRLabelPicker(pr:pr,storage:storage,workspace:workspace,didWrite:{ rowChanged() }) }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                // Newer commits waiting for Update hold every review action, so none covers commits not on screen.
                Group {
                    Button("Approve") { approving=true }
                        .popover(isPresented:$approving,arrowEdge:.bottom) {
                            QuickApprovePopover(pr:pr,account:account,openComposer:{ model.compose(.approve) },approved:{ reviewWritten() })
                        }
                    Button("Request changes") { model.compose(.requestChanges) }
                    Button("Comment") { model.compose(.comment) }
                }.disabled(model.actionsWaitForUpdate).help(model.actionsWaitForUpdate ? Self.waitForUpdateHelp : "")
                Button("Edit metadata / state") { editingMetadata=true }
                // Evidence age alone never disables Merge: the sheet re-verifies before anything is sent.
                Button(workspace?.mergeEligibility(pr).label ?? "Merge") { model.openMerge(nil) }.disabled(!mergeEnabled)
                    .help(model.actionsWaitForUpdate ? Self.waitForUpdateHelp : workspace.map { PRStatusSummary.merge($0.mergeEligibility(pr)).text } ?? "Merge status unknown")
                Menu("Merge actions") {
                    Button("Refresh eligibility") { Task { await workspace?.refreshMergeEvidence(pr) } }
                    Button("Enable auto-merge…") { model.openMerge(.enableAutoMerge) }.disabled(!model.canOpenMerge(.enableAutoMerge))
                    Button("Disable auto-merge…") { model.openMerge(.disableAutoMerge) }
                    Button("Remove from merge queue…") { model.openMerge(.removeQueue) }
                    Button("Update branch…") { model.openMerge(.updateBranch) }
                }
                // Head-branch cleanup applies to same-repository heads of merged/closed PRs only.
                if pr.state != .open,pr.metadata?.headRepositoryID.map({ $0 == pr.key.repositoryID }) ?? true { PRHeadBranchControl(pr:pr,account:account,didWrite:{ rowChanged() }) }
                if pr.state == .merged { Button("Revert…",systemImage:"arrow.uturn.backward.circle") { reverting=true }.accessibilityIdentifier("revertPR") }
                Spacer(minLength: 12)
                PRSubscriptionMenu(account:account)
                // Less frequent actions stay one click away so the bar fits the default window width.
                Menu {
                    Button("Copy branch",systemImage:"doc.on.doc") { NSPasteboard.general.clearContents();NSPasteboard.general.setString(pr.metadata?.headBranch ?? "",forType:.string) }
                    if let setup {
                        Button("Check out locally…",systemImage:"laptopcomputer.and.arrow.down") { setup.showLocalCheckout(pr);openWindow(id:"main") }
                            .disabled(pr.metadata == nil || pr.key.host != "github.com")
                    }
                } label: { Label("More",systemImage:"ellipsis.circle").labelStyle(.iconOnly) }
                    .fixedSize().help("More actions").accessibilityLabel("More actions").accessibilityIdentifier("prDetailMore")
            }
                .padding(8)
            }.scrollIndicators(.hidden)
            .workspaceGlass(radius: 12)
            .padding(.top, 4)
            accountStatus

        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func overview() -> some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment:.firstTextBaseline) {
                        Label("Description", systemImage: "text.alignleft").font(.headline)
                        Spacer()
                        if model.loading { ProgressView().controlSize(.mini) }
                        if let description=model.description,description.cached {
                            Text(prCachedAge(description.fetchedAt)+(model.loading ? " · refreshing" : "")).font(.caption).foregroundStyle(.secondary)
                        } else if model.description == nil,pr.metadata?.descriptionPreview != nil {
                            Text("Saved preview").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let description=model.description {
                        MarkdownView(source:description.body.isEmpty ? "No description." : description.body,webURL:pr.metadata?.webURL)
                    } else if let preview=pr.metadata?.descriptionPreview,!preview.isEmpty {
                        MarkdownView(source:preview,webURL:pr.metadata?.webURL)
                    } else { Text(model.loading ? "Reading the description…" : "Description unavailable. Refresh or open on GitHub.").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18).workspacePanel(radius: 16)
                overviewSection("Details",symbol:"info.circle") {
                    Grid(alignment:.leadingFirstTextBaseline,horizontalSpacing:16,verticalSpacing:8) {
                        GridRow { Text("Author type").foregroundStyle(.secondary);Text((pr.metadata?.authorClassification ?? "unknown").capitalized) }
                        GridRow { Text("Assignees").foregroundStyle(.secondary);Text(listText(pr.metadata?.assignees)) }
                        GridRow {
                            Text("Labels").foregroundStyle(.secondary)
                            if let metadata=pr.metadata,!metadata.labels.isEmpty { LabelChipRow(labels:metadata.labels,colors:metadata.labelColors,limit:12) } else { Text(listText(pr.metadata?.labels)) }
                        }
                    }.textSelection(.enabled)
                    contextStatus(model.overviewSource,label:"Overview context") { model.retryContext(.overview) }
                }
                if !model.loading { PRReviewersPanel(pr:pr,account:account,context:model.overviewSource.section?.overview,didWrite:{ rowChanged() }) }
                if let context=model.overviewSource.section?.overview {
                    overviewSection("Milestone",symbol:"flag") {
                        if let milestone=context.milestone {
                            Text(milestone.title+" · "+(milestone.state ?? "Unknown state"))
                            if let url=milestone.url,safeWeb(url) { Button("Open milestone") { ExternalLinkPolicy.open(url) }.buttonStyle(.link) }
                        } else { Text(context.milestoneKnown ? "No milestone" : "Milestone unknown").foregroundStyle(.secondary) }
                    }
                    overviewSection("Linked issues",symbol:"link") {
                        if context.issues.isEmpty { Text(context.issuesComplete ? "No linked closing issues" : "Linked issues unknown or incomplete").foregroundStyle(.secondary) }
                        ForEach(Array(context.issues.enumerated()),id:\.offset) { _,issue in
                            Text("#\(issue.number) · \(issue.title) · \(issue.state ?? "Unknown state")")
                            if let url=issue.url,safeWeb(url) { Button("Open issue #\(issue.number)") { ExternalLinkPolicy.open(url) }.buttonStyle(.link) }
                        }
                        if !context.issuesComplete { Text("Linked closing issues are partial (up to 100).").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                overviewSection("Risk review",symbol:"exclamationmark.shield") {
                    let flagged=model.risks?.filter { $0.kind != .unviewed } ?? [],unviewed=model.risks?.filter { $0.kind == .unviewed } ?? []
                    if model.detail == nil {
                        Text("Open Files to inspect patches and scan for risks.").foregroundStyle(.secondary)
                        Button("Review files") { model.tab = .files }
                    } else if model.risks == nil { HStack(spacing:6) { ProgressView().controlSize(.small);Text("Scanning loaded patches…").foregroundStyle(.secondary) } }
                    else if flagged.isEmpty && unviewed.isEmpty { Text("No risks detected in loaded patches.").foregroundStyle(.secondary) }
                    ForEach(flagged.prefix(200)) { evidence in
                        Button { if let path=evidence.path { model.openFile(path) } } label: {
                            HStack(spacing:8) {
                                Image(systemName:"exclamationmark.triangle").foregroundStyle(.orange).frame(width:18)
                                Text(evidence.title)
                                Text(evidence.path ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength:0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if flagged.count > 200 { Text("+\(flagged.count-200) more risk locations in loaded patches.").font(.caption).foregroundStyle(.secondary) }
                    // One row for unviewed files instead of one per file, which is unusable on huge PRs.
                    if let first=unviewed.first(where:{ $0.path != nil })?.path {
                        Button { model.openFile(first) } label: {
                            HStack(spacing:8) {
                                Image(systemName:"eye.slash").foregroundStyle(.secondary).frame(width:18)
                                Text("\(unviewed.count) \(unviewed.count == 1 ? "file" : "files") not yet viewed")
                                Text("Open first unviewed").foregroundStyle(.secondary)
                                Spacer(minLength:0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    Text((model.baseline?.explanation ?? "Repository size baseline is loading.")+" Risk detection uses loaded patches; unavailable files are not scanned. Viewed state is local to this revision.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Some HTML, images, and diagrams may require opening the pull request on GitHub.").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
    }
    private func overviewSection<Content:View>(_ title:String,symbol:String,@ViewBuilder content:() -> Content) -> some View {
        VStack(alignment:.leading,spacing:10) {
            Label(title,systemImage:symbol).font(.headline)
            content()
        }.frame(maxWidth:.infinity,alignment:.leading).padding(18).workspacePanel(radius:16)
    }
    private func listText(_ values:[String]?) -> String {
        guard let values else { return "Unknown" }
        return values.isEmpty ? "None" : values.joined(separator:", ")
    }
    private func files(_ document:DiffDocument) -> some View {
        VStack(spacing:0) {
            filesBar(document)
            if model.checksSource.phase != .loaded || model.conversationSource.phase != .loaded {
                HStack(spacing:16) {
                    contextStatus(model.checksSource,label:"Check annotations") { model.retryContext(.checks) }
                    contextStatus(model.conversationSource,label:"Review comments") { model.retryContext(.conversation) }
                    Spacer(minLength:0)
                }.padding(.horizontal,16).padding(.bottom,8)
            }
            if let comparison=model.comparison {
                VStack(alignment:.leading,spacing:6) {
                    HStack(spacing:10) {
                        Label(comparison.comparison == .snapshot ? "Exact snapshot interdiff · \(comparison.baseSHA.prefix(8)) → \(comparison.headSHA.prefix(8)) · candidates verified on selection" : "Three-dot comparison · merge base \(comparison.baseSHA.prefix(8)) → \(comparison.headSHA.prefix(8))",systemImage:"arrow.left.arrow.right").font(.callout.weight(.medium))
                        Spacer(minLength:8)
                        Button("Return to current PR") { model.returnToCanonical() }.controlSize(.small)
                    }
                    Text("Current PR viewed state is disabled; provider review threads map only in the canonical PR diff.").font(.caption).foregroundStyle(.secondary)
                    if let snapshotStatus=model.snapshotStatus { HStack { Text(snapshotStatus).font(.caption);if !model.snapshotLoading { Button("Retry selected snapshot") { model.retrySnapshot() }.controlSize(.small) } } }
                }.padding(12).background(DesignTokens.violet.opacity(0.08),in:RoundedRectangle(cornerRadius:10)).padding(.horizontal,16).padding(.bottom,8)
            }
            if document.missingFileCount > 0 || (model.comparison == nil && model.detail?.nextPage != nil) {
                HStack(spacing:10) {
                    if document.missingFileCount > 0 { Label("At least \(document.missingFileCount) files not loaded or unavailable in this API response. Load additional pages or open Files on GitHub.",systemImage:"exclamationmark.triangle").foregroundStyle(.orange).font(.caption) }
                    Spacer(minLength:0)
                    if model.comparison == nil,model.detail?.nextPage != nil { Button(model.paging ? "Loading next file page…" : "Load next 100 files") { model.requestNextPage() }.disabled(model.paging).controlSize(.small) }
                }.padding(.horizontal,16).padding(.bottom,8)
            }
            if !model.search.isEmpty {
                let result=document.search(model.search)
                HStack(spacing:8) {
                    Text("\(result.matches.count) matches\(result.complete ? "" : " · incomplete: some patches unavailable")").font(.caption.weight(.medium)).foregroundStyle(.secondary).fixedSize()
                    ScrollView(.horizontal) { HStack(spacing:6) { ForEach(result.matches.prefix(50)) { match in Button("\(match.path):\(match.line.newLine ?? match.line.oldLine ?? 0)") { model.reveal(path:match.path,line:match.line.newLine ?? match.line.oldLine,side:match.line.kind == .removed ? .left : .right) }.controlSize(.small) } } }.scrollIndicators(.hidden)
                }.padding(.horizontal,16).padding(.bottom,8)
            }
            Divider()
            HSplitView {
                fileList(document).frame(minWidth:200,idealWidth:260,maxWidth:340)
                Group {
                    if let file=document.files.first(where:{ $0.path == model.selectedFile }) {
                        VStack(spacing:0) {
                            fileHeader(file,document:document)
                            Divider()
                            if document.comparison == .snapshot,file.patch == nil {
                                ContentUnavailableView("Snapshot candidate",systemImage:"doc.text.magnifyingglass",description:Text("Exact content has not been compared. The selected old/new snapshots load within the documented bounds; unavailable content remains unverified."))
                            } else {
                                let requested=model.requestedPath == file.path
                                RichDiffView(pr:pr,file:file,document:document,storage:storage,split:model.split,wrap:model.wrap,hideWhitespace:model.whitespace,requestedLine:requested ? model.requestedLine : nil,requestedSide:requested ? model.requestedSide : nil,annotations:model.annotations+model.commentLocations,reviewRevision:model.detail.map(PRWriteRevision.init),commentSelected:{ value in model.compose(.comment,selection:value) },sources:model.sources,requestToken:requested ? model.requestToken : 0,
                                             threads:model.threads,commentAdded:{ count in account.status="Added to your review draft (\(count) \(count == 1 ? "comment" : "comments")). Submit it with Comment or Request changes." },threadsChanged:{ model.retryContext(.conversation) })
                                    .id(file.path+document.baseSHA+document.headSHA+(file.patch == nil ? ":pending" : ":ready"))
                            }
                        }
                    } else { ContentUnavailableView("Select a file",systemImage:"doc.text.magnifyingglass",description:Text("Choose a changed file to review its diff.")) }
                }.frame(minWidth:420,maxWidth:.infinity,maxHeight:.infinity)
            }
        }
        .task(id:document.headSHA+document.baseSHA) { if model.selectedFile == nil || !document.files.contains(where:{ $0.path == model.selectedFile }) { model.selectedFile=PRDetailModel.displayOrder(document.files).first?.path } }
    }
    private func filesBar(_ document:DiffDocument) -> some View {
        HStack(spacing:12) {
            HStack(spacing:6) {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search entire diff",text:$model.search).textFieldStyle(.plain).focused($searchFocused)
                if !model.search.isEmpty { Button { model.search="" } label: { Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear search") }
            }
            .padding(.horizontal,9).padding(.vertical,5)
            .background(Color.primary.opacity(0.05),in:RoundedRectangle(cornerRadius:7))
            .overlay(RoundedRectangle(cornerRadius:7).strokeBorder(Color(nsColor:.separatorColor).opacity(0.6),lineWidth:1))
            .frame(minWidth:180,maxWidth:420)
            Spacer(minLength:8)
            Toggle("Split",isOn:$model.split).toggleStyle(.checkbox)
            Toggle("Wrap",isOn:$model.wrap).toggleStyle(.checkbox)
            Toggle("Hide whitespace",isOn:$model.whitespace).toggleStyle(.checkbox).help("Hide whitespace changes")
            let next=model.nextUnviewed(document)
            // The unmodified N key is handled by `handleKey` only while no text is being edited (search, thread replies).
            Button("Next unviewed",systemImage:"arrow.down.to.line") { if let next { model.selectedFile=next } }
                .disabled(model.comparison != nil || next == nil).help("Next unviewed file (N)")
        }
        .controlSize(.small).font(.callout)
        .padding(.horizontal,16).padding(.vertical,10)
    }
    private func fileList(_ document:DiffDocument) -> some View {
        let groups=Dictionary(grouping:document.files) { ($0.path as NSString).deletingLastPathComponent }
        let viewedCount=document.files.filter { model.progress.viewed.contains($0.path) }.count
        return VStack(spacing:0) {
            HStack {
                Text("\(document.files.count) \(document.files.count == 1 ? "file" : "files")").font(.caption.weight(.semibold))
                Spacer()
                if model.comparison == nil { Text("\(viewedCount) viewed").font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal,14).padding(.vertical,8)
            if model.comparison == nil,!document.files.isEmpty {
                ProgressView(value:Double(viewedCount),total:Double(document.files.count)).progressViewStyle(.linear).tint(.green).padding(.horizontal,14).padding(.bottom,6)
            }
            Divider()
            List(selection:$model.selectedFile) {
                ForEach(groups.keys.sorted(),id:\.self) { directory in
                    Section(directory.isEmpty ? "/" : directory) {
                        ForEach(groups[directory]!.sorted { $0.path < $1.path }) { file in fileRow(file,document:document).tag(file.path) }
                    }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden).accessibilityIdentifier("detailFiles")
        }
    }
    private func fileRow(_ file:DiffFile,document:DiffDocument) -> some View {
        let viewed=model.comparison == nil && model.progress.viewed.contains(file.path)
        return HStack(spacing:8) {
            Image(systemName:statusSymbol(file.status)).foregroundStyle(statusTint(file.status)).frame(width:16).help(PRDetailText.status(file.status)).accessibilityLabel(PRDetailText.status(file.status))
            VStack(alignment:.leading,spacing:2) {
                Text((file.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle).foregroundStyle(viewed ? .secondary : .primary)
                if let old=file.previousPath { Text("Renamed from \(old)").font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                if document.comparison == .snapshot { Text(file.patch == nil ? "Candidate · contents unverified" : file.status == .unchanged ? "Verified unchanged" : "Verified snapshot difference").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength:4)
            if viewed { Image(systemName:"checkmark.circle.fill").foregroundStyle(.green).font(.caption).accessibilityLabel("Viewed") }
            else if file.additions+file.deletions > 0 { changeCounts(file).font(.caption2.monospacedDigit()) }
        }
    }
    /// Colour stays on the small +/− glyphs; the counts are plain text so they read in every appearance.
    private func changeCounts(_ file:DiffFile) -> some View {
        HStack(spacing:6) {
            if file.additions > 0 { HStack(spacing:1) { Image(systemName:"plus").foregroundStyle(.green).imageScale(.small);Text("\(file.additions)") } }
            if file.deletions > 0 { HStack(spacing:1) { Image(systemName:"minus").foregroundStyle(.red).imageScale(.small);Text("\(file.deletions)") } }
        }.foregroundStyle(.secondary).accessibilityElement(children:.ignore).accessibilityLabel(PRDetailText.changes(file))
    }
    private func fileHeader(_ file:DiffFile,document:DiffDocument) -> some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(spacing:10) {
                Image(systemName:statusSymbol(file.status)).foregroundStyle(statusTint(file.status)).accessibilityHidden(true)
                Text(file.path).font(.system(.callout,design:.monospaced).weight(.semibold)).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(file.path)
                changeCounts(file).font(.caption.monospacedDigit().weight(.medium))
                Spacer(minLength:8)
                Toggle("Viewed",isOn:Binding(get:{ model.comparison == nil && model.progress.viewed.contains(file.path) },set:{ model.setViewed(file.path,viewed:$0,displayed:document) }))
                    .toggleStyle(.checkbox).disabled(model.comparison != nil).help("Mark viewed locally")
            }
            if model.comparison == nil,let snapshot=model.detail { PRViewedControl(pr:pr,snapshot:snapshot,path:file.path,account:account) }
        }.padding(.horizontal,14).padding(.vertical,10)
    }
    private func statusSymbol(_ status:DiffFile.Status) -> String {
        switch status {
        case .added: "plus.square.fill"
        case .removed: "minus.square.fill"
        case .renamed,.copied: "arrow.right.square.fill"
        case .unchanged: "equal.square"
        default: "square.and.pencil"
        }
    }
    private func statusTint(_ status:DiffFile.Status) -> Color {
        switch status {
        case .added: .green
        case .removed: .red
        case .renamed,.copied: DesignTokens.violet
        case .unchanged: .secondary
        default: .orange
        }
    }
    private var events:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                if model.tab == .checks || model.tab == .deployments {
                    Button(model.tab == .deployments ? "Open deployment approvals" : "Actions for this revision") { actionsRunID=nil;actionsPresented=true }
                }
                if model.tab == .conversation { ReviewThreadView(readPR:pr,storage:storage,workspace:workspace,didWrite:{ model.threads.reset();model.refreshDetail() }) }
                if model.eventSource == nil,model.sectionTab == model.tab,model.section != nil {
                    if model.sectionReadLoading { ProgressView("Refreshing \(PRDetailText.title(model.tab).lowercased())…").controlSize(.small) }
                    if let sectionError=model.sectionError { Text(sectionError).font(.caption).foregroundStyle(.orange);Button("Retry") { model.retryContext(model.tab) }.controlSize(.small) }
                }
                if let section=model.eventSection {
                    if section.cached { Text(prCachedAge(section.fetchedAt)+(model.eventLoading ? " · refreshing" : model.eventFailed ? " · refresh failed" : "")).font(.caption).foregroundStyle(.secondary) }
                    ForEach(section.events) { event in
                        VStack(alignment:.leading,spacing:6) {
                            Text(event.title).font(.headline)
                            if let sha=event.sha { Button(String(sha.prefix(12))) { model.compareBase=sha;model.compareHead=pr.headRevision.rawValue }.buttonStyle(.link) }
                            if let anchor=event.anchor { Text("\(anchor.path):\(anchor.startLine)–\(anchor.endLine) · \(anchor.side) · \(anchor.commitSHA.prefix(8))").font(.caption) }
                            if let commit=event.commitContext {
                                Text("Author: \(commit.authorLogin ?? commit.authorName ?? "Unknown") · \(PRStatusSummary.checks(commit.checksState).text)").font(.caption)
                            }
                            if let timing=event.checkTiming {
                                Text(timing.duration.map { "Duration: \(Int($0)) seconds" } ?? "Duration: unknown or still running").font(.caption)
                            }
                            if let coordinates=event.commentCoordinates {
                                Text("Provider current: "+coordinateText(coordinates.current,path:coordinates.path)).font(.caption)
                                Text("Provider original: "+coordinateText(coordinates.original,path:coordinates.path)+" · retained, not remapped").font(.caption)
                                if event.renderingAnchor(in:model.detail?.document ?? .init(baseSHA:"",headSHA:"",files:[],expectedFiles:0)) == nil { Text("Outdated or unmapped comment").font(.caption).foregroundStyle(.secondary) }
                            }
                            if let location=event.providerComment {
                                Text("\(location.path):\(location.startLine)–\(location.endLine) · \(location.side) · reviewed \(location.reviewedHeadSHA.prefix(8))").font(.caption)
                                if let detail=model.detail,event.renderingAnchor(in:detail.document) != nil { Button("Show comment location") {
                                    // Provider threads map only onto the canonical PR diff, so leave any comparison first.
                                    model.showCommentLocation(location)
                                } }
                            }
                            MarkdownView(source:event.body,webURL:event.url ?? pr.metadata?.webURL)
                            if let url=event.url,safeWeb(url) { Button("Open on GitHub") { ExternalLinkPolicy.open(url) }.buttonStyle(.link) }
                            if let url=event.url,let runID=workflowRunID(url) {
                                Button("Open workflow run") { actionsRunID=runID;actionsPresented=true }
                            }
                        }.padding(14).frame(maxWidth:.infinity,alignment:.leading).workspacePanel(radius:12)
                    }
                    if section.events.isEmpty { Text("No \(PRDetailText.title(model.tab).lowercased()) returned for this revision.") }
                    if !section.complete { Text("Partial provider response. Open GitHub for remaining entries.") }
                } else if let error=model.eventError {
                    WorkspaceNotice(message:error,symbol:"exclamationmark.triangle",tint:.orange)
                    Button("Retry") { model.retryContext(model.tab) }.controlSize(.small)
                }
                else if model.eventLoading { ProgressView("Reading \(PRDetailText.title(model.tab).lowercased())…").controlSize(.small) }
                else { Text("Load or refresh this tab to read provider context.").foregroundStyle(.secondary) }
                Text("Use Conversation for replies and review commands. Open Actions for job logs and available deployment approvals.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth:.infinity,alignment:.leading).padding(20)
        }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
    }
    private var commitComparisonControls:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack { TextField("Original commit SHA or ref",text:$model.compareBase);TextField("Target SHA or ref",text:$model.compareHead) }
            HStack {
                Group {
                    Button("Compare three-dot") { model.startComparison(snapshots:false) }
                    Button("Compare snapshots") { model.startComparison(snapshots:true) }
                }.disabled(model.compareBase.trimmingCharacters(in:.whitespaces).isEmpty || model.compareHead.trimmingCharacters(in:.whitespaces).isEmpty)
                if let reReview=model.reReview,reReview.hasNewCommits { Button("Changes since your review (\(reReview.reviewedHead.prefix(8)))") { model.showChangesSinceReview(reReview) } }
            }.controlSize(.small)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func workflowRunID(_ url:URL) -> Int64? {
        guard url.scheme == "https",url.host == "github.com",url.user == nil,url.password == nil else { return nil }
        let parts=url.path.split(separator:"/")
        guard parts.count >= 5,parts[2] == "actions",parts[3] == "runs",let id=Int64(parts[4]),id > 0 else { return nil }
        return id
    }
    private func coordinateText(_ value:PRCommentCoordinates.Location,path:String?) -> String {
        "\(path ?? "Unknown path") · \(value.startSide ?? value.side ?? "Unknown side"):\(value.startLine.map(String.init) ?? "nil")–\(value.side ?? "Unknown side"):\(value.endLine.map(String.init) ?? "nil") · reviewed \(value.reviewedHeadSHA ?? "Unknown commit")"
    }
    private func contextStatus(_ source:PRContextSource,label:String,retry:@escaping () -> Void) -> some View {
        HStack {
            Text(label+": "+PRDetailModel.phaseText(source))
            if [.failed,.partial,.idle].contains(source.phase) { Button("Retry",action:retry).controlSize(.small) }
        }.font(.caption).foregroundStyle(source.phase == .failed || source.phase == .partial ? Color.orange : Color.secondary)
    }
    private func safeWeb(_ url:URL) -> Bool { url.scheme == "https" && url.user == nil && url.password == nil }
    private func load() async {
        let instrumentation=storage.dependencies.fixtures?.detailInstrumentation
        await instrumentation?.loadWillBegin(pr.key,model:model)
        if await model.load(trace:instrumentation?.loadTrace(pr.key) ?? PRDetailLoadTrace()) { await didLoad?() }
    }
    /// Write outcomes from header, reviewers and pickers, with durable reconcile actions.
    @ViewBuilder private var accountStatus:some View {
        if let message=account.status {
            HStack(alignment:.top,spacing:8) {
                WorkspaceNotice(message:message)
                if let revertURL { Button("Open revert on GitHub") { ExternalLinkPolicy.open(revertURL) }.buttonStyle(.link).font(.callout) }
                Button { account.status=nil;revertURL=nil } label: { Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Dismiss message")
            }
        }
        if account.blocked,let error=account.actionError {
            HStack(spacing:8) {
                Label(error,systemImage:"lock").font(.caption).foregroundStyle(.orange)
                Button("Read selected account") { account.reset();Task { await account.loadAdministration() } }.controlSize(.small)
            }
        }
        if let key=account.actionPR?.key {
            PRWriteStatusView(key:key,storage:storage,changeSignal:account.operationRevision) { await account.reconciled();rowChanged() }.font(.caption)
        }
    }
    /// The window's Refresh: an explicit action, so a waiting update is applied too.
    private func refreshAll() {
        if let update { update.apply();return }
        model.refreshDetail();Task { await account.reconciled() }
    }
    /// A confirmed light write changed the stored row; let the route refresh it.
    private func rowChanged() { Task { await didLoad?() } }
    /// A review or comment was confirmed: reread what it changed, including "Changes since your review".
    private func reviewWritten() { model.reviewWritten();let account=account;Task { await account.loadAdministration();await didLoad?() } }
    private func openOnWeb() {
        guard let url=pr.metadata?.webURL else { return }
        ExternalLinkPolicy.open(PRDetailText.webPath(model.tab).map { url.appendingPathComponent($0) } ?? url)
    }
    private func copyLink() {
        guard let url=pr.metadata?.webURL else { return }
        NSPasteboard.general.clearContents();NSPasteboard.general.setString(url.absoluteString,forType:.string)
        AccessibilityNotification.Announcement("Link copied").post()
    }
    /// The Pull Request menu acts on this window when it is focused. Review and merge commands are unavailable while
    /// newer commits wait for Update, like the header buttons.
    private var commandTarget:PRCommandTarget {
        let reviewable = !model.actionsWaitForUpdate
        return PRCommandTarget(subject:"#\(pr.metadata?.number ?? 0)",open:nil,
                        approve:reviewable ? { approving=true } : nil,requestChanges:reviewable ? { model.compose(.requestChanges) } : nil,comment:reviewable ? { model.compose(.comment) } : nil,
                        merge:mergeEnabled ? { model.openMerge(nil) } : nil,
                        labels:{ labelsPresented=true },refresh:{ refreshAll() },
                        copyLink:pr.metadata?.webURL == nil ? nil : { copyLink() },openOnWeb:pr.metadata?.webURL == nil ? nil : { openOnWeb() },
                        nextPR:navigation?.next,previousPR:navigation?.previous)
    }
    private var mergeEnabled:Bool { model.canOpenMerge(nil) && workspace?.mergeEligibility(pr).opensMergeSheet == true }
    private static let waitForUpdateHelp="New commits are waiting. Choose Update and review them first."
    /// Which accounts read and act: logins, never numeric account IDs.
    private var accountLine:String {
        let reader=workspace?.accounts.first { $0.scope == pr.key.account }?.login
        var text=pr.key.host+" · "+(reader.map { "Read as \($0)" } ?? "Reading account")
        if !account.login.isEmpty,account.login != reader { text += " · Actions as \(account.login)" }
        return text
    }

    // MARK: New commits and re-review

    @ViewBuilder private var updateBanner:some View {
        if let update {
            HStack(spacing:10) {
                Image(systemName:"arrow.down.circle.fill").foregroundStyle(DesignTokens.cobalt).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:2) {
                    Text("New commits").font(.callout.weight(.semibold))
                    Text("This window shows \(pr.headRevision.rawValue.prefix(8)); the pull request is now at \(update.head.prefix(8)). Your tab, file and search stay as they are.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength:8)
                Button("Update") { update.apply() }.buttonStyle(.borderedProminent).controlSize(.small).accessibilityIdentifier("prDetailUpdate")
            }
            .padding(.horizontal,20).padding(.vertical,8).background(DesignTokens.cobalt.opacity(0.08))
            .accessibilityElement(children:.contain)
        }
    }
    @ViewBuilder private var reReviewBanner:some View {
        if let reReview=model.reReview,reReview.hasNewCommits,update == nil,model.comparison?.baseSHA != reReview.reviewedHead {
            HStack(spacing:10) {
                Image(systemName:"arrow.triangle.2.circlepath").foregroundStyle(DesignTokens.cobalt).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:2) {
                    Text(reReview.reRequested == true ? "Your review was re-requested" : "New commits since your review").font(.callout.weight(.semibold))
                    Text("You reviewed \(reReview.reviewedHead.prefix(8))\(reReview.source == .provider ? " (GitHub)" : ""); the pull request is now at \(reReview.currentHead.prefix(8)).").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength:8)
                Button("Show changes since your review") { model.showChangesSinceReview(reReview) }.buttonStyle(.borderedProminent).controlSize(.small).accessibilityIdentifier("changesSinceReview")
            }
            .padding(10).background(DesignTokens.cobalt.opacity(0.08),in:RoundedRectangle(cornerRadius:10))
            .padding(.horizontal,20).padding(.bottom,8)
        }
    }

    // MARK: Jump to file (⌘P)

    private var jumpSheet:some View {
        let files=model.jumpFiles(fileQuery)
        return VStack(alignment:.leading,spacing:8) {
            TextField("Jump to file",text:$fileQuery).textFieldStyle(.roundedBorder).focused($jumpFocused).accessibilityIdentifier("jumpToFileField")
                .onSubmit { openJump(files) }
                .onKeyPress(.downArrow) { moveJump(1,in:files);return .handled }
                .onKeyPress(.upArrow) { moveJump(-1,in:files);return .handled }
            ScrollViewReader { proxy in
                List(files) { file in
                    let highlighted=file.path == jumpHighlight
                    Button { model.selectedFile=file.path;model.tab = .files;filePicker=false } label: {
                        HStack(spacing:8) {
                            Image(systemName:statusSymbol(file.status)).foregroundStyle(statusTint(file.status)).accessibilityLabel(PRDetailText.status(file.status))
                            Text(file.path).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength:0)
                        }.padding(.vertical,2).padding(.horizontal,6).contentShape(Rectangle())
                        .background(highlighted ? Color.accentColor.opacity(0.18) : .clear,in:RoundedRectangle(cornerRadius:6))
                    }.buttonStyle(.plain).id(file.path)
                    .accessibilityAddTraits(highlighted ? .isSelected : [])
                }
                .onChange(of:jumpHighlight) { _,path in if let path { proxy.scrollTo(path) } }
            }
            HStack {
                Text(files.isEmpty ? "No matching files" : "↑↓ to choose · Return to open").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { filePicker=false }.keyboardShortcut(.cancelAction)
            }
        }.padding().frame(width:500,height:350)
        .onAppear { jumpFocused=true;jumpHighlight=files.first?.path }
        .onChange(of:fileQuery) { jumpHighlight=model.jumpFiles(fileQuery).first?.path }
    }
    /// Single-key commands in this window, never while a text field or editor has focus: "?" opens the
    /// keyboard shortcuts list, N opens the next unviewed file.
    private func handleKey(_ event:NSEvent) -> Bool {
        guard !Self.editingText(event.window?.firstResponder) else { return false }
        let key=event.charactersIgnoringModifiers,modifiers=event.editingModifiers
        if key == "?",modifiers.isSubset(of:[.shift]) { KeyboardShortcutsHelp.show();return true }
        if key == "n",modifiers.isEmpty,model.selectNextUnviewed() { return true }
        return false
    }
    static func editingText(_ responder:NSResponder?) -> Bool {
        if let text=responder as? NSTextView { return text.isEditable }
        if let field=responder as? NSTextField { return field.isEditable }
        return false
    }
    private func moveJump(_ step:Int,in files:[DiffFile]) {
        guard !files.isEmpty else { jumpHighlight=nil;return }
        let index=files.firstIndex { $0.path == jumpHighlight }.map { $0+step } ?? (step > 0 ? 0 : files.count-1)
        jumpHighlight=files[min(max(index,0),files.count-1)].path
    }
    private func openJump(_ files:[DiffFile]) {
        guard let path=jumpHighlight ?? files.first?.path else { return }
        model.openJump(path);filePicker=false
    }
}
