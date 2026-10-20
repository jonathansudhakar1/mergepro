import MergeProCore
import SwiftUI

/// Read-only commit inspection. Selection never changes the canonical Files comparison.
struct PRCommitsView:View {
    let pr:PullRequest
    let storage:SetupStorage
    let section:PRDetailSection?
    let sectionError:String?
    let sectionLoading:Bool
    let available:Bool
    let refresh:UUID
    let retrySection:() -> Void
    let sources:PRDiffSourceCache
    @State private var selectedSHA:String?
    @State private var selectedFile:String?
    @State private var detail:PRCommitDetail?
    @State private var loading=false
    @State private var paging=false
    @State private var error:String?
    @State private var pageError=false
    @State private var retry=UUID()
    @State private var pageRequest:UUID?
    @State private var detailRequest=UUID()
    @State private var split=false
    @State private var wrap=false
    @State private var hideWhitespace=false
    @State private var mergeFile:DiffFile?
    @State private var mergeFileSHA:String?
    @State private var mergeFileError:String?
    @State private var mergeFileLoading=false
    @State private var mergeFileRetry=UUID()
    private var commits:[PRDetailEvent] { section?.events.filter { $0.sha != nil } ?? [] }
    private var selectedEvent:PRDetailEvent? { commits.first { $0.sha == selectedSHA } }
    private var visibleDetail:PRCommitDetail? { detail?.sha == selectedSHA ? detail : nil }
    private var selectionIdentity:String { (selectedSHA ?? "")+":"+pr.headRevision.rawValue+":"+refresh.uuidString+":"+retry.uuidString+":"+String(available) }
    private var mergeFileIdentity:String { (visibleDetail?.sha ?? "")+":"+(selectedFile ?? "")+":"+mergeFileRetry.uuidString+":"+String(available) }

    var body:some View {
        HSplitView {
            VStack(alignment:.leading,spacing:0) {
                columnHeader("Commits") { if sectionLoading { ProgressView().controlSize(.small) } }
                Divider()
                if let sectionError { Text(sectionError).font(.caption).foregroundStyle(.orange).padding(.horizontal,12);Button("Retry commits",action:retrySection).padding(12) }
                List(selection:$selectedSHA) {
                    ForEach(commits) { event in
                        if let sha=event.sha { commitRow(event,sha:sha).tag(sha) }
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden).accessibilityLabel("Pull request commits")
                if section?.complete == false { Text("Partial commit list. Open GitHub for remaining commits.").font(.caption).foregroundStyle(.secondary).padding(12) }
                if commits.isEmpty && !sectionLoading && sectionError == nil { Text("No commits returned.").foregroundStyle(.secondary).padding(12) }
            }.frame(minWidth:160,idealWidth:220,maxWidth:300,maxHeight:.infinity,alignment:.topLeading)
            inspector.frame(minWidth:640,maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        }
        .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        .task(id:commits.map(\.id)) {
            guard available,section != nil else { return }
            if !commits.contains(where:{ $0.sha == selectedSHA }) { selectedSHA=commits.first?.sha }
        }
        .task(id:selectionIdentity) { await loadCommit() }
        .task(id:mergeFileIdentity) { await loadMergeFile() }
        .task(id:pageRequest) { if pageRequest != nil { await loadMore() } }
        .onChange(of:available) { if !available { detail=nil;selectedSHA=nil;selectedFile=nil;error=nil;detailRequest=UUID() } }
    }
    private func commitRow(_ event:PRDetailEvent,sha:String) -> some View {
        VStack(alignment:.leading,spacing:5) {
            Text(event.body.components(separatedBy:"\n").first ?? event.title).font(.callout.weight(.semibold)).lineLimit(2)
            Text("\(sha.prefix(8)) · \(event.commitContext?.authorLogin ?? event.commitContext?.authorName ?? "Unknown author")").font(.caption).foregroundStyle(.secondary)
            Text(PRStatusSummary.checks(event.commitContext?.checksState).text).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,5)
    }
    private func columnHeader<Accessory:View>(_ title:String,@ViewBuilder accessory:() -> Accessory) -> some View {
        HStack(spacing:8) { Text(title).font(.headline);Spacer(minLength:0);accessory() }
            .padding(.horizontal,12).frame(height:38)
    }
    @ViewBuilder private var inspector:some View {
        if selectedSHA == nil {
            ContentUnavailableView("Select a commit",systemImage:"point.topleft.down.to.point.bottomright.curvepath",description:Text("Read its message, metadata and changed files."))
        } else {
            HSplitView {
                if let detail=visibleDetail { changedFiles(detail) }
                else {
                    ContentUnavailableView("Commit changes",systemImage:"doc.text.magnifyingglass",description:Text(loading ? "Reading changed files…" : "Commit changes are unavailable. Retry from Commit info."))
                        .frame(maxWidth:.infinity,maxHeight:.infinity)
                }
                commitInfo.frame(minWidth:180,idealWidth:230,maxWidth:300,maxHeight:.infinity,alignment:.topLeading)
            }
        }
    }
    private var commitInfo:some View {
        VStack(alignment:.leading,spacing:0) {
            columnHeader("Commit info") { EmptyView() }
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    Text(visibleDetail?.message ?? selectedEvent?.body ?? "Reading commit…")
                        .font(.callout.weight(.medium)).textSelection(.enabled)
                    metadataField("Commit",value:selectedSHA ?? "",monospaced:true)
                    metadataField("Author",value:visibleDetail?.authorLogin ?? visibleDetail?.authorName ?? selectedEvent?.commitContext?.authorLogin ?? selectedEvent?.commitContext?.authorName ?? "Unknown")
                    if let date=visibleDetail?.authoredAt { metadataField("Authored",value:date.formatted(date:.abbreviated,time:.shortened)) }
                    if let name=visibleDetail?.committerName { metadataField("Committer",value:name) }
                    if let date=visibleDetail?.committedAt { metadataField("Committed",value:date.formatted(date:.abbreviated,time:.shortened)) }
                    metadataField("Checks",value:PRStatusSummary.checks(selectedEvent?.commitContext?.checksState).text)
                    if let detail=visibleDetail {
                        if detail.parents.isEmpty { Text("Root commit · compared with the empty tree").font(.caption).foregroundStyle(.secondary) }
                        else {
                            metadataField(detail.parents.count > 1 ? "Parents · first-parent comparison" : "Compared with parent",value:detail.parents.joined(separator:"\n"),monospaced:true)
                        }
                        if let url=detail.webURL { Button("Open commit on GitHub") { ExternalLinkPolicy.open(url) }.buttonStyle(.link).font(.caption) }
                    }
                    Divider()
                    VStack(alignment:.leading,spacing:10) {
                        Text("Diff display").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Toggle("Split",isOn:$split)
                        Toggle("Wrap",isOn:$wrap)
                        Toggle("Hide whitespace",isOn:$hideWhitespace)
                    }.toggleStyle(.checkbox).controlSize(.small)
                    if loading { ProgressView("Reading commit details…").controlSize(.small) }
                    if let error {
                        VStack(alignment:.leading,spacing:8) {
                            Text(error).font(.caption).foregroundStyle(.orange)
                            Button("Retry") { if pageError { pageRequest=UUID() } else { retry=UUID() } }.controlSize(.small)
                        }
                    }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(12)
            }
        }
    }
    private func metadataField(_ label:String,value:String,monospaced:Bool=false) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(monospaced ? .system(.caption,design:.monospaced) : .caption)
                .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func changedFiles(_ detail:PRCommitDetail) -> some View {
        HSplitView {
            VStack(alignment:.leading,spacing:0) {
                columnHeader("Files") {
                    Text("\(detail.files.count)\(detail.complete ? "" : "+")").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                List(selection:$selectedFile) {
                    ForEach(detail.files.sorted { $0.path < $1.path }) { file in
                        VStack(alignment:.leading,spacing:4) {
                            Text(file.path).font(.caption.monospaced()).lineLimit(2)
                            Text("\(PRDetailText.status(file.status)) · +\(file.additions) −\(file.deletions)").font(.caption2).foregroundStyle(.secondary)
                                .accessibilityLabel("\(PRDetailText.status(file.status)), \(PRDetailText.changes(file))")
                        }.tag(file.path)
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden).accessibilityLabel("Commit changed files")
                if detail.nextPage != nil { Button(paging ? "Loading files…" : "Load more files") { pageRequest=UUID() }.disabled(paging).padding(10) }
                if !detail.complete && detail.nextPage == nil { Text("Provider file limit reached. Open this commit on GitHub for the remaining files.").font(.caption).foregroundStyle(.secondary).padding(10) }
            }.frame(minWidth:150,idealWidth:210,maxWidth:300,maxHeight:.infinity,alignment:.topLeading)
            if let file=detail.files.first(where:{ $0.path == selectedFile }) {
                if detail.parents.count <= 1 { commitDiff(detail,file:file) }
                else if mergeFileSHA == detail.sha,let mergeFile,mergeFile.path == file.path {
                    if mergeFile.status == .unchanged { ContentUnavailableView("Unchanged from first parent",systemImage:"equal",description:Text("This file has identical content in the commit and its first parent.")).frame(maxWidth:.infinity,maxHeight:.infinity) }
                    else { commitDiff(detail,file:mergeFile) }
                } else {
                    VStack(alignment:.leading,spacing:10) {
                        if mergeFileLoading { ProgressView("Comparing exact first-parent snapshots…") }
                        if let mergeFileError { Text(mergeFileError).font(.callout).foregroundStyle(.orange);Button("Retry file diff") { mergeFileRetry=UUID() } }
                        Spacer()
                    }.padding(16).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                }
            } else {
                ContentUnavailableView("No changed file selected",systemImage:"doc.text.magnifyingglass",description:Text("Select a file to inspect this commit’s changes."))
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }.frame(minWidth:450,maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
    }
    private func commitDiff(_ detail:PRCommitDetail,file:DiffFile) -> some View {
        RichDiffView(pr:pr,file:file,document:detail.document.replacing(file),storage:storage,split:split,wrap:wrap,hideWhitespace:hideWhitespace,sources:sources)
            .id(detail.sha+":"+file.path).frame(minWidth:240,maxWidth:.infinity,maxHeight:.infinity)
    }
    private func loadCommit() async {
        guard available,let sha=selectedSHA else { loading=false;return }
        let request=UUID();detailRequest=request;loading=true;error=nil;pageError=false;paging=false;pageRequest=nil
        if detail?.sha != sha { detail=nil;selectedFile=nil }
        defer { if detailRequest == request { loading=false } }
        do {
            let value=try await storage.commitDetail(pr,sha:sha)
            try Task.checkCancellation()
            guard available,detailRequest == request,selectedSHA == sha else { return }
            detail=value
            if !value.files.contains(where:{ $0.path == selectedFile }) { selectedFile=value.files.sorted { $0.path < $1.path }.first?.path }
        } catch {
            guard !Task.isCancelled,available,detailRequest == request,selectedSHA == sha else { return }
            self.error=commitErrorMessage(error)
        }
    }
    private func loadMore() async {
        guard available,!paging,!loading,let snapshot=visibleDetail,snapshot.nextPage != nil else { return }
        let request=detailRequest;paging=true;error=nil
        defer { if detailRequest == request { paging=false } }
        do {
            let value=try await storage.moreCommitDetail(pr,snapshot:snapshot)
            try Task.checkCancellation()
            guard available,detailRequest == request,selectedSHA == snapshot.sha,detail?.nextPage == snapshot.nextPage else { return }
            detail=value
        } catch {
            guard !Task.isCancelled,available,detailRequest == request,selectedSHA == snapshot.sha else { return }
            self.error=commitErrorMessage(error)
            pageError=true
        }
    }
    /// REST documents commit diffs but does not specify merge-parent patch semantics. Compute this
    /// file from immutable first-parent sources while leaving metadata and the inventory readable.
    private func loadMergeFile() async {
        mergeFile=nil;mergeFileSHA=nil;mergeFileError=nil;mergeFileLoading=false
        guard available,let detail=visibleDetail,detail.parents.count > 1,let file=detail.files.first(where:{ $0.path == selectedFile }) else { return }
        mergeFileLoading=true
        defer { if !Task.isCancelled { mergeFileLoading=false } }
        do {
            let value=try await storage.snapshotFile(pr,document:detail.document,file:file)
            try Task.checkCancellation()
            guard available,selectedSHA == detail.sha,selectedFile == file.path else { return }
            mergeFile=value;mergeFileSHA=detail.sha
        } catch {
            guard !Task.isCancelled,available,selectedSHA == detail.sha,selectedFile == file.path else { return }
            mergeFileError=commitErrorMessage(error)+" Exact first-parent diff unavailable; open the commit on GitHub."
        }
    }
    private func commitErrorMessage(_ error:any Error) -> String {
        if let failure=error as? PRDetailFailure {
            switch failure {
            case .revisionChanged:return "The PR revision changed. Refresh the PR workspace before inspecting commits."
            case .oversized:return "This commit exceeds the supported diff or source size. Open it on GitHub."
            case .unavailable:return "The commit or its exact source snapshots are unavailable. Retry or open it on GitHub."
            case .invalidPath:return "This commit or file path is invalid. Refresh the PR workspace."
            }
        }
        return providerErrorMessage(error)
    }
}
