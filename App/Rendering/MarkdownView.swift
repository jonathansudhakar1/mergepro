import SwiftUI
import MergeProCore
import MergeProRendering

/// Full bounded GFM AST rendered with native views; raw HTML remains literal source.
struct MarkdownView:View {
    let source:String
    var webURL:URL? = nil
    @State private var document:NativeMarkdown?
    @State private var failed=false
    @Environment(\.codeAppearance) private var appearance
    /// One code line in the shared code surface: font line height plus its 2 pt line spacing.
    private var codeLineHeight:CGFloat {
        let size=min(28,max(9,appearance.fontSize)),font=NSFont(name:appearance.fontName,size:size) ?? .monospacedSystemFont(ofSize:size,weight:.regular)
        return ceil(font.ascender-font.descender+font.leading)+2
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            if let document { blocks(document.blocks) }
            else if failed {
                Text("Markdown exceeds native preview bounds. Source preview is limited to 256 KB; open the full content on GitHub.").font(.caption)
                CodeTextView(text:String(decoding:source.utf8.prefix(262144),as:UTF8.self),wrap:true).frame(height:260)
                if let webURL { Link("Open on GitHub",destination:webURL) }
            } else { ProgressView("Rendering Markdown…") }
        }.frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)
        .task(id:source) {
            document=nil;failed=false
            do { let value=try await NativeMarkdownWorker.shared.parse(source);try Task.checkCancellation();document=value }
            catch { if !Task.isCancelled { failed=true } }
        }
        // Provider content opens through the shared policy: https only, and non-GitHub hosts show the real URL first.
        .environment(\.openURL,OpenURLAction { url in ExternalLinkPolicy.open(url) ? .handled : .discarded })
    }
    private func blocks(_ values:[NativeMarkdown.Block]) -> some View {
        VStack(alignment:.leading,spacing:10) { ForEach(Array(values.enumerated()),id:\.offset) { _,value in block(value) } }
    }
    private func block(_ value:NativeMarkdown.Block) -> AnyView {
        switch value.kind {
        case .paragraph:return AnyView(inlines(value.inlines))
        case .heading:return AnyView(inlines(value.inlines).font(value.level == 1 ? .title : value.level == 2 ? .title2 : value.level == 3 ? .title3 : .headline).fontWeight(.semibold))
        case .literal:return AnyView(Text(value.literal).font(.system(.body,design:.monospaced)).textSelection(.enabled))
        case .rule:return AnyView(Divider().padding(.vertical,4))
        case .quote:return AnyView(HStack(alignment:.top) { Rectangle().fill(.secondary).frame(width:3);blocks(value.children).foregroundStyle(.secondary) }.fixedSize(horizontal:false,vertical:true))
        case .item:return AnyView(blocks(value.children))
        case .list:
            return AnyView(VStack(alignment:.leading,spacing:6) {
                ForEach(Array(value.children.enumerated()),id:\.offset) { index,item in
                    HStack(alignment:.top,spacing:8) {
                        if let checked=item.checked { Image(systemName:checked ? "checkmark.square" : "square").accessibilityLabel(checked ? "Completed task" : "Incomplete task") }
                        else { Text(value.listStart.map { "\($0+index)." } ?? "•").frame(minWidth:16,alignment:.trailing) }
                        blocks(item.children)
                    }
                }
            }.padding(.leading,8))
        case .code:
            if value.language.lowercased() == "mermaid",let graph=try? NativeFlowchart.parse(value.literal) { return AnyView(NativeFlowchartView(graph:graph)) }
            return AnyView(VStack(alignment:.leading) {
                if value.language.lowercased() == "mermaid" {
                    Text("Unsupported Mermaid syntax. Native flowcharts support bounded rectangular TD/TB/LR nodes and arrows; source is shown.").font(.caption)
                    if let webURL { Link("Open diagram on GitHub",destination:webURL) }
                }
                // The fence's trailing newline would add an empty, clipped last line.
                let code=value.literal.hasSuffix("\n") ? String(value.literal.dropLast()) : value.literal
                CodeTextView(text:code,wrap:true,path:"code."+value.language)
                    .frame(height:min(300,max(40,CGFloat(code.components(separatedBy:"\n").count)*codeLineHeight+22)))
                    .clipShape(RoundedRectangle(cornerRadius:8))
                    .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(Color(nsColor:.separatorColor).opacity(0.6),lineWidth:1).allowsHitTesting(false))
            })
        case .table:
            return AnyView(ScrollView(.horizontal) {
                Grid(alignment:.leading,horizontalSpacing:0,verticalSpacing:0) {
                    ForEach(Array(value.rows.enumerated()),id:\.offset) { row,cells in
                        GridRow {
                            ForEach(Array(cells.enumerated()),id:\.offset) { column,cell in
                                let alignment=value.alignments.indices.contains(column) ? value.alignments[column] : .left
                                inlines(cell).fontWeight(row == 0 ? .semibold : .regular)
                                    .frame(width:180,alignment:alignment == .right ? .trailing : alignment == .center ? .center : .leading)
                                    .padding(8).background(row == 0 ? Color.secondary.opacity(0.12) : .clear).border(.quaternary)
                            }
                        }
                    }
                }
            })
        }
    }
    private struct InlineGroup:Identifiable {
        let id:Int
        var runs:[NativeMarkdown.Run]
        var image:NativeMarkdown.Run?
    }
    private func groups(_ runs:[NativeMarkdown.Run]) -> [InlineGroup] {
        var result:[InlineGroup]=[],text:[NativeMarkdown.Run]=[]
        for run in runs {
            if run.image {
                if !text.isEmpty { result.append(.init(id:result.count,runs:text));text=[] }
                result.append(.init(id:result.count,runs:[],image:run))
            } else { text.append(run) }
        }
        if !text.isEmpty { result.append(.init(id:result.count,runs:text)) };return result
    }
    private func inlines(_ runs:[NativeMarkdown.Run]) -> some View {
        VStack(alignment:.leading,spacing:4) {
            ForEach(groups(runs)) { group in
                if let image=group.image {
                    if let url=image.destination {
                        MarkdownImagePreview(alt:image.text,url:url).id(url)
                        if let link=image.linkDestination { Link("Open linked image destination",destination:link) }
                    }
                    else { Text("Image: \(image.text) · unsupported or private reference; open GitHub to view.").font(.caption) }
                } else { Text(attributed(group.runs)) }
            }
        }
    }
    private func attributed(_ runs:[NativeMarkdown.Run]) -> AttributedString {
        var result=AttributedString()
        for run in runs {
            var text=AttributedString(run.text)
            var intent:InlinePresentationIntent=[]
            if run.styles.contains(.strong) { intent.insert(.stronglyEmphasized) }
            if run.styles.contains(.emphasis) { intent.insert(.emphasized) }
            if run.styles.contains(.strike) { intent.insert(.strikethrough) }
            if run.styles.contains(.code) { intent.insert(.code);text.font = .system(.body,design:.monospaced);text.backgroundColor = .secondary.opacity(0.1) }
            text.inlinePresentationIntent=intent
            if let url=run.destination { text.link=url }
            result += text
        }
        return result
    }
}
