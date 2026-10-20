import SwiftUI
import MergeProCore

struct RepoHistoryView:View {
    let repository:RepoCatalogEntry
    let ref:ResolvedRepositoryRef?
    let service:RepositoryBrowserService
    var openPR:(ProviderKey) -> Void
    @State private var commits:[RepositoryCommit]=[]
    @State private var nextPage:Int?=1
    @State private var selected:RepositoryCommit?
    @State private var files:[RepositoryChangedFile]=[]
    @State private var linked:[CreatedRepositoryPR]=[]
    @State private var checks:[String:String]=[:]
    @State private var path=""
    @State private var author=""
    @State private var base=""
    @State private var head=""
    @State private var comparison:RepositoryComparison?
    @State private var comparePage=1
    /// Later comparison pages extend the refs that were compared, not whatever the fields contain now.
    @State private var compareBase=""
    @State private var compareHead=""
    @State private var compareHasMore=false
    @State private var error:String?
    @State private var historyStore:RepositoryHistoryStore?
    @State private var queryGeneration=UUID()
    @State private var compareGeneration=UUID()
    @State private var detailGeneration=UUID()
    @State private var compareLoading=false
    @State private var loadingCommits=false
    @State private var loadingDetail=false
    /// Each request owns its own flag, so one finishing cannot hide or block another.
    private var busy:Bool { loadingCommits || loadingDetail || compareLoading }
    var body:some View {
        VStack(spacing:0) {
            ScrollView(.horizontal) {
                VStack(alignment:.leading,spacing:10) {
                    HStack(spacing:10) {
                        TextField("Filter by path",text:$path).textFieldStyle(.roundedBorder).frame(width:170).onSubmit { Task { await reset() } }
                        TextField("Filter by author",text:$author).textFieldStyle(.roundedBorder).frame(width:170).onSubmit { Task { await reset() } }
                        Button("Apply") { Task { await reset() } }
                    }
                    HStack(spacing:10) {
                        TextField("Compare base ref / SHA",text:$base).textFieldStyle(.roundedBorder).frame(width:170)
                        TextField("Head ref / SHA",text:$head).textFieldStyle(.roundedBorder).frame(width:170)
                        Button("Compare") { startCompare() }.disabled(trimmed(base).isEmpty || trimmed(head).isEmpty || compareLoading)
                        if comparison != nil { Button("History") { compareGeneration=UUID();compareLoading=false;comparison=nil;compareHasMore=false;selected=nil;files=[];linked=[];detailGeneration=UUID();loadingDetail=false } }
                    }
                }.fixedSize(horizontal:true,vertical:false).padding(12)
            }.fixedSize(horizontal:false,vertical:true).background(Color(nsColor:.windowBackgroundColor))
            if let error { WorkspaceNotice(message:error,symbol:"exclamationmark.circle",tint:.red).padding(10) }
            if busy { ProgressView().controlSize(.small).padding(6) }
            Divider()
            HSplitView {
                List {
                    if let comparison {
                        Button { selected=nil;linked=[];detailGeneration=UUID();loadingDetail=false;files=comparison.files } label:{ Text(ProviderStateText.comparisonStatus(comparison.status)+" · \(comparison.ahead) ahead · \(comparison.behind) behind").font(.headline).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()) }
                            .buttonStyle(.plain).help("Show the comparison's changed files")
                            .listRowBackground(selected==nil ? DesignTokens.cobalt.opacity(0.10) : Color.clear)
                        ForEach(comparison.commits) { commit in commitRow(commit) }
                        if comparison.incomplete { warning("Comparison is incomplete. GitHub limits file lists; inspect the full comparison on the web.") }
                        if compareHasMore { Button("Load Next Commit Page") { Task { await compare(page:comparePage+1) } }.disabled(compareLoading) }
                        if let url=comparison.webURL { Button("Open Full Comparison") { ExternalLinkPolicy.open(url) }.buttonStyle(.link).help(url.absoluteString) }
                    } else {
                        ForEach(commits) { commit in commitRow(commit) }
                        if nextPage != nil { Button("Load More Commits") { Task { await loadMore() } }.disabled(loadingCommits) }
                        if commits.isEmpty,!loadingCommits { Text("No matching commits.").foregroundStyle(.secondary) }
                    }
                }.frame(minWidth:160,idealWidth:280,maxWidth:400)
                ScrollView {
                    VStack(alignment:.leading,spacing:14) {
                        if let selected {
                            Text(selected.message).font(.headline).textSelection(.enabled)
                            Text(selected.sha).font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            ScrollView(.horizontal) { HStack { if let url=selected.webURL { Button("Open Commit") { ExternalLinkPolicy.open(url) }.buttonStyle(.link).help(url.absoluteString) };ForEach(linked,id:\.key) { pr in Button("Open PR #\(pr.number)") { openPR(pr.key) } } }.fixedSize(horizontal:true,vertical:false).padding(.bottom,2) }.fixedSize(horizontal:false,vertical:true)
                        }
                        ForEach(files) { file in
                            VStack(alignment:.leading,spacing:6) {
                                VStack(alignment:.leading,spacing:6) {
                                    Text(file.path).font(.system(.callout,design:.monospaced)).textSelection(.enabled)
                                    HStack { WorkspaceStatusBadge(text:ProviderStateText.changedFileStatus(file.status),tint:DesignTokens.cobalt);Spacer();Text("+\(file.additions) −\(file.deletions)").foregroundStyle(.secondary).accessibilityLabel("\(file.additions) additions, \(file.deletions) deletions") }.font(.caption)
                                }
                                if let patch=file.patch { CodeTextView(text:patch,wrap:true,path:"change.diff").frame(height:CGFloat(min(600,max(80,patch.components(separatedBy:"\n").count*17)))) }
                                else { Text("Patch unavailable; this may be binary or exceed GitHub’s patch limits.").font(.caption).foregroundStyle(.secondary) }
                            }.padding(12).workspacePanel(radius:12)
                        }
                        if selected==nil,comparison==nil { ContentUnavailableView("Select a Commit",systemImage:"clock.arrow.circlepath",description:Text("Inspect changed files and linked pull requests, or compare two refs.")) }
                        if files.count>=300 { warning("File list may be truncated at GitHub’s limit. Open the full comparison on GitHub.") }
                    }.padding(16)
                }.frame(minWidth:240)
            }
        }.task(id:ref?.commitSHA) { await reset() }
        .onChange(of:error) { _,message in if let message { AccessibilityNotification.Announcement(message).post() } }
    }
    private func commitRow(_ commit:RepositoryCommit) -> some View {
        // Inspecting a commit keeps an open comparison; in history mode it abandons a comparison still loading.
        Button { selected=commit;files=[];linked=[];if comparison==nil { compareGeneration=UUID();compareLoading=false };Task { await detail(commit) } } label:{
            VStack(alignment:.leading,spacing:5) {
                Text(commit.message.components(separatedBy:"\n").first ?? commit.message).font(.headline).lineLimit(2)
                Text(commit.author+" · "+String(commit.sha.prefix(8))).font(.caption).foregroundStyle(.secondary)
                if let date=commit.date { Text(date.formatted(date:.abbreviated,time:.shortened)).font(.caption) }
                if let raw=checks[commit.sha] { PRStatusLabel(value:ProviderStateText.commitChecks(raw)).font(.caption) }
                else { Text("Reading checks…").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,5)
        }.buttonStyle(.plain)
        .listRowBackground(selected?.sha==commit.sha ? DesignTokens.cobalt.opacity(0.10) : Color.clear)
        .task(id:commit.sha) { guard checks[commit.sha]==nil else { return };let value=(try? await service.commitChecks(repository:repository,sha:commit.sha)) ?? "";if !Task.isCancelled { checks[commit.sha]=value } }
    }
    /// Warning text stays readable secondary text; the orange stays on the icon.
    private func warning(_ message:String) -> some View {
        Label { Text(message).foregroundStyle(.secondary) } icon:{ Image(systemName:"exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true) }.font(.caption)
    }
    private func trimmed(_ value:String) -> String { value.trimmingCharacters(in:.whitespacesAndNewlines) }
    private func reset() async {
        queryGeneration=UUID();let captured=queryGeneration
        commits=[];nextPage=1;selected=nil;files=[];linked=[];comparison=nil;compareHasMore=false;checks=[:];compareGeneration=UUID();detailGeneration=UUID();compareLoading=false;loadingDetail=false;loadingCommits=false
        guard let ref else { return };let store=historyStore ?? RepositoryHistoryStore(provider:service);historyStore=store
        let path=trimmed(self.path),author=trimmed(self.author)
        loadingCommits=true;defer { if captured==queryGeneration { loadingCommits=false } }
        do { try await store.reset(repository:repository,ref:ref,path:path.isEmpty ? nil:path,author:author.isEmpty ? nil:author);guard captured==queryGeneration,!Task.isCancelled else { return };let state=await store.snapshot();guard captured==queryGeneration,!Task.isCancelled else { return };commits=state.commits;nextPage=state.nextPage;error=nil }
        catch { if captured==queryGeneration,!Task.isCancelled { self.error=providerErrorMessage(error) } }
    }
    private func loadMore() async {
        guard let store=historyStore,!loadingCommits else { return };let captured=queryGeneration;loadingCommits=true
        defer { if captured==queryGeneration { loadingCommits=false } }
        do { try await store.loadMore();guard captured==queryGeneration,!Task.isCancelled else { return };let state=await store.snapshot();guard captured==queryGeneration,!Task.isCancelled else { return };commits=state.commits;nextPage=state.nextPage;error=nil }
        catch { if captured==queryGeneration,!Task.isCancelled { self.error=providerErrorMessage(error) } }
    }
    private func detail(_ commit:RepositoryCommit) async {
        let captured=queryGeneration;let detailID=UUID();detailGeneration=detailID
        loadingDetail=true;defer { if detailID==detailGeneration { loadingDetail=false } }
        do {
            async let diffs=service.commitDiff(repository:repository,sha:commit.sha)
            async let prs=service.linkedPRs(repository:repository,sha:commit.sha)
            let (loaded,linked)=try await (diffs,prs)
            guard !Task.isCancelled,captured==queryGeneration,detailID==detailGeneration,selected?.sha==commit.sha else { return };files=loaded;self.linked=linked;error=nil
        } catch { if !Task.isCancelled,captured==queryGeneration,detailID==detailGeneration,selected?.sha==commit.sha { self.error=providerErrorMessage(error) } }
    }
    private func startCompare() {
        compareBase=trimmed(base);compareHead=trimmed(head);compareGeneration=UUID();detailGeneration=UUID();loadingDetail=false
        Task { await compare(page:1) }
    }
    /// The page only advances after it loads, so a failed page is retried rather than skipped.
    private func compare(page:Int) async {
        guard !compareLoading else { return };let generation=compareGeneration,base=compareBase,head=compareHead
        compareLoading=true;defer { if generation==compareGeneration { compareLoading=false } }
        do {
            let result=try await service.compare(repository:repository,base:base,head:head,page:page)
            guard !Task.isCancelled,generation==compareGeneration else { return }
            if page==1 { comparison=result;files=result.files;selected=nil;linked=[] }
            else if let previous=comparison { let known=Set(previous.commits.map(\.sha));comparison=RepositoryComparison(status:result.status,ahead:result.ahead,behind:result.behind,commits:previous.commits+result.commits.filter { !known.contains($0.sha) },files:previous.files,webURL:result.webURL,incomplete:result.incomplete) }
            else { return }
            // A page past the end returns no commits even while GitHub still reports the comparison incomplete.
            comparePage=page;compareHasMore=result.incomplete && !result.commits.isEmpty;error=nil
        } catch { if generation==compareGeneration,!Task.isCancelled { self.error="Comparison unavailable: "+providerErrorMessage(error) } }
    }
}
