import MergeProCore
import SwiftUI

struct StackSidebar:View {
    let stack:PRStack
    let current:ProviderKey
    let workspace:PRWorkspaceModel?
    let combined:() -> Void
    /// Opens a layer in this window; without it a layer opens its own window.
    var navigate:((ProviderKey) -> Void)? = nil
    @State private var presentation:PRActionPresentation?
    @Environment(\.openWindow) private var openWindow
    var body:some View {
        ScrollView { VStack(alignment:.leading,spacing:12) {
            Label(stack.kind == .native ? "Native stack" : "Inferred stack",systemImage:"square.3.layers.3d").font(.headline)
            Text("\(stack.layers.count) layers · bottom → top").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(stack.layers.enumerated()),id:\.element.key) { index,layer in
                Button {
                    if layer.key == current { return }
                    if let navigate { navigate(layer.key) }
                    else { workspace?.recordOpen(layer.key);openWindow(id:"pr-detail",value:layer.key) }
                } label: {
                    HStack(alignment:.top,spacing:8) {
                        Text("\(index+1)").font(.caption.monospacedDigit().weight(.semibold))
                            .frame(width:22,height:22).background(.quaternary,in:Circle()).accessibilityHidden(true)
                        VStack(alignment:.leading,spacing:5) {
                            Text("#\(String(layer.metadata?.number ?? 0)) \(layer.title)").fontWeight(layer.key == current ? .semibold : .regular).lineLimit(3)
                            Text("\(PRDetailText.state(layer)) · \(PRStatusSummary.checks(layer.metadata?.checks).text)").font(.caption).foregroundStyle(.secondary)
                            Text(PRStatusSummary.review(layer.metadata?.reviewDecision).text).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth:.infinity,alignment:.leading)
                        if layer.key == current { Image(systemName:"chevron.right").font(.caption).accessibilityHidden(true) }
                    }.padding(10).background(layer.key == current ? DesignTokens.cobalt.opacity(0.14):Color.clear,in:RoundedRectangle(cornerRadius:10))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("Layer \(index+1) of \(stack.layers.count), pull request \(layer.metadata?.number ?? 0), \(layer.title), \(PRDetailText.state(layer))")
                    .accessibilityValue(layer.key == current ? "Current pull request":"")
                    .help(layer.key == current ? "This pull request" : navigate == nil ? "Open this layer's pull request" : "Show this layer's pull request in this window")
            }
            Divider()
            ForEach(stack.warnings,id:\.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            Button("Read combined stack comparison",action:combined).disabled(!stack.warnings.isEmpty)
            Text("Combined comparison uses immutable bottom-base and top-head IDs; it has no comment anchors.").font(.caption).foregroundStyle(.secondary)
            if workspace != nil {
                Button("Approve whole stack…") { presentation = .init(rows:stack.layers.filter { $0.state == .open },kind:.batchApprove) }
                if stack.kind == .inferred {
                    Button("Merge up to here…") { if let layers=try? stack.affected(upTo:current) { presentation = .init(rows:layers,kind:.batchMerge) } }.disabled(!stack.warnings.isEmpty)
                    if let url=stack.layers.last?.metadata?.webURL { Button("Restacking on GitHub") { ExternalLinkPolicy.open(url) }.buttonStyle(.link) }
                }
            }
        }.padding(12).frame(maxWidth:.infinity,alignment:.topLeading) }.frame(width:250).accessibilityIdentifier("stackSidebar")
        .sheet(item:$presentation) { value in if let workspace { PRActionSheet(presentation:value,workspace:workspace) } }
        // Opening a layer already renders its saved metadata immediately. Avoid decoding every
        // layer's full diff in the background just to display this lightweight navigation list.
    }
}
