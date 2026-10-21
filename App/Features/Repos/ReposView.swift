import AppKit
import SwiftUI
import MergeProCore

struct ReposView:View {
    let setup:SetupModel
    let storage:SetupStorage
    var pullRequests:(RepositoryKey) -> AnyView = { _ in AnyView(EmptyView()) }
    var actions:(RepositoryKey) -> AnyView = { _ in AnyView(EmptyView()) }
    var openPR:(ProviderKey) -> Void = { _ in }
    var route:RepoNavigationRoute? = nil
    @State private var model=ReposModel()
    @State private var appearance=CodeAppearance()
    @State private var createPR=false
    /// The PR head is chosen per sheet; the browser's ref field keeps describing the resolved ref.
    @State private var createPRHead=""
    @State private var catalogPresented=false
    var body:some View {
        GeometryReader { geometry in
            let compact=geometry.size.width<860
            VStack(spacing:0) {
                WorkspaceSectionHeader(title:"Repositories",subtitle:"\(model.entries.count) \(model.entries.count == 1 ? "repository" : "repositories") across your connected accounts",symbol:"shippingbox") {
                    if model.busy { ProgressView().controlSize(.small) }
                    if compact,model.repository != nil {
                        Button { catalogPresented.toggle() } label:{ Label("Catalog",systemImage:"sidebar.left") }
                            .popover(isPresented:$catalogPresented,arrowEdge:.bottom) {
                                VStack(alignment:.leading,spacing:0) {
                                    Text("Repository Catalog").font(.headline).padding(14)
                                    Divider()
                                    catalog
                                }.frame(width:340,height:440)
                            }
                    }
                    Picker("View",selection:$model.treeMode) { Label("Tree",systemImage:"list.bullet.indent").tag(true);Label("List",systemImage:"list.bullet").tag(false) }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    Button { Task { await model.refresh() } } label:{ Image(systemName:"arrow.clockwise") }.help("Refresh Repositories").accessibilityLabel("Refresh repositories").keyboardShortcut("r",modifiers:.command)
                }
                filters
                if let error=model.error {
                    HStack(alignment:.top) {
                        WorkspaceNotice(message:error,symbol:"exclamationmark.circle",tint:.red)
                        Button("Dismiss") { model.error=nil }.padding(.top,12)
                    }.padding(.horizontal,24).padding(.bottom,10)
                }
                if !model.accountProblems.isEmpty {
                    WorkspaceNotice(message:"Some accounts could not refresh. Available accounts remain visible; reconnect unavailable accounts in Setup.",symbol:"exclamationmark.triangle",tint:.orange)
                        .padding(.horizontal,24).padding(.bottom,10)
                }
                HStack(spacing:0) {
                    if !compact {
                        catalog.frame(width:min(300,geometry.size.width*0.28))
                        Divider()
                    }
                    Group {
                        if let repository=model.repository,let service=model.service {
                            VStack(spacing:0) {
                                browserHeader(repository)
                                Divider()
                                Group {
                                    switch model.section {
                                    case "history": RepoHistoryView(repository:repository,ref:model.ref,service:service,openPR:openPR)
                                    case "branches": RepoBranchesView(model:model,createPR:{ name in createPRHead=name;createPR=true },openPR:openPR,canCreatePR:setup.activeAccount == repository.key.account)
                                    case "releases": RepoReleasesView(repository:repository,service:service,selectRef:{ model.changeRef($0);model.section="code" })
                                    case "pullRequests": pullRequests(repository.key)
                                    case "labels": RepoLabelsView(repository:repository,service:service,canWrite:setup.activeAccount == repository.key.account,labelsChanged:{ await setup.refreshActivity(reason:.scheduled) })
                                    case "actions": actions(repository.key)
                                    default: RepoCodeView(repository:repository,ref:model.ref,service:service,initialPath:model.initialPath,initialLine:model.initialLine)
                                    }
                                }.frame(maxWidth:.infinity,maxHeight:.infinity)
                            }.id(repository.key)
                            .task(id:model.generation) { await model.open() }
                        } else if compact {
                            catalog
                        } else {
                            ContentUnavailableView("Choose a Repository",systemImage:"shippingbox",description:Text("Browse files, history, branches and releases across your connected accounts."))
                        }
                    }.frame(maxWidth:.infinity,maxHeight:.infinity)
                }
                .background(Color(nsColor:.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius:16))
                .overlay(RoundedRectangle(cornerRadius:16).strokeBorder(Color(nsColor:.separatorColor).opacity(0.4),lineWidth:1).allowsHitTesting(false))
                .padding(.horizontal,24).padding(.bottom,20)
            }.onChange(of:compact) { _,_ in catalogPresented=false }
        }
        .background { WorkspaceCanvas() }
        .onChange(of:model.selected) { _,_ in catalogPresented=false }
        .onChange(of:model.error) { _,message in if let message { AccessibilityNotification.Announcement(message).post() } }
        .environment(\.codeAppearance,appearance)
        .task { appearance=(try? await storage.codeAppearance()) ?? CodeAppearance();await model.load(storage:storage,route:route) }
        .onChange(of:route) { _,route in if let route { model.route(route) } }
        .onChange(of:model.filter) { _,_ in var filtered=model.filter;filtered.search="";model.tree.refresh(filtered.apply(model.entries));model.tree.search=model.filter.search }
        .onChange(of:setup.accountProblems) { _,problems in model.invalidateAccounts(Set(problems.keys)) }
        .onChangeTask(of:setup.accountProblems) { _ in await model.refresh() }
        .onChange(of:setup.snapshots) { _,snapshots in let known=Set(snapshots.compactMap { $0.account?.scope });model.invalidateAccounts(Set(model.entries.map { $0.key.account }).subtracting(known)) }
        .sheet(isPresented:$createPR) {
            if let repository=model.repository,let service=model.service { CreatePRSheet(repository:repository,head:createPRHead,branches:model.branches,service:service,openPR:openPR) }
        }
    }
    private var filters:some View {
        ScrollView(.horizontal) {
            VStack(alignment:.leading,spacing:10) {
                HStack(spacing:12) {
                    TextField("Search repositories",text:$model.filter.search).textFieldStyle(.roundedBorder).frame(width:240)
                    Picker("Sort",selection:$model.filter.sort) { ForEach(RepoCatalogSort.allCases,id:\.self) { Text(Self.title($0)).tag($0) } }.frame(width:150)
                    Toggle("Pinned",isOn:$model.filter.pinnedOnly).toggleStyle(.checkbox)
                    Toggle("Open PRs",isOn:$model.filter.hasOpenPRs).toggleStyle(.checkbox)
                }.fixedSize(horizontal:true,vertical:false)
                HStack(spacing:12) {
                    Picker("Owner",selection:$model.filter.owner) { Text("All owners").tag("");ForEach(Array(Set(model.entries.map(\.owner)+model.tree.owners.map(\.name))).sorted(),id:\.self) { Text($0).tag($0) } }.frame(width:150)
                    Picker("Language",selection:$model.filter.language) { Text("All languages").tag("");ForEach(Array(Set(model.entries.compactMap(\.language))).sorted(),id:\.self) { Text($0).tag($0) } }.frame(width:160)
                    TextField("Topic",text:$model.filter.topic).textFieldStyle(.roundedBorder).frame(width:100)
                    Picker("Visibility",selection:$model.filter.visibility) { Text("All").tag(Optional<Bool>.none);Text("Private").tag(Optional(true));Text("Public").tag(Optional(false)) }
                    Picker("Archived",selection:$model.filter.archived) { Text("Any").tag(Optional<Bool>.none);Text("Active").tag(Optional(false));Text("Archived").tag(Optional(true)) }
                    Picker("Fork",selection:$model.filter.fork) { Text("Any").tag(Optional<Bool>.none);Text("Forks").tag(Optional(true));Text("Sources").tag(Optional(false)) }
                }.fixedSize(horizontal:true,vertical:false)
            }.controlSize(.small).padding(.horizontal,14).padding(.vertical,12)
        }
        .scrollIndicators(.hidden)
        .fixedSize(horizontal:false,vertical:true).workspaceGlass(radius:16).padding(.horizontal,24).padding(.bottom,14)
    }
    private func catalogRow(_ repository:RepoCatalogEntry) -> some View {
        VStack(alignment:.leading,spacing:4) {
            HStack { if repository.pinned { Image(systemName:"pin.fill").foregroundStyle(DesignTokens.violet).accessibilityLabel("Pinned") };Text(repository.repository.name).font(.headline).lineLimit(2) }
            Text(Self.summary(repository)).font(.caption).foregroundStyle(.secondary)
            HStack(spacing:7) { PRStatusLabel(value:ProviderStateText.checks(repository.defaultCI)).help("Default branch checks");Text(Self.openPRText(repository.openPRs)+" · ★ \(repository.stars)").foregroundStyle(.secondary) }.font(.caption)
            if let pushed=repository.pushedAt { Text("Pushed "+pushed.formatted(date:.abbreviated,time:.omitted)).font(.caption).foregroundStyle(.secondary) }
            if let release=repository.latestRelease { Text("Release "+release).font(.caption) }
        }
    }
    static func summary(_ repository:RepoCatalogEntry) -> String {
        let visibility=repository.repository.isPrivate ? "Private" : "Public"
        let language=repository.language ?? "No language"
        return "\(repository.accountLogin) · \(visibility) · \(language)"
    }
    @ViewBuilder private var catalog:some View {
        if model.entries.isEmpty && (!model.treeMode || model.tree.roots.isEmpty) { ContentUnavailableView("No Accessible Repositories",systemImage:"shippingbox",description:Text("Connect an account or refresh its repository access in Setup.")) }
        else if model.treeMode ? model.tree.visibleRoots.isEmpty : model.visible.isEmpty { ContentUnavailableView("No Matching Repositories",systemImage:"magnifyingglass",description:Text("Adjust your search or filters to see more repositories.")) }
        else if model.treeMode { RepoTreeView(model:model) }
        else {
            List(selection:Binding(get:{ model.selected },set:{ if let key=$0 { model.select(key) } })) {
                ForEach(model.visible) { repository in
                    catalogRow(repository).tag(repository.key).padding(.vertical,4)
                    .contextMenu { Button(repository.pinned ? "Unpin" : "Pin") { Task { await model.pin(repository) } };Button("Open on GitHub") { ExternalLinkPolicy.open(repository.webURL) } }
                    .task(id:repository.key) { await model.enrich(repository) }
                }
            }
        }
    }
    private func browserHeader(_ repository:RepoCatalogEntry) -> some View {
        VStack(alignment:.leading,spacing:12) {
            ViewThatFits(in:.horizontal) {
                HStack(spacing:12) { repositoryTitle(repository);Spacer(minLength:8);repositoryActions(repository) }
                VStack(alignment:.leading,spacing:10) { repositoryTitle(repository);repositoryActions(repository) }
            }
            ScrollView(.horizontal) {
                HStack(spacing:10) {
                    Menu {
                        ForEach(model.branches) { branch in Button(branch.name) { model.changeRef(branch.name) } }
                        if model.branchPage != nil { Button("Load More Branches") { Task { await model.moreBranches() } } }
                        Divider()
                        ForEach(model.tags) { tag in Button("Tag: "+tag.name) { model.changeRef(tag.name) } }
                        if model.tagPage != nil { Button("Load More Tags") { Task { await model.moreTags() } } }
                    } label:{ Label(model.refName.isEmpty ? repository.defaultBranch : model.refName,systemImage:"arrow.triangle.branch").lineLimit(1) }
                    .frame(maxWidth:180)
                    TextField("Branch, tag or commit SHA",text:$model.refName).textFieldStyle(.roundedBorder).frame(width:200).onSubmit { model.changeRef(model.refName) }
                    if let ref=model.ref { Text(String(ref.commitSHA.prefix(8))).font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }
                }.padding(.bottom,2)
            }.fixedSize(horizontal:false,vertical:true)
            ViewThatFits(in:.horizontal) {
                sectionPicker.pickerStyle(.segmented).fixedSize(horizontal:true,vertical:false)
                sectionPicker.pickerStyle(.menu).fixedSize(horizontal:true,vertical:false)
            }.frame(maxWidth:.infinity,alignment:.leading)
        }.padding(16)
        .background(Color(nsColor:.windowBackgroundColor))
    }
    private var sectionPicker:some View {
        Picker("Section",selection:$model.section) {
            Text("Code").tag("code");Text("Commits").tag("history");Text("Branches").tag("branches");Text("Releases").tag("releases");Text("Pull Requests").tag("pullRequests");Text("Labels").tag("labels");Text("Actions").tag("actions")
        }.labelsHidden().accessibilityIdentifier("repoSectionPicker")
    }
    static func title(_ sort:RepoCatalogSort) -> String {
        switch sort { case .name:"Name";case .lastPush:"Last push";case .openPRs:"Open PRs";case .failingCI:"Failing checks first";case .stars:"Stars" }
    }
    /// Open PR counts load lazily; until then the count is shown as unknown, never as zero.
    static func openPRText(_ count:Int?) -> String { count.map { $0 == 1 ? "1 open PR" : "\($0) open PRs" } ?? "Open PRs unknown" }
    private func repositoryTitle(_ repository:RepoCatalogEntry) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text(repository.repository.name).font(.system(.title3,design:.rounded).weight(.semibold)).lineLimit(2)
            Text(repository.accountLogin+" · "+(repository.repository.isPrivate ? "Private repository" : "Public repository")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func repositoryActions(_ repository:RepoCatalogEntry) -> some View {
        HStack(spacing:8) {
            Button { Task { await model.pin(repository) } } label:{ Label(repository.pinned ? "Unpin" : "Pin",systemImage:repository.pinned ? "pin.slash" : "pin") }
            Button("Create PR") { createPRHead=model.ref?.name ?? model.refName;createPR=true }.buttonStyle(.borderedProminent).tint(DesignTokens.cobalt).disabled(model.ref == nil || setup.activeAccount != repository.key.account)
                .help(setup.activeAccount == repository.key.account ? "Create a pull request from the selected ref" : "Switch the active account to \(repository.accountLogin) to create pull requests")
            Button("GitHub") { ExternalLinkPolicy.open(repository.webURL) }.buttonStyle(.link).help(repository.webURL.absoluteString)
        }.fixedSize(horizontal:true,vertical:false)
    }
}
