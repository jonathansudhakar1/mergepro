import AppKit
import MergeProCore
import MergeProRendering
import SwiftUI

struct RichDiffView:View {
    let pr:PullRequest
    let file:DiffFile
    let document:DiffDocument
    let storage:SetupStorage
    let split:Bool
    let wrap:Bool
    let hideWhitespace:Bool
    var requestedLine:Int? = nil
    var requestedSide:DiffSide? = nil
    var annotations:[PRDetailEvent] = []
    var reviewRevision:PRWriteRevision? = nil
    /// Opens the full review composer with a selection or file comment.
    var commentSelected:((ReviewDraftComment) -> Void)?
    /// Window-owned `.gitattributes` and in-flight reads over the shared blob cache; nil reads directly.
    var sources:PRDiffSourceCache? = nil
    /// Bumped by the window for every Jump/search/comment-location request, including repeats of the same line.
    var requestToken=0
    /// The window's writable review threads; nil shows provider comments in the banner only (e.g. commits).
    var threads:PRThreadModel? = nil
    /// A comment was added to the pending review draft from the inline popover (draft comment count).
    var commentAdded:((Int) -> Void)? = nil
    /// A thread reply or resolution was confirmed.
    var threadsChanged:(() -> Void)? = nil
    @State private var attributes=FileAttributeRules.Attributes()
    @State private var presentations:[String:DiffPresentation]=[:]
    @State private var gutterMarks:[String:[CodeGutterMark]]=[:]
    /// Pane tokens are mapped once per prepared presentation, not on every SwiftUI render.
    @State private var paneTokens:[String:[CodeToken]]=[:]
    @State private var splitScroll=CodeScrollSync()
    @State private var visible=DiffLineIndex([])
    @State private var preparationID=UUID()
    /// The published presentation, for code surface instrumentation; always nil without it.
    @State private var presentationIdentity:CodePresentationIdentity?
    @State private var expanded=false
    @State private var context:DiffContext?
    @State private var contextExpansion:[Int:DiffContext.Expansion]=[:]
    @State private var contextHunk=0
    @State private var displayedLines:[DiffLine]=[]
    @State private var mode="Diff"
    @State private var before:Data?
    @State private var after:Data?
    @State private var leftTokens:DiffTokenMapping?
    @State private var rightTokens:DiffTokenMapping?
    @State private var symbols:[CodeSymbol]=[]
    @State private var message:String?
    /// Full-file scroll target (symbols); diff-pane offsets never apply to full-file text.
    @State private var selection:NSRange?
    @State private var selectedSide:DiffSide = .right
    @State private var anchor:ReviewAnchor?
    @State private var editorMessage:String?
    @State private var changeIndex = -1
    @State private var threadIndex = -1
    @State private var jumpLine:Int?
    @State private var jumpSide:DiffSide?
    @State private var jumpToken=0
    @State private var symbolToken=0
    @State private var selectionComment:ReviewDraftComment?
    @State private var fileComment:ReviewDraftComment?
    /// The thread overview beside the diff; threads themselves sit inside the code below their lines.
    @AppStorage(DiffPreferences.threadOverviewVisible) private var overviewVisible=false
    /// Measured inline thread heights by "<pane>:<item>"; a split row reserves the taller side in both panes.
    @State private var inlineHeights:[String:CGFloat]=[:]
    /// Bumped whenever new presentations are published, so thread placement is recomputed once per presentation.
    @State private var presented=0
    @State private var placementCache=InlinePlacementCache()
    /// Review threads for the canonical PR diff; comparisons have no provider threads.
    private var railAvailable:Bool { threads != nil && document.comparison == .pullRequest }
    private var fileThreadCount:Int { threads?.threads(for:file).count ?? 0 }
    private var providerComments:[PRDetailEvent] { mappedComments.filter { $0.providerComment != nil } }
    private var showsRail:Bool { railAvailable && overviewVisible && (fileThreadCount > 0 || !providerComments.isEmpty) }
    /// The banner keeps check annotations; provider comments sit inside the code when threads are available.
    private var bannerEvents:[PRDetailEvent] { railAvailable ? mappedComments.filter { $0.providerComment == nil } : mappedComments }
    var body:some View {
        VStack(spacing:0) {
            toolbar
            Divider()
            if !bannerEvents.isEmpty || message != nil || editorMessage != nil || anchor != nil || hasThreadNotice {
                VStack(alignment:.leading,spacing:6) {
                    threadNotice
                    ForEach(bannerEvents.prefix(3)) { annotation in
                        HStack(alignment:.firstTextBaseline,spacing:8) {
                            Image(systemName:"exclamationmark.bubble.fill").foregroundStyle(.orange)
                            Text("Line \(annotation.renderingAnchor(in:document)?.startLine ?? 0)").font(.caption.monospacedDigit().weight(.semibold))
                            Text(annotation.title).font(.caption.weight(.medium))
                            Text(annotation.body).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        }
                    }
                    if bannerEvents.count > 3 { Text("+\(bannerEvents.count-3) more in this file · marked in the gutter").font(.caption).foregroundStyle(.secondary) }
                    if let message { Label(message,systemImage:"info.circle").font(.caption).foregroundStyle(.secondary) }
                    if let editorMessage { Label(editorMessage,systemImage:"info.circle").font(.caption).foregroundStyle(.secondary) }
                    if let anchor {
                        HStack(spacing:8) {
                            Image(systemName:"text.cursor").foregroundStyle(DesignTokens.cobalt)
                            Text("\(anchor.path):\(anchor.startLine == anchor.endLine ? "\(anchor.startLine)" : "\(anchor.startLine)–\(anchor.endLine)") · \(anchor.side == DiffSide.left.rawValue ? "old" : "new") side").font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Spacer(minLength:4)
                            Button("Comment on selection",systemImage:"plus.bubble") { if let reviewRevision,let comment=try? ReviewDraftComment(body:"",anchor:anchor,document:document,revision:reviewRevision) { selectionComment=comment } }
                                .controlSize(.small).disabled(document.providerCommentLocation(for:anchor) == nil || commentSelected == nil || reviewRevision == nil)
                                .popover(item:$selectionComment,arrowEdge:.bottom) { comment in commentPopover(comment) }
                        }
                    }
                }.padding(.horizontal,12).padding(.vertical,8).frame(maxWidth:.infinity,alignment:.leading)
                .background(Color.secondary.opacity(0.05))
                Divider()
            }
            HStack(spacing:0) {
                diffContent.frame(maxWidth:.infinity,maxHeight:.infinity)
                if showsRail,let threads {
                    Divider()
                    InlineThreadRail(model:threads,file:file,comments:providerComments,document:document,selection:anchor,jump:{ side,line in jumpLine=line;jumpSide=side;jumpToken &+= 1;mode="Diff";expandThreads(side:side,line:line) },changed:{ threadsChanged?() })
                        .frame(width:300).frame(maxHeight:.infinity)
                }
            }
            if file.patchState != .available { Label("\(Self.patchStateText(file.patchState)) · comments on lines unavailable",systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange).padding(8).frame(maxWidth:.infinity,alignment:.leading) }
        }
        .environment(\.codePresentation,presentationIdentity)
        .onAppear { _ = DiffPreferences.retiredRemoved }
        .onChange(of:requestedLine) { jumpLine=nil;jumpSide=nil }
        // A new request (even for the same line) wins over local change/comment navigation and shows the diff.
        .onChange(of:requestToken) { jumpLine=nil;jumpSide=nil;if requestedLine != nil { mode="Diff" } }
        .onChange(of:hideWhitespace) { rebuildPresentations() }
        .onChange(of:annotations) { rebuildPresentations() }
        .task(id:preparationID) { await preparePresentations() }
        .task(id:expanded) { if !file.collapsedByDefault || expanded { await loadSources() } }
        // A file with provider comments reads the window's writable threads once.
        .task(id:railAvailable && mappedComments.contains { $0.providerComment != nil }) { if railAvailable,mappedComments.contains(where:{ $0.providerComment != nil }) { await threads?.loadIfNeeded() } }
    }
    @ViewBuilder private var diffContent:some View {
            if (file.collapsedByDefault || attributes.generated || attributes.vendored) && !expanded {
                ContentUnavailableView { Label("Generated, vendored or lock file",systemImage:"doc.zipper") } description: { Text("Collapsed by default. Search includes its available patch.") } actions: { Button("Show file") { expanded=true } }
            } else if mode == "Rich" {
                if before != nil || after != nil { RichFilePreview(path:file.path,before:before,after:after,webURL:pr.metadata?.webURL.appendingPathComponent("files")) }
                else { unavailable }
            } else if mode == "Full file" {
                if let data=after ?? before,let text=String(data:data,encoding:.utf8) { CodeTextView(text:text,wrap:wrap,path:fullSide == .left ? file.previousPath ?? file.path : file.path,languageOverride:attributes.language,gutterMarks:gutterMarks["full"] ?? [],scrollTo:selection,scrollToken:symbolToken,selectedRange:{ range in selectFull(range,text:text) }) }
                else { unavailable }
            } else if presentations["unified"]?.rows.isEmpty == true { unavailable }
            else if split {
                HSplitView { pane(.left);pane(.right) }
            } else { pane(nil) }
    }
    private func commentPopover(_ comment:ReviewDraftComment) -> some View {
        DiffCommentPopover(pr:pr,storage:storage,comment:comment,openComposer:commentSelected.map { open in { open(comment) } },added:{ count in commentAdded?(count) })
    }
    private var toolbar:some View {
        ViewThatFits(in:.horizontal) {
            toolbarContent
            ScrollView(.horizontal) { toolbarContent }.scrollIndicators(.hidden)
        }
    }
    private var toolbarContent:some View {
            HStack(spacing:10) {
                Picker("View",selection:$mode) { ForEach(["Diff","Full file","Rich"],id:\.self) { Text($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                ControlGroup {
                    Button("Previous change",systemImage:"chevron.up") { jumpChange(-1) }.keyboardShortcut("[",modifiers:.option).help("Previous change (⌥[)")
                    Button("Next change",systemImage:"chevron.down") { jumpChange(1) }.keyboardShortcut("]",modifiers:.option).help("Next change (⌥])")
                }.labelStyle(.iconOnly).fixedSize()
                Button("Next comment",systemImage:"text.bubble") { jumpComment() }.labelStyle(.iconOnly)
                    .keyboardShortcut("]",modifiers:[.option,.shift]).disabled(!mappedComments.contains { $0.providerComment != nil }).help("Next comment (⌥⇧])")
                if let context,mode == "Diff" {
                    Menu {
                        Picker("Change",selection:$contextHunk) { ForEach(0..<context.hunkCount,id:\.self) { Text("Change \($0+1)").tag($0) } }
                        Divider()
                        Button("Expand 20 lines above") { expandContext(above:true) }.disabled(context.gaps[contextHunk].count == 0)
                        Button("Expand 20 lines below") { expandContext(above:false) }.disabled(context.gaps[contextHunk+1].count == 0)
                        Button("Collapse context") { contextExpansion=[:];rebuildPresentations() }.disabled(contextExpansion.isEmpty)
                    } label: { Label("Context",systemImage:"arrow.up.and.down.text.horizontal") }
                    .fixedSize().help("Expand unchanged lines around change \(contextHunk+1)")
                }
                Spacer(minLength:8)
                if railAvailable {
                    Toggle(isOn:$overviewVisible) { Label(fileThreadCount > 0 ? "Threads (\(fileThreadCount))" : "Threads",systemImage:"text.bubble") }
                        .toggleStyle(.button).help(overviewVisible ? "Hide the thread overview beside the diff" : "Show every thread on this file beside the diff, including outdated ones")
                }
                Button("Comment on file",systemImage:"plus.bubble") { if let reviewRevision,let comment=try? ReviewDraftComment(fileBody:"",path:file.path,document:document,revision:reviewRevision) { fileComment=comment } }
                    .disabled(document.comparison != .pullRequest || commentSelected == nil || reviewRevision == nil)
                    .popover(item:$fileComment,arrowEdge:.bottom) { comment in commentPopover(comment) }
                Menu {
                    Button("Open in editor",systemImage:"curlybraces") { Task { editorMessage=await EditorNavigation.open(storage:storage,repository:pr.key.repository,path:anchor?.path ?? file.path,line:anchor?.startLine ?? 1) } }
                    Button("Blame on GitHub",systemImage:"person.text.rectangle") { openLine(blame:true) }
                    Button("Copy line link",systemImage:"link") { openLine(blame:false,copy:true) }
                    if !symbols.isEmpty {
                        Divider()
                        Menu("Symbols") { ForEach(Array(symbols.enumerated()),id:\.offset) { _,symbol in Button(symbol.name) { mode="Full file";selection=symbol.range;symbolToken &+= 1 } } }
                    }
                } label: { Label("More",systemImage:"ellipsis.circle") }
                .labelStyle(.iconOnly).menuIndicator(.hidden).fixedSize().help("More file actions")
            }
            .controlSize(.small)
            .padding(.horizontal,12).padding(.vertical,8)
    }
    private static func patchStateText(_ state:DiffFile.PatchState) -> String {
        switch state { case .available:"Patch available";case .unavailable:"Patch unavailable";case .truncated:"Patch truncated";case .oversized:"Patch too large" }
    }
    private var unavailable:some View { ContentUnavailableView("Content unavailable",systemImage:"doc.questionmark",description:Text("Binary, LFS, submodule, size-limited or missing content. Use the exact file link on GitHub.")) }
    private func pane(_ side:DiffSide?) -> some View {
        let key=side?.rawValue ?? "unified"
        let presentation=presentations[key] ?? DiffPresentation(file:DiffFile(path:file.path,status:file.status,patch:nil),side:side,hideWhitespace:false)
        return CodeTextView(text:presentation.text,wrap:wrap,path:file.path,tokens:paneTokens[key] ?? [],gutterMarks:gutterMarks[key] ?? [],firstTabColumn:6,scrollSync:side == nil ? nil : splitScroll,scrollTo:presentation.rows.first(where:{ $0.line == (jumpLine ?? requestedLine) && ((jumpSide ?? requestedSide) == nil || $0.side == (jumpSide ?? requestedSide)) })?.contentRange,scrollToken:requestToken &* 65_536 &+ jumpToken,selectedRange:{ selected in
            let range=Self.contentSelection(selected,in:presentation)
            guard let lines=presentation.lineRange(for:range) else { anchor=nil;return }
            let effective=side ?? presentation.rows.first(where:{ $0.line == lines.lowerBound && (range.length == 0 ? ($0.contentRange.length == 0 ? range.location == $0.contentRange.location : NSLocationInRange(range.location,$0.contentRange)) : NSIntersectionRange($0.contentRange,range).length > 0) })?.side ?? .right
            selectedSide=effective;anchor=(try? context?.anchor(side:effective,start:lines.lowerBound,end:lines.upperBound,visible:visible)) ?? (try? document.anchor(file:file,side:effective,start:lines.lowerBound,end:lines.upperBound))
        },inlineItems:inlineItems(side,pane:presentation),inlineHeightChanged:{ id,height in recordInlineHeight(key+":"+id,height) },gutterActivated:{ mark in gutterActivated(mark,pane:presentation) })
    }

    // MARK: Threads inside the code

    /// Thread lines on this file: writable threads once read, else the provider comments they come from (read-only).
    private var threadLines:[InlineThreadPlacement.Line] {
        guard railAvailable,let threads else { return [] }
        if threads.truth != nil {
            // Only threads anchored to this diff's head: the read can be at a newer push, whose lines would land on the
            // wrong rows (and move with every reload). The rest count as unplaced and stay in the overview.
            return threads.threads(for:file).compactMap { thread in PRThreadModel.line(thread,head:document.headSHA).map { .init(id:thread.id,side:$0.side,start:$0.start,end:$0.end) } }
        }
        return providerComments.compactMap { event in
            guard let location=event.renderingAnchor(in:document),let side=DiffSide(rawValue:location.side) else { return nil }
            return .init(id:event.id,side:side,start:location.startLine,end:location.endLine)
        }
    }
    /// Row → thread lines anchored below it, shared by the unified and both split panes; cached per presentation.
    private var placement:[Int:[InlineThreadPlacement.Line]] {
        let lines=threadLines
        guard !lines.isEmpty,mode == "Diff",let left=presentations["left"],let right=presentations["right"] else { return [:] }
        if let cached=placementCache.value,cached.presented == presented,cached.lines == lines { return cached.rows }
        let rows=InlineThreadPlacement.rows(lines,left:left,right:right)
        placementCache.value=(presented,lines,rows)
        return rows
    }
    /// One item per commented row. A split pane without threads of its own on that row reserves the same room empty,
    /// so both panes keep one row per diff line and scroll together.
    private func inlineItems(_ side:DiffSide?,pane:DiffPresentation) -> [CodeInlineItem] {
        let placed=placement
        guard !placed.isEmpty,let threads,let left=presentations["left"],let right=presentations["right"] else { return [] }
        let byID=Dictionary(threads.threads(for:file).map { ($0.id,$0) },uniquingKeysWith:{ first,_ in first })
        let comments=Dictionary(providerComments.map { ($0.id,$0) },uniquingKeysWith:{ first,_ in first })
        return placed.keys.sorted().compactMap { row in
            guard pane.rows.indices.contains(row),let lines=placed[row] else { return nil }
            let own=side.map { side in lines.filter { $0.side == side } } ?? lines
            // Keyed by its line, not its row or its threads: context expansion or hidden whitespace moves rows, and
            // another thread on the line changes the set, but a reply being typed in the hosted bubble must survive
            // both. Both split panes use the same key for the row.
            let id=InlineThreadPlacement.key(row:row,left:left,right:right)
            let content:AnyView?=own.isEmpty ? nil : AnyView(InlineThreadRow(model:threads,threads:own.compactMap { byID[$0.id] },head:document.headSHA,comments:threads.truth == nil ? own.compactMap { comments[$0.id] } : [],changed:{ threadsChanged?() }))
            return CodeInlineItem(id:id,location:pane.rows[row].contentRange.location,height:reservedHeight(id:id,lines:lines,split:side != nil),content:content)
        }
    }
    private func reservedHeight(id:String,lines:[InlineThreadPlacement.Line],split:Bool) -> CGFloat {
        let estimate=CGFloat(lines.count)*48+12
        guard split else { return inlineHeights["unified:"+id] ?? estimate }
        let sides=Set(lines.map(\.side))
        return sides.map { side in inlineHeights[side.rawValue+":"+id] ?? estimate }.max() ?? estimate
    }
    private func recordInlineHeight(_ key:String,_ height:CGFloat) {
        let value=height.rounded(.up)
        guard value > 0,abs((inlineHeights[key] ?? -1)-value) > 0.5 else { return }
        inlineHeights[key]=value
    }
    /// A click on a comment mark opens (or closes) the threads covering that line.
    private func gutterActivated(_ mark:CodeGutterMark,pane:DiffPresentation) {
        guard mark.kind == .comment,let threads,let left=presentations["left"],let right=presentations["right"],
              let row=InlineThreadPlacement.row(at:mark.range.location,in:pane) else { return }
        let ids=Set(InlineThreadPlacement.lines(threadLines,coveringRow:row,left:left,right:right).map(\.id))
        threads.toggle(threads.threads(for:file).filter { ids.contains($0.id) })
    }
    /// Jumping to a thread's line (Next comment, the overview) opens the threads there.
    private func expandThreads(side:DiffSide?,line:Int) {
        guard let threads else { return }
        let ids=threadLines.filter { (side == nil || $0.side == side) && $0.start <= line && line <= $0.end }.map(\.id)
        threads.setExpanded(ids,true)
    }
    /// Threads with no line in this diff (outdated, unmapped or anchored to a newer push) and thread read failures stay
    /// discoverable without the overview.
    private var unplacedThreadCount:Int {
        guard railAvailable,mode == "Diff",threads?.truth != nil,presentations["left"] != nil else { return 0 }
        return max(0,fileThreadCount-placement.values.reduce(0) { $0+$1.count })
    }
    private var hasThreadNotice:Bool { railAvailable && (threads?.error != nil || unplacedThreadCount > 0 || threads?.messages.isEmpty == false) }
    @ViewBuilder private var threadNotice:some View {
        if railAvailable,let threads {
            if let error=threads.error,!providerComments.isEmpty || fileThreadCount > 0 {
                HStack(spacing:8) {
                    Label("Reply and Resolve unavailable: "+error,systemImage:"exclamationmark.bubble").font(.caption).foregroundStyle(.orange)
                    Button("Read threads again") { Task { await threads.load() } }.controlSize(.small)
                }
            }
            if unplacedThreadCount > 0,!overviewVisible {
                HStack(spacing:8) {
                    Label("\(unplacedThreadCount) \(unplacedThreadCount == 1 ? "thread isn't" : "threads aren't") at a line in this diff (outdated, unmapped or on newer commits)",systemImage:"text.bubble").font(.caption).foregroundStyle(.secondary)
                    Button("Show overview") { overviewVisible=true }.controlSize(.small)
                }
            }
            if let key=threads.actionPR?.key,!threads.messages.isEmpty,!showsRail {
                PRWriteStatusView(key:key,storage:threads.storage,changeSignal:threads.operationRevision) { await threads.load();threadsChanged?() }.font(.caption)
            }
        }
    }
    /// A caret or selection confined to a row's "<number>\t<sign> " prefix or its line end selects that row.
    nonisolated private static func contentSelection(_ range:NSRange,in presentation:DiffPresentation) -> NSRange {
        guard presentation.lineRange(for:range) == nil,let row=presentation.rows.first(where:{ row in
            guard let line=row.line else { return false }
            return range.location >= row.contentRange.location-String(line).utf16.count-3 && NSMaxRange(range) <= NSMaxRange(row.contentRange)+(range.length > 0 ? 1 : 0)
        }) else { return range }
        return NSRange(location:row.contentRange.location,length:0)
    }
    nonisolated private static func renderMarks(_ values:[DiffGutterMarker]) -> [CodeGutterMark] {
        values.map { value in
            let kind:CodeGutterMark.Kind
            switch value.kind { case .lineNumber:kind = .lineNumber;case .added:kind = .added;case .removed:kind = .removed;case .comment:kind = .comment;case .annotation:kind = .annotation }
            let a=value.anchor
            return .init(range:value.range,kind:kind,label:value.label,identity:"\(a.commitSHA):\(a.path):\(a.side):\(a.startLine)")
        }
    }
    private var fullSide:DiffSide { after == nil ? .left : .right }
    private func rebuildPresentations() { preparationID=UUID() }
    private func preparePresentations() async {
        let instrumentation=storage.dependencies.fixtures?.detailInstrumentation
        let preparationStart=ContinuousClock.now,request=preparationID
        if instrumentation != nil { presentationIdentity=nil }
        do {
            let left=leftTokens,right=rightTokens
            let result=try await DiffPresentationWorker.shared.prepare(document:document,file:file,context:context,expansion:contextExpansion,events:annotations,hideWhitespace:hideWhitespace,fullSource:(after ?? before).flatMap { String(data:$0,encoding:.utf8) },fullSide:fullSide)
            let prepared=await Task.detached {
                // Diff text already shows numbers and signs; its panes keep only comment/annotation marks.
                (Dictionary(uniqueKeysWithValues:result.markers.map { key,values in (key,Self.renderMarks(key == "full" ? values : values.filter { $0.kind == .comment || $0.kind == .annotation })) }),
                 result.presentations.mapValues { DiffTokenMapping.tokens(for:$0,left:left,right:right) })
            }.value
            try Task.checkCancellation()
            presentations=result.presentations;gutterMarks=prepared.0;paneTokens=prepared.1;displayedLines=result.displayed;visible=result.visible;presented &+= 1
            if let instrumentation {
                let identity=CodePresentationIdentity(key:pr.key,head:document.headSHA,origin:document.baseSHA,comparison:document.comparison.rawValue,path:file.path,presentation:request)
                presentationIdentity=identity
                instrumentation.presentationPublished(identity,duration:preparationStart.duration(to:.now))
            }
        } catch { /* Cancelled preparation cannot replace the current immutable view. */ }
    }
    private func expandContext(above:Bool) {
        guard let context else { return }
        let gap=contextHunk+(above ? 0 : 1)
        var amount=contextExpansion[gap] ?? .init()
        if above { amount.fromEnd=min(context.gaps[gap].count,amount.fromEnd+20) }
        else { amount.fromStart=min(context.gaps[gap].count,amount.fromStart+20) }
        contextExpansion[gap]=amount;rebuildPresentations()
    }
    private var mappedComments:[PRDetailEvent] {
        annotations.filter { event in
            guard let location=event.renderingAnchor(in:document) else { return false }
            return location.path == file.path || location.path == file.previousPath
        }
    }
    private func jumpChange(_ direction:Int) {
        var seen=Set<Int>()
        let changes=file.lines.filter { $0.kind != .context && seen.insert($0.hunk).inserted }
        guard !changes.isEmpty else { return }
        changeIndex=changeIndex < 0 ? (direction > 0 ? 0 : changes.count-1) : (changeIndex+direction+changes.count)%changes.count
        let line=changes[changeIndex];jumpSide=line.kind == .removed ? .left : .right
        jumpLine=line.kind == .removed ? line.oldLine : line.newLine;jumpToken &+= 1;mode="Diff"
    }
    private func jumpComment() {
        let comments=mappedComments.filter { $0.providerComment != nil }
        guard !comments.isEmpty else { return }
        threadIndex=(threadIndex+1)%comments.count
        if let location=comments[threadIndex].renderingAnchor(in:document) { jumpLine=location.startLine;jumpSide=DiffSide(rawValue:location.side);jumpToken &+= 1;mode="Diff";expandThreads(side:jumpSide,line:location.endLine) }
    }
    private func selectFull(_ range:NSRange,text:String) {
        guard range.location >= 0,NSMaxRange(range) <= text.utf16.count else { return }
        let ns=text as NSString;let start=ns.substring(to:range.location).components(separatedBy:"\n").count
        let end=ns.substring(to:range.length > 0 ? NSMaxRange(range)-1 : range.location).components(separatedBy:"\n").count
        selectedSide=fullSide
        let maximum=text.components(separatedBy:"\n").count-(text.hasSuffix("\n") ? 1 : 0)
        guard start <= maximum,end <= maximum else { anchor=nil;return }
        anchor = .init(commitSHA:selectedSide == .left ? document.baseSHA : document.headSHA,path:selectedSide == .left ? file.previousPath ?? file.path : file.path,side:selectedSide.rawValue,startLine:start,endLine:end)
    }
    private struct SideSource:Sendable { let data:Data;let mapping:DiffTokenMapping?;let symbols:[CodeSymbol];let fallback:String? }
    private enum SideResult:Sendable { case skipped,loaded(SideSource),failed }
    private func loadSources() async {
        let head=document.headSHA,base=document.baseSHA
        let source:String?
        if let sources { source=await sources.gitattributes(storage:storage,pr:pr,head:head) }
        else { source=(try? await storage.detailBlob(pr,path:".gitattributes",sha:head)).flatMap { String(data:$0,encoding:.utf8) } }
        guard !Task.isCancelled else { return }
        if let source { attributes=FileAttributeRules(source).attributes(for:file.path) }
        if (attributes.generated || attributes.vendored) && !expanded { return }
        let language=attributes.language
        // Head and base sources read and tokenize concurrently; each side stands alone if the other fails.
        async let right=Self.readSide(storage:storage,sources:sources,pr:pr,path:file.path,sha:head,language:language,side:.right,skip:file.status == .removed)
        async let left=Self.readSide(storage:storage,sources:sources,pr:pr,path:file.previousPath ?? file.path,sha:base,language:language,side:.left,skip:file.status == .added)
        let (rightResult,leftResult)=await (right,left)
        guard !Task.isCancelled else { return }
        for (side,result) in [(DiffSide.right,rightResult),(.left,leftResult)] {
            switch result {
            case .skipped:break
            case .failed:message="Full source unavailable for one side. Available patch remains readable; open the file on GitHub for additional context."
            case .loaded(let value):
                if side == .left { before=value.data;leftTokens=value.mapping } else { after=value.data;rightTokens=value.mapping;if value.mapping != nil { symbols=value.symbols } }
                if let fallback=value.fallback { message=fallback }
            }
        }
        rebuildPresentations()
        if file.patchState == .available {
            do {
                let left=before.flatMap { String(data:$0,encoding:.utf8) }.map { DiffContext.Source(sha:base,text:$0) }
                let right=after.flatMap { String(data:$0,encoding:.utf8) }.map { DiffContext.Source(sha:head,text:$0) }
                let verified=try await DiffContextWorker.shared.build(document:document,file:file,before:left,after:right)
                try Task.checkCancellation();context=verified;rebuildPresentations()
            } catch { if !Task.isCancelled { message="Extra context cannot be verified against both immutable sources. Patch and full-file views remain available." } }
        }
    }
    /// One side's immutable source: window cache (shared with prefetch) or a direct read, then tokens mapped off the main actor.
    private static func readSide(storage:SetupStorage,sources:PRDiffSourceCache?,pr:PullRequest,path:String,sha:String,language:String?,side:DiffSide,skip:Bool) async -> SideResult {
        guard !skip else { return .skipped }
        let instrumentation=storage.dependencies.fixtures?.detailInstrumentation
        do {
            let sourceStart=ContinuousClock.now
            let data:Data
            if let sources { data=try await sources.blob(storage:storage,pr:pr,path:path,sha:sha) } else { data=try await storage.detailBlob(pr,path:path,sha:sha) }
            instrumentation?.sourceRead(pr.key,path:path,side:side,bytes:data.count,duration:sourceStart.duration(to:.now))
            try Task.checkCancellation()
            guard let text=String(data:data,encoding:.utf8) else { return .loaded(.init(data:data,mapping:nil,symbols:[],fallback:nil)) }
            let tokenStart=ContinuousClock.now
            let result=await CodeTokenizer.shared.tokenize(text,path:path,languageOverride:language)
            try Task.checkCancellation()
            let tokens=result.tokens
            let mapped=await Task.detached(priority:.userInitiated) { DiffTokenMapping(source:text,tokens:tokens) }.value
            instrumentation?.sourceTokenized(pr.key,path:path,side:side,duration:tokenStart.duration(to:.now))
            return .loaded(.init(data:data,mapping:mapped,symbols:result.symbols,fallback:result.fallbackReason))
        } catch { return Task.isCancelled ? .skipped : .failed }
    }
    private func openLine(blame:Bool,copy:Bool = false) {
        guard let web=pr.metadata?.webURL else { return }
        let root=web.deletingLastPathComponent().deletingLastPathComponent()
        let left=selectedSide == .left || file.status == .removed
        let path=anchor?.path ?? (left ? file.previousPath ?? file.path : file.path)
        let sha=anchor?.commitSHA ?? (left ? document.baseSHA : document.headSHA)
        var components=URLComponents(url:root.appendingPathComponent(blame ? "blame" : "blob").appendingPathComponent(sha).appendingPathComponent(path),resolvingAgainstBaseURL:false)
        components?.fragment="L\(anchor?.startLine ?? 1)"+(anchor.map { $0.endLine > $0.startLine ? "-L\($0.endLine)" : "" } ?? "")
        guard let url=components?.url,url.scheme == "https",url.user == nil,url.password == nil else { return }
        if copy { NSPasteboard.general.clearContents();NSPasteboard.general.setString(url.absoluteString,forType:.string) } else { ExternalLinkPolicy.open(url) }
    }
}

/// Diff preferences in user defaults.
enum DiffPreferences {
    /// The thread overview beside the diff; off by default, since threads sit inside the code.
    static let threadOverviewVisible="diffThreadOverviewVisible"
    /// `diffThreadRailVisible` (the thread rail, on by default) became the overview, which starts off: the old value
    /// isn't carried over, and is removed rather than left behind.
    static let retired=["diffThreadRailVisible"]
    static func removeRetired(from defaults:UserDefaults) { for key in retired { defaults.removeObject(forKey:key) } }
    /// Once per launch, when the first diff appears.
    static let retiredRemoved:Void = removeRetired(from:.standard)
}

/// Thread placement for the presentations last published (reference storage: reading it never invalidates the view).
@MainActor final class InlinePlacementCache {
    var value:(presented:Int,lines:[InlineThreadPlacement.Line],rows:[Int:[InlineThreadPlacement.Line]])?
}

/// One per detail window: `.gitattributes` once per head and shared in-flight reads over the process-wide,
/// account-scoped blob LRU (`PRDetailMemoryCache.shared.blobs`), so revisiting, prefetching, re-rendering
/// or opening another window never reads the same blob twice and every window shares one memory bound.
@MainActor final class PRDiffSourceCache {
    private var attributes:[String:Task<(source:String?,definitive:Bool),Never>]=[:]
    private let blobs=PRDetailMemoryCache.shared.blobs
    private var inFlight:[String:Task<Data,Error>]=[:]
    /// A missing file (404) is remembered for the head; a transient failure is retried by the next file.
    func gitattributes(storage:SetupStorage,pr:PullRequest,head:String) async -> String? {
        let task=attributes[head] ?? Task {
            do { return (String(data:try await storage.detailBlob(pr,path:".gitattributes",sha:head),encoding:.utf8),true) }
            catch { return (nil,(error as? GitHubFailure) == .resourceDenied) }
        }
        attributes[head]=task
        let value=await task.value
        if !value.definitive,attributes[head] == task { attributes[head]=nil }
        return value.source
    }
    func blob(storage:SetupStorage,pr:PullRequest,path:String,sha:String,priority:TaskPriority? = nil) async throws -> Data {
        let key=PRBlobMemoryCache.Key(repository:pr.key.repository,sha:sha,path:path),flight=Self.flight(key)
        if let data=blobs.data(key) { return data }
        let task=inFlight[flight] ?? Task(priority:priority) { try await storage.detailBlob(pr,path:path,sha:sha) }
        inFlight[flight]=task
        do { let data=try await task.value;inFlight[flight]=nil;blobs.store(data,for:key);return data }
        catch { inFlight[flight]=nil;throw error }
    }
    private static func flight(_ key:PRBlobMemoryCache.Key) -> String { key.sha+"\u{0}"+key.path }
    /// Low-priority read of a file's head and base sources so selecting it next needs no provider wait.
    func prefetch(storage:SetupStorage,pr:PullRequest,file:DiffFile,document:DiffDocument) {
        guard !file.collapsedByDefault,file.patchState == .available else { return }
        var reads:[(path:String,sha:String)]=[]
        if file.status != .removed { reads.append((file.path,document.headSHA)) }
        if file.status != .added { reads.append((file.previousPath ?? file.path,document.baseSHA)) }
        for read in reads {
            let key=PRBlobMemoryCache.Key(repository:pr.key.repository,sha:read.sha,path:read.path)
            guard !blobs.contains(key),inFlight[Self.flight(key)] == nil else { continue }
            Task(priority:.background) { [weak self] in _ = try? await self?.blob(storage:storage,pr:pr,path:read.path,sha:read.sha,priority:.background) }
        }
    }
}
