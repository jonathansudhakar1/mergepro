import Foundation

public enum RichFileDocument {
    public enum Kind: String,Sendable { case markdown,raster,svgSource,csv,notebook,lfs,text,binary }
    public static func kind(path:String,data:Data) -> Kind {
        if data.starts(with:Data("version https://git-lfs.github.com/spec/v1".utf8)) { return .lfs }
        switch URL(fileURLWithPath:path).pathExtension.lowercased() {
        case "md","markdown":return .markdown
        case "svg":return .svgSource
        case "csv":return .csv
        case "ipynb":return .notebook
        case "png","jpg","jpeg","gif","webp":return .raster
        default:return String(data:data,encoding:.utf8) == nil ? .binary : .text
        }
    }
    public static func csv(_ source:String) throws -> [[String]] {
        guard source.utf8.count <= 2_000_000 else { throw PRDetailFailure.oversized }
        var rows:[[String]]=[],row:[String]=[],cell="",quoted=false,afterQuote=false
        let chars=Array(source);var i=0
        while i < chars.count {
            let c=chars[i]
            if quoted {
                if c == "\"" {
                    if i+1 < chars.count,chars[i+1] == "\"" { cell.append("\"");i += 1 }
                    else { quoted=false;afterQuote=true }
                } else { cell.append(c) }
            } else if c == "\"",cell.isEmpty,!afterQuote { quoted=true }
            else if c == "," { row.append(cell);cell="";afterQuote=false }
            else if c == "\n" || c == "\r\n" || c == "\r" { row.append(cell);rows.append(row);row=[];cell="";afterQuote=false }
            else { guard !afterQuote else { throw PRDetailFailure.unavailable };cell.append(c) }
            guard rows.count <= 10000,row.count <= 200,cell.utf8.count <= 100000 else { throw PRDetailFailure.oversized }
            i += 1
        }
        guard !quoted else { throw PRDetailFailure.unavailable }
        if !row.isEmpty || !cell.isEmpty || afterQuote { row.append(cell);rows.append(row) }
        return rows
    }
    public struct NotebookCell:Sendable,Identifiable { public let id:Int;public let kind:String;public let source:String;public let outputs:[String] }
    public static func notebook(_ data:Data) throws -> [NotebookCell] {
        guard data.count <= 2_000_000,let json=try JSONSerialization.jsonObject(with:data) as? [String:Any],let cells=json["cells"] as? [[String:Any]],cells.count <= 2000 else { throw PRDetailFailure.oversized }
        func string(_ value:Any?) -> String { (value as? String) ?? (value as? [String])?.joined() ?? "" }
        return cells.enumerated().map { index,cell in
            let outputs=(cell["outputs"] as? [[String:Any]] ?? []).compactMap { output -> String? in
                if let text=output["text"] { return string(text) }
                if let plain=(output["data"] as? [String:Any])?["text/plain"] { return string(plain) }
                return nil
            }
            return .init(id:index,kind:cell["cell_type"] as? String ?? "raw",source:string(cell["source"]),outputs:outputs)
        }
    }
}
public struct EditorLocation:Sendable {
    public enum Editor:String,CaseIterable,Sendable {
        case vscode,cursor,xcode,zed,jetbrains
        public var displayName:String {
            switch self { case .vscode:"VS Code"; case .cursor:"Cursor"; case .xcode:"Xcode"; case .zed:"Zed"; case .jetbrains:"JetBrains" }
        }
    }
    public let url:URL
    public let line:Int
    public init(root:URL,path:String,line:Int) throws {
        guard root.isFileURL,GitHubPRDetailFetcher.validPath(path),line > 0,line <= 10000000 else { throw PRDetailFailure.invalidPath }
        let base=root.resolvingSymlinksInPath().standardizedFileURL
        var file=base
        for component in path.split(separator:"/") {
            file=file.appendingPathComponent(String(component)).resolvingSymlinksInPath().standardizedFileURL
            guard file.path.hasPrefix(base.path.hasSuffix("/") ? base.path : base.path+"/") else { throw PRDetailFailure.invalidPath }
        }
        self.url=file;self.line=line
    }
    public func editorURL(_ editor:Editor) -> URL? {
        if editor == .xcode { return url }
        var parts=URLComponents();parts.scheme=editor == .vscode ? "vscode" : editor == .cursor ? "cursor" : editor == .zed ? "zed" : "jetbrains"
        if editor == .jetbrains { parts.host="idea";parts.path="/navigate/reference";parts.queryItems=[.init(name:"path",value:url.path),.init(name:"line",value:String(line))] }
        else { parts.host="file";parts.path=url.path+":"+String(line) }
        return parts.url
    }
}
