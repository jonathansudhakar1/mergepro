import AppKit
import SwiftUI
import MergeProCore

struct RepoReleasesView:View {
    let repository:RepoCatalogEntry
    let service:RepositoryBrowserService
    var selectRef:(String) -> Void
    @State private var releases:[RepositoryRelease]=[]
    @State private var tags:[RepositoryTag]=[]
    @State private var releasePage:Int?=1
    @State private var tagPage:Int?=1
    @State private var selected:RepositoryRelease?
    @State private var error:String?
    @State private var status:String?
    @State private var downloading:Set<Int>=[]
    @State private var generation=UUID()
    @State private var loadingReleases=false
    @State private var loadingTags=false
    var body:some View {
        VStack(spacing:0) {
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Label("Tags & Releases",systemImage:"tag").font(.system(.headline,design:.rounded)).foregroundStyle(DesignTokens.violet)
                    Text("Release notes, versioned source and downloadable assets").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength:8)
                if loadingReleases || loadingTags { ProgressView().controlSize(.small) }
            }.padding(16).background(Color(nsColor:.windowBackgroundColor))
            if let error { WorkspaceNotice(message:error,symbol:"exclamationmark.circle",tint:.red).padding(.horizontal,16).padding(.vertical,8) }
            if let status { WorkspaceNotice(message:status,symbol:"checkmark.circle",tint:.green).padding(.horizontal,16).padding(.vertical,8) }
            HSplitView {
                List {
                    Section("Releases") {
                        ForEach(releases) { release in
                            Button { selected=release } label:{
                                VStack(alignment:.leading,spacing:7) {
                                    Text(release.name).font(.headline).lineLimit(2)
                                    Text(release.tag).font(.system(.caption,design:.monospaced)).foregroundStyle(DesignTokens.violet)
                                    if release.draft { WorkspaceStatusBadge(text:"Draft",symbol:"pencil") }
                                    if release.prerelease { WorkspaceStatusBadge(text:"Pre-release",tint:DesignTokens.violet) }
                                    if let date=release.publishedAt { Text(date.formatted(date:.abbreviated,time:.omitted)).font(.caption).foregroundStyle(.secondary) }
                                }.frame(maxWidth:.infinity,alignment:.leading).padding(10).workspacePanel(radius:12)
                            }.buttonStyle(.plain).listRowBackground(selected?.id==release.id ? DesignTokens.violet.opacity(0.10) : Color.clear)
                        }
                        if releases.isEmpty,!loadingReleases { Text("No releases published.").font(.caption).foregroundStyle(.secondary) }
                        if releasePage != nil { Button("Load More Releases") { Task { await loadReleases() } }.disabled(loadingReleases) }
                    }
                    Section("Tags") {
                        ForEach(tags) { tag in HStack { Label(tag.name,systemImage:"tag").foregroundStyle(DesignTokens.violet);Spacer(minLength:4);Button("Browse") { selectRef(tag.sha) } }.font(.caption).padding(.vertical,4) }
                        if tags.isEmpty,!loadingTags { Text("No tags available.").font(.caption).foregroundStyle(.secondary) }
                        if tagPage != nil { Button("Load More Tags") { Task { await loadTags() } }.disabled(loadingTags) }
                    }
                }.frame(minWidth:180,idealWidth:250,maxWidth:360)
                if let release=selected {
                    ScrollView {
                        VStack(alignment:.leading,spacing:16) {
                            Text(release.name).font(.system(.title2,design:.rounded).bold()).textSelection(.enabled)
                            ScrollView(.horizontal) { HStack(spacing:10) { WorkspaceStatusBadge(text:release.tag,symbol:"tag",tint:DesignTokens.violet);Button("Browse Tag") { selectRef(release.tag) };if let url=release.webURL { Button("Open Release") { ExternalLinkPolicy.open(url) }.buttonStyle(.link).help(url.absoluteString) } }.fixedSize(horizontal:true,vertical:false).padding(.vertical,2) }.fixedSize(horizontal:false,vertical:true)
                            MarkdownView(source:release.body,webURL:release.webURL)
                            if !release.assets.isEmpty { Divider();Text("Assets").font(.headline) }
                            ForEach(release.assets) { asset in
                                VStack(alignment:.leading,spacing:10) {
                                    Text(asset.name).font(.callout.weight(.medium)).textSelection(.enabled)
                                    HStack {
                                        Text(ByteCountFormatter.string(fromByteCount:Int64(asset.size),countStyle:.file)).font(.caption).foregroundStyle(.secondary)
                                        Spacer(minLength:4)
                                        if downloading.contains(asset.id) { ProgressView().controlSize(.small) }
                                        Button("Download") { Task { await download(asset) } }.disabled(downloading.contains(asset.id))
                                    }
                                }.padding(12).workspacePanel(radius:12)
                            }
                        }.padding(20)
                    }.frame(minWidth:240)
                } else { ContentUnavailableView("Choose a Release",systemImage:"tag",description:Text("Inspect release notes, browse a tag or download an asset.")).frame(maxWidth:.infinity,maxHeight:.infinity) }
            }
        }.onChange(of:error) { _,message in if let message { AccessibilityNotification.Announcement(message).post() } }
        .task(id:repository.key) { generation=UUID();releases=[];tags=[];selected=nil;releasePage=1;tagPage=1;error=nil;status=nil;downloading=[];loadingReleases=false;loadingTags=false;await loadReleases();await loadTags() }
    }
    private func loadReleases() async {
        guard let page=releasePage,!loadingReleases else { return }
        let captured=generation;loadingReleases=true;defer { if captured==generation { loadingReleases=false } }
        do {
            let value=try await service.releases(repository:repository,page:page);try Task.checkCancellation()
            guard captured==generation,releasePage==page else { return }
            // Publishing between page loads shifts page boundaries; duplicate IDs would corrupt the list.
            let known=Set(releases.map(\.id));releases += value.values.filter { !known.contains($0.id) };releasePage=value.nextPage;if selected==nil { selected=releases.first }
        } catch { if captured==generation,!Task.isCancelled { self.error=providerErrorMessage(error) } }
    }
    private func loadTags() async {
        guard let page=tagPage,!loadingTags else { return }
        let captured=generation;loadingTags=true;defer { if captured==generation { loadingTags=false } }
        do {
            let value=try await service.tags(repository:repository,page:page);try Task.checkCancellation()
            guard captured==generation,tagPage==page else { return };let known=Set(tags.map(\.name));tags += value.values.filter { !known.contains($0.name) };tagPage=value.nextPage
        } catch { if captured==generation,!Task.isCancelled { self.error=providerErrorMessage(error) } }
    }
    /// The save panel shows and lets the reviewer change the exact file name before anything is written; it also
    /// asks before replacing an existing file. The asset downloads into a private folder first, so a failed or
    /// cancelled download never touches the chosen location.
    private func download(_ asset:RepositoryReleaseAsset) async {
        let captured=generation
        let panel=NSSavePanel();panel.nameFieldStringValue=Self.suggestedFileName(asset.name);panel.canCreateDirectories=true;panel.isExtensionHidden=false
        panel.prompt="Download";panel.message="Save the release asset \(asset.name) (\(ByteCountFormatter.string(fromByteCount:Int64(asset.size),countStyle:.file)))."
        guard await panel.begin() == .OK,let destination=panel.url else { return }
        // Cleared first so a repeated failure is announced again.
        error=nil;status=nil
        downloading.insert(asset.id);defer { downloading.remove(asset.id) }
        let files=FileManager.default,staging=files.temporaryDirectory.appendingPathComponent("MergePro-asset-"+UUID().uuidString,isDirectory:true)
        defer {
            // A leftover staging folder only costs temporary space; record it rather than fail the download.
            if files.fileExists(atPath:staging.path) {
                do { try files.removeItem(at:staging) } catch { AppLog.failed(AppLog.repositories,"A release download staging folder could not be removed",error) }
            }
        }
        do {
            try files.createDirectory(at:staging,withIntermediateDirectories:true)
            let downloaded=try await service.download(repository:repository,asset:asset,directory:staging)
            try Task.checkCancellation()
            let scoped=destination.startAccessingSecurityScopedResource();defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            let saved:URL
            if files.fileExists(atPath:destination.path) { saved=try files.replaceItemAt(destination,withItemAt:downloaded) ?? destination }
            else { try files.moveItem(at:downloaded,to:destination);saved=destination }
            guard captured==generation else { return }
            error=nil;status="Downloaded "+saved.lastPathComponent+" to "+saved.deletingLastPathComponent().lastPathComponent
            AccessibilityNotification.Announcement(status ?? "").post()
            NSWorkspace.shared.activateFileViewerSelecting([saved])
        }
        catch { if captured==generation,!Task.isCancelled { status=nil;self.error=providerErrorMessage(error) } }
    }
    /// The name a directory download would use (see `RepositoryAssetDownload.safeFileName`).
    static func suggestedFileName(_ name:String) -> String {
        let clean=RepositoryAssetDownload.safeFileName(name);return clean.isEmpty ? "release-asset" : clean
    }
}
