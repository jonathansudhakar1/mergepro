import AppKit
import SwiftUI
import MergeProRendering
import MergeProCore

/// Shared native rendering for full files, diffs and fenced prose. Tokenization always
/// receives an entire source; diff callers supply ranges mapped from full source tokens.
struct CodeTextView:View {
    let text:String
    var wrap=false
    var path=""
    var languageOverride:String? = nil
    /// Raw `git diff` output: syntax colors from `path` plus git-style line tints. `.diff` and `.patch` paths imply it.
    var patch=false
    var tokens:[CodeToken]? = nil
    var gutterMarks:[CodeGutterMark]=[]
    var tabColumns=4
    /// Diff rows start "<number>\t<sign> "; see NativeCodeSurface.setDocument.
    var firstTabColumn:Int? = nil
    var scrollSync:CodeScrollSync? = nil
    var scrollTo:NSRange? = nil
    /// A new token re-requests the scroll even when `scrollTo` equals the previous target (a repeated Jump).
    var scrollToken=0
    var selectedRange:((NSRange)->Void)?
    /// Views inside the code below their lines (review threads); each reports its measured height through `inlineHeightChanged`.
    var inlineItems:[CodeInlineItem]=[]
    var inlineHeightChanged:((String,CGFloat) -> Void)? = nil
    /// A click on a gutter mark, after the gutter selects and reveals its range.
    var gutterActivated:((CodeGutterMark) -> Void)? = nil
    @Environment(\.codeAppearance) private var appearance
    @State private var highlighted:CodeHighlightSnapshot?
    @State private var patchTokens:(identity:CodeDocumentIdentity,tokens:[CodeToken])?
    private var isPatch:Bool { patch || path.hasSuffix(".diff") || path.hasSuffix(".patch") }
    var body:some View {
        let identity=CodeDocumentIdentity(source:text,path:path,languageOverride:languageOverride)
        let overlays=patchTokens.flatMap { $0.identity == identity ? $0.tokens : nil } ?? []
        CodeSurface(text:text,wrap:wrap,tokens:tokens ?? (highlighted?.tokens(for:identity) ?? [])+overlays,fontSize:appearance.fontSize,fontName:appearance.fontName,ligatures:appearance.ligatures,theme:appearance.theme,gutterMarks:gutterMarks,tabColumns:tabColumns,firstTabColumn:firstTabColumn,scrollSync:scrollSync,scrollTo:scrollTo,scrollToken:scrollToken,selectedRange:selectedRange,
                    inlineItems:inlineItems,inlineHeightChanged:inlineHeightChanged,gutterActivated:gutterActivated,appearance:appearance)
            // Caller-supplied tokens need no tokenizer pass, so avoid copying large text into the task identity.
            .task(id:tokens == nil ? identity : nil) {
                guard tokens == nil,!path.isEmpty || languageOverride != nil else { return }
                if isPatch {
                    let source=identity.source
                    let overlays=await Task.detached { GitPatchTokens.tokens(in:source) }.value
                    guard !Task.isCancelled else { return };patchTokens=(identity,overlays)
                }
                let result=await CodeTokenizer.shared.tokenize(identity.source,path:identity.path,languageOverride:identity.languageOverride)
                guard !Task.isCancelled else { return };highlighted=CodeHighlightSnapshot(identity:identity,result:result)
            }
    }
}
private struct CodeSurface:NSViewRepresentable {
    @Environment(\.codeSurfaceInstrumentation) private var instrumentation
    @Environment(\.codePresentation) private var presentation
    let text:String
    let wrap:Bool
    let tokens:[CodeToken]
    let fontSize:Double
    let fontName:String
    let ligatures:Bool
    let theme:String
    let gutterMarks:[CodeGutterMark]
    let tabColumns:Int
    let firstTabColumn:Int?
    let scrollSync:CodeScrollSync?
    let scrollTo:NSRange?
    let scrollToken:Int
    var selectedRange:((NSRange)->Void)?
    let inlineItems:[CodeInlineItem]
    let inlineHeightChanged:((String,CGFloat) -> Void)?
    let gutterActivated:((CodeGutterMark) -> Void)?
    let appearance:CodeAppearance
    func makeCoordinator() -> Coordinator { Coordinator() }
    @MainActor final class Coordinator {
        var scrollTo:NSRange?
        var scrollToken=0
        var documentText:String?
        /// One hosting view per inline item, reused across updates so a reply being typed keeps its state.
        var inlineHosts:[String:NSHostingView<CodeInlineHost>]=[:]
        /// What the instrumentation keeps alive with the surface (`CodeSurfaceInstrumentation.surfaceCreated`).
        var instrumentationToken:AnyObject?
    }
    func makeNSView(context:Context) -> NativeCodeSurface {
        let surface=NativeCodeSurface(frame:.zero)
        context.coordinator.instrumentationToken=instrumentation?.surfaceCreated(surface)
        return surface
    }
    func updateNSView(_ view:NativeCodeSurface,context:Context) {
        if context.coordinator.documentText != text {
            context.coordinator.documentText=text;context.coordinator.scrollTo=nil
        }
        view.selectionChanged=selectedRange
        if let scrollSync { scrollSync.add(view) } else { view.scrolled=nil }
        let installStart=ContinuousClock.now
        view.setDocument(text,tokens:tokens,wrap:wrap,fontSize:fontSize,fontName:fontName,ligatures:ligatures,theme:theme,gutterMarks:gutterMarks,tabColumns:tabColumns,firstTabColumn:firstTabColumn)
        instrumentation?.documentInstalled(view,presentation:presentation,duration:installStart.duration(to:.now))
        installInline(view,coordinator:context.coordinator)
        view.gutterMarkActivated=gutterActivated
        if scrollTo == nil { context.coordinator.scrollTo=nil;context.coordinator.scrollToken=scrollToken }
        if let scrollTo,scrollTo != context.coordinator.scrollTo || scrollToken != context.coordinator.scrollToken,scrollTo.location >= 0,NSMaxRange(scrollTo) <= text.utf16.count {
            context.coordinator.scrollTo=scrollTo;context.coordinator.scrollToken=scrollToken;view.codeView.setSelectedRange(scrollTo);view.codeView.scrollRangeToVisible(scrollTo)
        }
    }
    /// Inline items become accessories after the document is installed, since their offsets refer to its text.
    private func installInline(_ view:NativeCodeSurface,coordinator:Coordinator) {
        var accessories:[CodeInlineAccessory]=[],live=Set<String>()
        for item in inlineItems {
            var host:NSView?
            if let content=item.content {
                let id=item.id,report=inlineHeightChanged
                let root=CodeInlineHost(content:content,appearance:appearance,instrumentation:instrumentation) { height in report?(id,height) }
                if let existing=coordinator.inlineHosts[id] { existing.rootView=root;host=existing }
                else { let created=NSHostingView(rootView:root);created.sizingOptions=[];coordinator.inlineHosts[id]=created;host=created }
                live.insert(id)
            }
            accessories.append(.init(identity:item.id,location:item.location,height:item.height,view:host))
        }
        for id in coordinator.inlineHosts.keys where !live.contains(id) { coordinator.inlineHosts[id]=nil }
        view.setInlineAccessories(accessories)
    }
}

/// SwiftUI content inside the code below one line (e.g. a review thread). `height` is the room reserved now; the content's
/// measured height arrives through `CodeTextView.inlineHeightChanged`. Nil content reserves room only, so a split diff's
/// other pane stays row-aligned.
struct CodeInlineItem:Identifiable {
    let id:String
    /// Any UTF-16 offset in the line the item follows.
    let location:Int
    let height:CGFloat
    let content:AnyView?
}
/// Hosted inline content: laid out at the visible text width, its natural height reported after each layout change.
struct CodeInlineHost:View {
    let content:AnyView
    let appearance:CodeAppearance
    /// Hosted views don't inherit the environment, so the surface hands its instrumentation on.
    let instrumentation:(any CodeSurfaceInstrumentation)?
    let report:(CGFloat) -> Void
    var body:some View {
        content
            .environment(\.codeAppearance,appearance)
            .environment(\.codeSurfaceInstrumentation,instrumentation)
            .frame(maxWidth:.infinity,alignment:.leading)
            .fixedSize(horizontal:false,vertical:true)
            // Deferred: the report changes the caller's state, which must not happen inside this layout pass.
            .onGeometryChange(for:CGFloat.self) { $0.size.height } action:{ height in Task { @MainActor in report(height) } }
            .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
    }
}

struct CodeAppearance:Sendable { var fontSize=12.0;var fontName="";var ligatures=false;var theme="system" }
private struct CodeAppearanceKey:EnvironmentKey { static let defaultValue=CodeAppearance() }
extension EnvironmentValues {
    var codeAppearance:CodeAppearance {
        get { self[CodeAppearanceKey.self] }
        set { self[CodeAppearanceKey.self]=newValue }
    }
}

/// The diff presentation a code surface shows: pull request, revisions, comparison, path and the preparation that
/// published it. Diffs set it (`codePresentation`) only while code surfaces are instrumented.
struct CodePresentationIdentity:Sendable,Equatable {
    let key:ProviderKey
    let head:String,origin:String,comparison:String,path:String
    let presentation:UUID
}
private struct CodeSurfaceInstrumentationKey:EnvironmentKey { static let defaultValue:(any CodeSurfaceInstrumentation)? = nil }
private struct CodePresentationKey:EnvironmentKey { static let defaultValue:CodePresentationIdentity? = nil }
extension EnvironmentValues {
    /// Measurement hooks of the code surfaces below (the fixture app's); nil in the shipped app.
    var codeSurfaceInstrumentation:(any CodeSurfaceInstrumentation)? {
        get { self[CodeSurfaceInstrumentationKey.self] }
        set { self[CodeSurfaceInstrumentationKey.self]=newValue }
    }
    /// The diff presentation the code surfaces below show, while they are instrumented.
    var codePresentation:CodePresentationIdentity? {
        get { self[CodePresentationKey.self] }
        set { self[CodePresentationKey.self]=newValue }
    }
}
