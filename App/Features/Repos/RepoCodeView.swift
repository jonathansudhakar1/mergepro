import AppKit
import SwiftUI
import MergeProCore
import MergeProRendering

struct RepoCodeView:View {
    let repository:RepoCatalogEntry
    let ref:ResolvedRepositoryRef?
    let service:RepositoryBrowserService
    var initialPath:String? = nil
    var initialLine:Int? = nil
    @State private var store:RefTreeStore?
    @State private var tree=RefTreeSnapshot()
    @State private var expanded:Set<String>=[]
    @State private var data:Data?
    @State private var document:CodeDocument?
    @State private var blobKind:RepositoryBlob.Kind?
    @State private var wrap=false
    @State private var codeSearch=""
    @State private var findSnapshot:RepoCodeFindSnapshot?
    @State private var matchIndex:Int?
    @State private var navigationNotice:String?
    @State private var scrollToken=0
    @State private var selectedLine:Int?
    @FocusState private var findFocused:Bool
    @State private var error:String?
    @State private var fileSearch=""
    @State private var revealPath=""
    @State private var markdown=true
    @State private var jumpLine=""
    @State private var scrollTo:NSRange?
    @State private var loadingBlob=false
    @State private var blobGeneration=UUID()
    @State private var scrollAnchor:String?
    @State private var saveTask:Task<Void,Never>?
    /// A routed path that arrived with a new ref waits for that ref's tree instead of being revealed in the previous one.
    @State private var pendingPath:String?
    @State private var shownPath:String?
    private var entry:GitTreeEntry? { tree.entries.first { $0.path==tree.selection } }
    private var searchFields:some View {
        Group {
            TextField("Find loaded files",text:$fileSearch).textFieldStyle(.roundedBorder).frame(width:180)
            TextField("Reveal path",text:$revealPath).textFieldStyle(.roundedBorder).frame(width:170).onSubmit { Task { await reveal(revealPath) } }
            Button("Reveal") { Task { await reveal(revealPath) } }.disabled(revealPath.isEmpty)
        }
    }
    @ViewBuilder private var fileActions:some View {
        if let entry,let ref {
            Button("Copy Permalink") { copy(RepositoryBrowserService.permalink(repository:repository,ref:ref,path:entry.path,line:selectedLine).absoluteString) }.accessibilityIdentifier("repoCopyPermalink")
            Button("Open File on Web") { ExternalLinkPolicy.open(RepositoryBrowserService.permalink(repository:repository,ref:ref,path:entry.path,line:selectedLine)) }.buttonStyle(.link)
            Button("Blame") { ExternalLinkPolicy.open(RepositoryBrowserService.permalink(repository:repository,ref:ref,path:entry.path,blame:true)) }.buttonStyle(.link).help("Open blame for this file on GitHub")
        }
    }
    var body:some View {
        VStack(spacing:0) {
            // One row when it fits, otherwise the file actions wrap below the search fields.
            ViewThatFits(in:.horizontal) {
                HStack(spacing:10) { searchFields;fileActions;Spacer(minLength:0) }
                VStack(alignment:.leading,spacing:8) {
                    HStack(spacing:10) { searchFields;Spacer(minLength:0) }
                    HStack(spacing:10) { fileActions;Spacer(minLength:0) }
                }
            }.padding(12).background(Color(nsColor:.windowBackgroundColor))
            if let missing=tree.missingPath { WorkspaceNotice(message:"\(missing) does not exist at this ref. Selected its nearest available parent.",symbol:"exclamationmark.triangle",tint:.orange).padding(10) }
            if let error { HStack(alignment:.top) { WorkspaceNotice(message:error,symbol:"exclamationmark.circle",tint:.red);Button("Retry") { Task { await retry(tree.selection ?? "") } }.padding(.top,12) }.padding(10) }
            Divider()
            HSplitView {
                VStack(spacing:0) {
                    OutlineView(accessibilityID:"repoFileTree",roots:nodes(""),selection:tree.selection,expanded:effectiveExpansion,scrollAnchor:scrollAnchor,selected:{ path in Task { await select(path) } },expansion:{ path,open in
                        if open { expanded.insert(path);Task { await expand(path) } } else { expanded.remove(path) };persist()
                    },scrolled:{ anchor in scrollAnchor=anchor;persist() },contextActions:{ path in
                        var actions=[OutlineContextAction(title:"Copy Path",perform:{ copy(path) })]
                        if let ref { actions += [OutlineContextAction(title:"Copy Permalink",perform:{ copy(RepositoryBrowserService.permalink(repository:repository,ref:ref,path:path).absoluteString) }),OutlineContextAction(title:"Open on GitHub",perform:{ ExternalLinkPolicy.open(RepositoryBrowserService.permalink(repository:repository,ref:ref,path:path)) })] }
                        actions.append(OutlineContextAction(title:"Retry Loading",perform:{ Task { await retry(path) } }));return actions
                    })
                    if tree.loading[""] == .incomplete { incomplete("") }
                }.frame(minWidth:160,idealWidth:200,maxWidth:260)
                viewer.frame(minWidth:240,maxWidth:.infinity,maxHeight:.infinity)
            }
        }
        .task(id:ref?.commitSHA) { await load() }
        .task(id:findIdentity) { await findInFile() }
        // A newer route or leaving the browser cancels a reveal still loading the tree.
        .onChangeTask(of:[initialPath ?? "",initialLine.map(String.init) ?? ""]) { _ in await applyRoute() }
        .onChange(of:error) { _,message in if let message { AccessibilityNotification.Announcement(message).post() } }
        .onChange(of:navigationNotice) { _,message in if let message { AccessibilityNotification.Announcement(message).post() } }
    }
    /// Routes apply to the tree of the ref they name; a line target only moves within the file it belongs to.
    private func applyRoute() async {
        guard let path=initialPath else { return }
        guard let ref,tree.ref?.commitSHA==ref.commitSHA else { pendingPath=path;return }
        if tree.selection==path,let line=initialLine,document != nil { jumpLine=String(line);jump() } else { await reveal(path) }
    }
    private var effectiveExpansion:Set<String> {
        guard !fileSearch.isEmpty else { return expanded }
        var result=expanded
        for item in tree.entries where item.path.localizedCaseInsensitiveContains(fileSearch) {
            var path=(item.path as NSString).deletingLastPathComponent
            while !path.isEmpty { result.insert(path);path=(path as NSString).deletingLastPathComponent }
        }
        return result
    }
    private func nodes(_ parent:String) -> [NativeOutlineNode] {
        (tree.children[parent] ?? []).compactMap { entry in
            let children=entry.kind == .directory ? nodes(entry.path) : []
            if !fileSearch.isEmpty,!entry.path.localizedCaseInsensitiveContains(fileSearch),children.isEmpty { return nil }
            var subtitle=""
            if case .failed = tree.loading[entry.path] { subtitle="Retry required" }
            if tree.loading[entry.path] == .loading { subtitle="Loading…" }
            if tree.loading[entry.path] == .incomplete { subtitle="Incomplete · Retry" }
            if entry.kind == .symlink { subtitle="Symlink" };if entry.kind == .submodule { subtitle="Submodule" }
            return NativeOutlineNode(id:entry.path,title:(entry.path as NSString).lastPathComponent,subtitle:subtitle,symbol:entry.kind == .directory ? "folder" : entry.kind == .symlink ? "link" : entry.kind == .submodule ? "shippingbox" : "doc.text",children:children,expandable:entry.kind == .directory)
        }
    }
    @ViewBuilder private var viewer:some View {
        if ref == nil { ProgressView("Resolving immutable ref…") }
        else if loadingBlob { ProgressView("Loading file…") }
        else if let entry {
            VStack(spacing:0) {
                HStack(spacing:8) { Image(systemName:entry.kind == .directory ? "folder" : "doc.text").foregroundStyle(DesignTokens.cobalt).accessibilityHidden(true);Text(entry.path).font(.system(.caption,design:.monospaced)).textSelection(.enabled).accessibilityIdentifier("repoFilePath");Spacer(minLength:4);if let size=entry.size { Text(ByteCountFormatter.string(fromByteCount:Int64(size),countStyle:.file)).font(.caption).foregroundStyle(.secondary).fixedSize() } }.padding(12).background(Color(nsColor:.windowBackgroundColor))
                Divider()
                if entry.kind == .directory {
                    VStack { Label("Directory",systemImage:"folder");Text("Expand the directory to browse its files.").foregroundStyle(.secondary);if tree.loading[entry.path] == .incomplete { incomplete(entry.path) };Button("Load / Retry") { Task { await expand(entry.path) } } }.frame(maxWidth:.infinity,maxHeight:.infinity)
                } else if entry.kind == .submodule {
                    ContentUnavailableView("Git Submodule",systemImage:"shippingbox",description:Text("This entry points to commit \(entry.sha). Inspect the repository’s .gitmodules file for its remote location."))
                } else if let data {
                    file(data,entry:entry)
                } else { ContentUnavailableView("File Unavailable",systemImage:"doc",description:Text("Select a file or retry loading.")) }
            }
        } else { ContentUnavailableView("Select a File",systemImage:"doc.text",description:Text("Directories load as you expand them. README opens automatically when available.")) }
    }
    @ViewBuilder private func file(_ data:Data,entry:GitTreeEntry) -> some View {
        let kind=blobKind ?? RepositoryBlob.classify(data)
        if kind == .binary {
            VStack(spacing:12) { Label("Binary file",systemImage:"doc.richtext");Text("\(data.count) bytes · \(entry.sha)").font(.caption).textSelection(.enabled);if let ref { Button("Open on GitHub") { ExternalLinkPolicy.open(RepositoryBrowserService.permalink(repository:repository,ref:ref,path:entry.path)) }.buttonStyle(.link) } }.frame(maxWidth:.infinity,maxHeight:.infinity)
        } else if kind == .lfsPointer {
            VStack(alignment:.leading,spacing:12) { Label("Git LFS Pointer",systemImage:"externaldrive");Text("The object is stored in Git LFS. This preview shows its pointer.").font(.caption);CodeTextView(text:document?.source ?? String(decoding:data,as:UTF8.self),wrap:true,path:entry.path,gutterMarks:document?.lineNumberMarks ?? []);if let ref { Button("Open LFS file on GitHub") { ExternalLinkPolicy.open(RepositoryBrowserService.permalink(repository:repository,ref:ref,path:entry.path)) }.buttonStyle(.link) } }.padding()
        } else {
            let text=document?.source ?? String(decoding:data,as:UTF8.self)
            VStack(spacing:0) {
                sourceToolbar(text,entry:entry)
                if let navigationNotice {
                    Label(navigationNotice,systemImage:"exclamationmark.triangle").font(.caption).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,12).padding(.vertical,6)
                }
                if markdown,entry.path.lowercased().hasSuffix(".md") { ScrollView { MarkdownView(source:text,webURL:ref.map { RepositoryBrowserService.permalink(repository:repository,ref:$0,path:entry.path) }).padding(16) } }
                else { CodeTextView(text:text,wrap:wrap,path:entry.path,gutterMarks:document?.lineNumberMarks ?? [],scrollTo:scrollTo,scrollToken:scrollToken,selectedRange:{ range in selectedLine=document?.lineNumber(at:range.location) }).accessibilityIdentifier("repoCodeViewer") }
            }
        }
    }
    private func incomplete(_ path:String) -> some View {
        HStack { Label { Text("Incomplete tree response").foregroundStyle(.secondary) } icon:{ Image(systemName:"exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true) }.font(.caption);Button("Retry") { Task { await retry(path) } } }.padding(8)
    }
    private func load() async {
        blobGeneration=UUID();loadingBlob=false
        guard let ref else { data=nil;document=nil;blobKind=nil;return }
        let saved=await AppLog.value(AppLog.repositories, "Saved code browser state could not be read", fallback:nil) { try await service.codeState(repository:repository.key) }
        // A superseded load must not switch the shared tree store after its replacement started.
        guard !Task.isCancelled else { return }
        if tree.ref==nil { expanded=saved?.expanded ?? [];scrollAnchor=saved?.scrollAnchor }
        let requested=pendingPath
        let oldPath=requested ?? (tree.ref == nil ? (initialPath ?? saved?.selection) : tree.selection);data=nil;document=nil;blobKind=nil;findSnapshot=nil;matchIndex=nil;selectedLine=nil;scrollTo=nil;navigationNotice=nil;error=nil
        let current=store ?? RefTreeStore(provider:service);store=current
        do {
            try await current.switchRef(repository:repository,ref:ref,preserving:oldPath)
            try Task.checkCancellation();tree=await current.snapshot()
            if let oldPath { expanded.formUnion(ancestors(oldPath)) }
            for path in expanded.sorted(by:{ $0.count<$1.count }) { try? await current.reveal(path);try? await current.expand(path) }
            if let oldPath { try await current.reveal(oldPath) } else { await current.select(nil) }
            // A route for this ref that arrived while its tree was loading still applies here.
            let late=Task.isCancelled ? nil : pendingPath.flatMap { $0==requested ? nil : $0 }
            if let late { try await current.reveal(late);expanded.formUnion(ancestors(late)) }
            tree=await current.snapshot()
            if let applied=late ?? requested,pendingPath==applied { pendingPath=nil }
            if tree.selection == nil,let readme=tree.children[""]?.first(where:{ $0.kind == .file && $0.path.lowercased().hasPrefix("readme") }) { await select(readme.path) }
            else { await select(tree.selection) }
            if repository.pinned {
                do { try await service.indexFiles(repository:repository,ref:ref,maxTrees:12) }
                catch { AppLog.failed(AppLog.repositories, "Pinned repository files could not be indexed", error) }
            }
        } catch { if !Task.isCancelled,!(error is CancellationError) { self.error=providerErrorMessage(error) } }
    }
    private func select(_ path:String?) async {
        guard let store,let ref else { return }
        let captured=UUID();blobGeneration=captured;loadingBlob=false
        await store.select(path)
        guard captured==blobGeneration,!Task.isCancelled else { return }
        let snapshot=await store.snapshot()
        guard captured==blobGeneration,!Task.isCancelled else { return }
        // Line targets belong to one file; a stale line would also leak into the next file's permalink.
        if path != shownPath { jumpLine="";scrollTo=nil;codeSearch="" };shownPath=path
        tree=snapshot;data=nil;document=nil;blobKind=nil;findSnapshot=nil;matchIndex=nil;selectedLine=nil;scrollTo=nil;navigationNotice=nil;error=nil;persist()
        guard let entry=tree.entries.first(where:{ $0.path==path }),entry.kind == .file || entry.kind == .symlink else { return }
        loadingBlob=true;defer { if captured==blobGeneration { loadingBlob=false } }
        do {
            let value=try await service.blob(repository:repository,ref:ref,entry:entry)
            guard !Task.isCancelled,captured==blobGeneration,self.ref?.commitSHA==ref.commitSHA,tree.selection==path else { return }
            let previewTask=Task.detached(priority:.userInitiated) {
                let kind=RepositoryBlob.classify(value)
                return (kind,kind == .binary ? nil : CodeDocument(String(decoding:value,as:UTF8.self)))
            }
            let preview=await withTaskCancellationHandler(operation:{ await previewTask.value },onCancel:{ previewTask.cancel() })
            guard !Task.isCancelled,captured==blobGeneration,self.ref?.commitSHA==ref.commitSHA,tree.selection==path else { return }
            blobKind=preview.0;document=preview.1;data=value
            if let initialLine,path==initialPath { jumpLine=String(initialLine);jump() }
        } catch { if !Task.isCancelled,captured==blobGeneration,self.ref?.commitSHA==ref.commitSHA,tree.selection==path { self.error=providerErrorMessage(error) } }
    }
    /// Tree generation changes surface as CancellationError; they mean superseded work, not a failure to report.
    private func show(_ error:any Error) { if !(error is CancellationError) { self.error=providerErrorMessage(error) } }
    private func expand(_ path:String) async { guard let store else { return };do { try await store.expand(path);tree=await store.snapshot() } catch { show(error);tree=await store.snapshot() } }
    private func retry(_ path:String) async {
        guard let store else { return }
        // Files retry their blob; only directories and the root have tree children to refetch.
        if let entry=tree.entries.first(where:{ $0.path==path }),entry.kind != .directory { await select(path);return }
        do { try await store.retry(path);tree=await store.snapshot();if path==tree.selection { await select(path) } } catch { show(error);tree=await store.snapshot() }
    }
    private func reveal(_ path:String) async { guard let store,!path.isEmpty else { return };do { try await store.reveal(path);tree=await store.snapshot();expanded.formUnion(ancestors(path));await select(tree.selection) } catch { if !Task.isCancelled { show(error) } } }
    private func persist() {
        guard let ref else { return };let state=RepoCodePersistence(refName:ref.name,selection:tree.selection,expanded:expanded,scrollAnchor:scrollAnchor)
        saveTask?.cancel();saveTask=Task {
            do { try await Task.sleep(for:.milliseconds(180));try await service.saveCodeState(state,repository:repository.key) }
            catch { AppLog.failed(AppLog.repositories, "Code browser state could not be saved", error) }
        }
    }
    private func ancestors(_ path:String) -> Set<String> { var result=Set<String>(),parent=(path as NSString).deletingLastPathComponent;while !parent.isEmpty { result.insert(parent);parent=(parent as NSString).deletingLastPathComponent };return result }
    private func copy(_ value:String) { NSPasteboard.general.clearContents();NSPasteboard.general.setString(value,forType:.string) }
    private func jump() {
        guard let target=Int(jumpLine),let range=document?.range(forLine:target) else {
            navigationNotice="Enter a line from 1 to \(document?.lineRanges.count ?? 1).";return
        }
        navigationNotice=nil;selectedLine=target;scrollTo=range;scrollToken &+= 1;markdown=false
    }
    private var findIdentity:RepoCodeFindIdentity { .init(source:document?.source ?? "",path:tree.selection ?? "",query:codeSearch) }
    private var found:CodeSearchResult? { findSnapshot?.identity == findIdentity ? findSnapshot?.result : nil }
    private var findCount:String {
        guard !codeSearch.isEmpty else { return "" }
        guard let found else { return "Searching…" }
        let count=found.ranges.count
        return count == 0 ? "No matches" : "\(matchIndex.map { $0+1 } ?? 0) of \(count)\(found.truncated ? "+" : "")"
    }
    private func findInFile() async {
        let identity=findIdentity
        guard let document,!identity.query.isEmpty else { findSnapshot=nil;matchIndex=nil;return }
        do { try await Task.sleep(for:.milliseconds(120)) } catch { return }
        let search=Task.detached(priority:.userInitiated) { document.find(identity.query) }
        let result=await withTaskCancellationHandler(operation:{ await search.value },onCancel:{ search.cancel() })
        guard !Task.isCancelled,identity == findIdentity else { return }
        findSnapshot=RepoCodeFindSnapshot(identity:identity,result:result);matchIndex=nil
        moveMatch(backwards:false)
        // The count beside the field changes silently; VoiceOver hears the finished search once.
        AccessibilityNotification.Announcement(result.ranges.isEmpty ? "No matches" : "\(result.ranges.count)\(result.truncated ? " or more" : "") matches").post()
    }
    private func moveMatch(backwards:Bool) {
        guard let result=found,let index=result.nextIndex(after:matchIndex,backwards:backwards) else { return }
        matchIndex=index;selectedLine=document?.lineNumber(at:result.ranges[index].location);scrollTo=result.ranges[index];scrollToken &+= 1;markdown=false;navigationNotice=nil
    }
    private func sourceToolbar(_ text:String,entry:GitTreeEntry) -> some View {
        ViewThatFits(in:.horizontal) {
            HStack(spacing:10) {
                sourceActions(text,entry:entry);Divider().frame(height:18);findControls;Divider().frame(height:18);lineControls
            }.fixedSize(horizontal:true,vertical:false)
            VStack(alignment:.leading,spacing:8) {
                HStack(spacing:10) { sourceActions(text,entry:entry);Divider().frame(height:18);lineControls }
                findControls
            }.fixedSize(horizontal:true,vertical:false)
            VStack(alignment:.leading,spacing:8) {
                sourceActions(text,entry:entry)
                findControls
                lineControls
            }.fixedSize(horizontal:true,vertical:false)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(10).background(Color(nsColor:.windowBackgroundColor))
    }
    private func sourceActions(_ text:String,entry:GitTreeEntry) -> some View {
        HStack(spacing:10) {
            if entry.kind == .symlink { Label("Symlink target",systemImage:"link").font(.caption) }
            if entry.path.lowercased().hasSuffix(".md") { Toggle("Rendered Markdown",isOn:$markdown).toggleStyle(.checkbox) }
            Toggle("Wrap",isOn:$wrap).toggleStyle(.checkbox).accessibilityIdentifier("repoCodeWrap").help("Wrap long source lines without changing file contents")
            Button("Copy File") { copy(text) }.accessibilityIdentifier("repoCopyFile")
        }
    }
    private var findControls:some View {
        HStack(spacing:8) {
            Button { findFocused=true } label:{ Image(systemName:"magnifyingglass") }
                .keyboardShortcut("f",modifiers:.command).help("Find in file (⌘F)").accessibilityLabel("Find in file")
            TextField("Find in file",text:$codeSearch).textFieldStyle(.roundedBorder).frame(width:140).focused($findFocused)
                .accessibilityIdentifier("repoCodeFind").onSubmit { moveMatch(backwards:false) }
            Text(findCount).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("repoCodeFindCount")
            Button { moveMatch(backwards:true) } label:{ Image(systemName:"chevron.up") }
                .keyboardShortcut("g",modifiers:[.command,.shift]).help("Previous match (⇧⌘G)").accessibilityLabel("Previous match").disabled(found?.ranges.isEmpty != false)
            Button { moveMatch(backwards:false) } label:{ Image(systemName:"chevron.down") }
                .keyboardShortcut("g",modifiers:.command).help("Next match (⌘G)").accessibilityLabel("Next match").disabled(found?.ranges.isEmpty != false)
        }
    }
    private var lineControls:some View {
        HStack(spacing:8) {
            TextField("Line",text:$jumpLine).textFieldStyle(.roundedBorder).frame(width:65).onSubmit { jump() }.accessibilityLabel("Jump to line").accessibilityIdentifier("repoCodeLine")
            Button("Jump") { jump() }.accessibilityIdentifier("repoCodeJump")
            if let count=document?.lineRanges.count { Text("\(count) lines").font(.caption).foregroundStyle(.secondary) }
        }
    }

}

private struct RepoCodeFindIdentity:Hashable,Sendable { let source:String;let path:String;let query:String }
private struct RepoCodeFindSnapshot { let identity:RepoCodeFindIdentity;let result:CodeSearchResult }
