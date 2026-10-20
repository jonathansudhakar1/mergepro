import MergeProCore
import SwiftUI

struct NativeFlowchartView:View {
    let graph:NativeFlowchart
    private let step:CGFloat=160
    private var horizontal:Bool { graph.direction == .horizontal }
    private func center(_ index:Int) -> CGPoint { CGPoint(x:horizontal ? CGFloat(index)*step+90 : 140,y:horizontal ? 70 : CGFloat(index)*90+45) }
    var body:some View {
        ScrollView([.horizontal,.vertical]) {
            ZStack(alignment:.topLeading) {
                Canvas { context,_ in
                    for edge in graph.edges {
                        guard let from=graph.nodes.firstIndex(where:{ $0.id == edge.from }),let to=graph.nodes.firstIndex(where:{ $0.id == edge.to }) else { continue }
                        var a=center(from),b=center(to)
                        if horizontal { a.x += from <= to ? 60 : -60;b.x += from <= to ? -60 : 60 }
                        else { a.y += from <= to ? 25 : -25;b.y += from <= to ? -25 : 25 }
                        var path=Path();path.move(to:a);path.addLine(to:b)
                        let angle=atan2(b.y-a.y,b.x-a.x)
                        path.move(to:CGPoint(x:b.x-8*cos(angle-0.45),y:b.y-8*sin(angle-0.45)));path.addLine(to:b);path.addLine(to:CGPoint(x:b.x-8*cos(angle+0.45),y:b.y-8*sin(angle+0.45)))
                        context.stroke(path,with:.color(.secondary),lineWidth:1.5)
                    }
                }
                ForEach(Array(graph.nodes.enumerated()),id:\.element.id) { index,node in
                    Text(node.label).font(.callout).lineLimit(3).multilineTextAlignment(.center).frame(width:112,height:44).padding(4)
                        .background(.background,in:RoundedRectangle(cornerRadius:6)).overlay(RoundedRectangle(cornerRadius:6).stroke(.secondary)).position(center(index))
                }
            }.frame(width:horizontal ? CGFloat(graph.nodes.count)*step+20 : 280,height:horizontal ? 140 : CGFloat(graph.nodes.count)*90)
        }.frame(height:min(380,horizontal ? 160 : CGFloat(graph.nodes.count)*90+16))
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("Flowchart. "+graph.nodes.map(\.label).joined(separator:", ")+". Connections: "+graph.edges.map { "\($0.from) to \($0.to)" }.joined(separator:", "))
    }
}

struct MarkdownImagePreview:View {
    let alt:String
    let url:URL
    @State private var requested=false
    @State private var image:CGImage?
    @State private var failure=false
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            if let image { Image(decorative:image,scale:1).resizable().scaledToFit().frame(maxHeight:360).accessibilityLabel(alt.isEmpty ? "Markdown image" : alt) }
            else if MarkdownRasterPolicy.approved(url) != nil && !failure {
                Button(requested ? "Loading public image…" : "Load public image: \(alt.isEmpty ? "image" : alt)") { requested=true }.disabled(requested)
                Text("Anonymous request · PNG, JPEG, GIF or WebP · up to 2 MB. Private images require GitHub.").font(.caption).foregroundStyle(.secondary)
            } else { Text("Image preview unavailable: private, external, signed, unsupported or oversized image. Open the image on the web.").font(.caption).foregroundStyle(.secondary) }
            if url.scheme == "https",url.user == nil,url.password == nil { Button("Open image on web") { ExternalLinkPolicy.open(url) }.buttonStyle(.link).help(url.absoluteString) }
        }.task(id:requested) {
            guard requested else { return }
            do {
                let data=try await MarkdownRasterClient().load(url)
                try Task.checkCancellation()
                guard let decoded=RasterImage.decode(data) else { failure=true;return }
                image=decoded
            } catch { if !Task.isCancelled { failure=true } }
        }
    }
}
