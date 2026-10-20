import ImageIO
import MergeProCore
import SwiftUI
import UniformTypeIdentifiers

struct RichFilePreview:View {
    let path:String
    let before:Data?
    let after:Data?
    var webURL:URL? = nil
    @State private var imageMode="Side by side"
    @State private var blend=0.5
    var body:some View {
        let data=after ?? before ?? Data()
        switch RichFileDocument.kind(path:path,data:data) {
        case .markdown:
            ScrollView { HStack(alignment:.top) { if let before { MarkdownView(source:String(decoding:before,as:UTF8.self),webURL:webURL) };if let after { MarkdownView(source:String(decoding:after,as:UTF8.self),webURL:webURL) } }.padding() }
        case .csv:
            if let rows=try? RichFileDocument.csv(String(decoding:data,as:UTF8.self)) {
                ScrollView([.horizontal,.vertical]) { LazyVStack(alignment:.leading,spacing:0) {
                    ForEach(Array(rows.prefix(2000).enumerated()),id:\.offset) { _,row in
                        HStack(alignment:.top,spacing:0) { ForEach(Array(row.enumerated()),id:\.offset) { _,cell in Text(cell).textSelection(.enabled).frame(width:160,alignment:.leading).padding(6).border(.quaternary) } }
                    }
                    if rows.count > 2000 { Text("Table preview limited to 2,000 rows. Full source remains available.") }
                }.padding() }
            } else { fallback("CSV parse or size limit. Use full source.") }
        case .notebook:
            if let cells=try? RichFileDocument.notebook(data) {
                ScrollView { LazyVStack(alignment:.leading,spacing:14) {
                    ForEach(cells) { cell in
                        Text("Cell \(cell.id+1) · "+(cell.kind == "markdown" ? "Markdown" : cell.kind == "code" ? "Code" : cell.kind == "raw" ? "Raw" : "Other")).font(.caption).foregroundStyle(.secondary)
                        if cell.kind == "markdown" { MarkdownView(source:cell.source) }
                        else { CodeTextView(text:cell.source,wrap:true,path:"cell.py").frame(height:CGFloat(min(350,max(80,cell.source.components(separatedBy:"\n").count*17+22)))) }
                        ForEach(Array(cell.outputs.enumerated()),id:\.offset) { _,output in Text(output).font(.system(.body,design:.monospaced)).textSelection(.enabled) }
                    }
                    Text("Notebook cells are never executed. HTML, widgets and unsupported output MIME types are omitted.").font(.caption)
                }.padding() }
            } else { fallback("Notebook parse or size limit. Use full source.") }
        case .raster:
            if let current=RasterImage.decode(data) {
                VStack {
                    Picker("Image comparison",selection:$imageMode) { ForEach(["Side by side","Swipe","Onion skin"],id:\.self) { Text($0) } }.pickerStyle(.segmented)
                    GeometryReader { geometry in
                        if let before,let previous=RasterImage.decode(before) {
                            if imageMode == "Side by side" { HStack { image(previous);image(current) } }
                            else { ZStack { image(previous);image(current).opacity(imageMode == "Onion skin" ? blend : 1).mask(alignment:.leading) { Rectangle().frame(width:imageMode == "Swipe" ? geometry.size.width*blend : geometry.size.width) } } }
                        } else { image(current) }
                    }
                    if imageMode != "Side by side" { Slider(value:$blend,in:0...1) }
                    Text("\(data.count.formatted()) bytes · raster preview").font(.caption)
                }.padding()
            } else { fallback("Unsupported raster type, pixel or size limit. Use GitHub.") }
        case .svgSource: VStack { Text("SVG source only. Scripts, links and external resources are never loaded.").font(.caption);CodeTextView(text:String(decoding:data,as:UTF8.self),wrap:true) }
        case .lfs: fallback("Git LFS pointer · media is not downloaded automatically.\n"+String(decoding:data.prefix(400),as:UTF8.self))
        case .binary: fallback("Binary content · \(data.count.formatted()) bytes. Native preview unavailable.")
        case .text: CodeTextView(text:String(decoding:data,as:UTF8.self),wrap:true,path:path)
        }
    }
    private func fallback(_ message:String) -> some View { ContentUnavailableView("Preview unavailable",systemImage:"doc",description:Text(message)) }
    private func image(_ value:CGImage) -> some View { Image(decorative:value,scale:1).resizable().scaledToFit().accessibilityLabel("Repository image") }
}

enum RasterImage {
    static func decode(_ data:Data) -> CGImage? {
        guard data.count <= 2_000_000,let source=CGImageSourceCreateWithData(data as CFData,nil),let type=CGImageSourceGetType(source) as String?,[UTType.png.identifier,UTType.jpeg.identifier,UTType.gif.identifier,UTType.webP.identifier].contains(type),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,width > 0,height > 0,width <= 10000,height <= 10000,width*height <= 20_000_000 else { return nil }
        return CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCache:false] as CFDictionary)
    }
}
