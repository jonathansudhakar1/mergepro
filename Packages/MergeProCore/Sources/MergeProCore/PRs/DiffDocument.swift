import Foundation

/// Rendering content coordinates. LEFT commitSHA is the diff origin; it must never
/// be copied into a provider reviewed-head/commit_id without a transport-specific contract.
public struct ReviewAnchor: Hashable, Codable, Sendable {
    public let commitSHA: String
    public let path: String
    public let side: String
    public let startLine: Int
    public let endLine: Int
    public init(commitSHA:String,path:String,side:String,startLine:Int,endLine:Int) {
        self.commitSHA=commitSHA; self.path=path; self.side=side; self.startLine=startLine; self.endLine=endLine
    }
}
public enum DiffSide: String, Sendable { case left = "LEFT", right = "RIGHT" }
public struct DiffLine: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case context, added, removed }
    public let id: Int
    public let hunk: Int
    public let kind: Kind
    public let text: String
    public let oldLine: Int?
    public let newLine: Int?
}
public struct DiffFile: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case added, removed, modified, renamed, copied, changed, unchanged }
    public enum PatchState: String, Sendable { case available, unavailable, truncated, oversized }
    public let path: String
    public let previousPath: String?
    public let status: Status
    public let patch: String?
    public let additions: Int
    public let deletions: Int
    /// Blob SHA from the provider's files API (the head-side blob; the removed blob for a deletion). Nil when not read.
    public let sha: String?
    public var id: String { path }
    public init(path:String,previousPath:String? = nil,status:Status,patch:String?,additions:Int = 0,deletions:Int = 0,sha:String? = nil) {
        self.path=path; self.previousPath=previousPath; self.status=status; self.patch=patch; self.additions=additions; self.deletions=deletions; self.sha=sha
        let value=Self.parse(patch,additions:additions,deletions:deletions);self.lines=value.0;self.patchState=value.1;self.lineIndex=DiffLineIndex(value.0)
    }
    public let lines:[DiffLine]
    public let patchState:PatchState
    public let lineIndex:DiffLineIndex
    private enum CodingKeys:String,CodingKey { case path,previousPath,status,patch,additions,deletions,sha }
    public init(from decoder:any Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        self.init(path:try c.decode(String.self,forKey:.path),previousPath:try c.decodeIfPresent(String.self,forKey:.previousPath),status:try c.decode(Status.self,forKey:.status),patch:try c.decodeIfPresent(String.self,forKey:.patch),additions:try c.decode(Int.self,forKey:.additions),deletions:try c.decode(Int.self,forKey:.deletions),sha:try c.decodeIfPresent(String.self,forKey:.sha))
    }
    public static func ==(a:Self,b:Self) -> Bool { a.path == b.path && a.previousPath == b.previousPath && a.status == b.status && a.patch == b.patch && a.additions == b.additions && a.deletions == b.deletions && a.sha == b.sha }
    public var collapsedByDefault: Bool {
        let p = path.lowercased()
        return p.split(separator:"/").contains { ["vendor","vendored","node_modules","generated","dist"].contains(String($0)) } || p.hasSuffix(".lock") || ["package-lock.json","yarn.lock","pnpm-lock.yaml","package.resolved"].contains(URL(fileURLWithPath:p).lastPathComponent) || p.contains(".generated.") || p.hasSuffix(".min.js")
    }
    private static func parse(_ patch:String?,additions:Int,deletions:Int) -> ([DiffLine],PatchState) {
        guard let patch else { return ([],.unavailable) }
        guard patch.utf8.count <= 4_000_000 else { return ([],.oversized) }
        var result: [DiffLine] = []; var old = 0; var new = 0; var oldRemaining = 0; var newRemaining = 0
        var hunk = -1; var valid = true
        for raw in patch.components(separatedBy:"\n") {
            if raw.hasPrefix("@@ ") {
                if oldRemaining != 0 || newRemaining != 0 { valid = false }
                let parts = raw.split(separator:" ")
                guard parts.count >= 4, parts[3] == "@@", let a = Self.range(parts[1],prefix:"-"), let b = Self.range(parts[2],prefix:"+") else { valid=false; continue }
                old=a.0; oldRemaining=a.1; new=b.0; newRemaining=b.1; hunk += 1
                continue
            }
            if raw.hasPrefix("\\ No newline") || raw.isEmpty { continue }
            guard hunk >= 0, let prefix = raw.first else { valid=false; continue }
            let kind: DiffLine.Kind
            switch prefix { case " ": kind = .context; case "+": kind = .added; case "-": kind = .removed; default: valid=false; continue }
            let usesOld = kind != .added, usesNew = kind != .removed
            if usesOld && oldRemaining <= 0 || usesNew && newRemaining <= 0 { valid=false; continue }
            result.append(DiffLine(id:result.count,hunk:hunk,kind:kind,text:String(raw.dropFirst()),oldLine:usesOld ? old : nil,newLine:usesNew ? new : nil))
            if usesOld { old += 1; oldRemaining -= 1 }; if usesNew { new += 1; newRemaining -= 1 }
        }
        if additions > 0 && result.filter({ $0.kind == .added }).count != additions { valid=false }
        if deletions > 0 && result.filter({ $0.kind == .removed }).count != deletions { valid=false }
        return (result, valid && hunk >= 0 && oldRemaining == 0 && newRemaining == 0 ? .available : .truncated)
    }
    private static func range(_ value:Substring,prefix:Character) -> (Int,Int)? {
        guard value.first == prefix else { return nil }; let parts=value.dropFirst().split(separator:",",omittingEmptySubsequences:false)
        guard parts.count <= 2,let start=Int(parts[0]),let count=parts.count == 2 ? Int(parts[1]) : 1,start >= 0,count >= 0,start < Int.max-count else { return nil }
        return (start,count)
    }
}
public struct DiffDocument: Sendable {
    public enum Comparison:String,Sendable { case pullRequest,threeDot,snapshot }
    public let comparison:Comparison
    public let baseSHA: String
    public let headSHA: String
    public let files: [DiffFile]
    public let expectedFiles: Int
    public let requestedBase:String?
    public let requestedHead:String?
    public let resolvedBaseSHA:String?
    public init(baseSHA:String,headSHA:String,files:[DiffFile],expectedFiles:Int,requestedBase:String? = nil,requestedHead:String? = nil,resolvedBaseSHA:String? = nil,comparison:Comparison = .pullRequest) { self.baseSHA=baseSHA;self.headSHA=headSHA;self.files=files;self.expectedFiles=expectedFiles;self.requestedBase=requestedBase;self.requestedHead=requestedHead;self.resolvedBaseSHA=resolvedBaseSHA;self.comparison=comparison }
    public func replacing(_ file:DiffFile) -> Self {
        .init(baseSHA:baseSHA,headSHA:headSHA,files:files.map { $0.path == file.path ? file : $0 },expectedFiles:expectedFiles,requestedBase:requestedBase,requestedHead:requestedHead,resolvedBaseSHA:resolvedBaseSHA,comparison:comparison)
    }
    public var missingFileCount: Int { max(0,expectedFiles-files.count) }
    public enum AnchorError: Error { case unavailable }
    public func anchor(file:DiffFile,side:DiffSide,start:Int,end:Int) throws -> ReviewAnchor {
        guard start > 0,end >= start,end-start < 10000,files.contains(file),file.patchState == .available else { throw AnchorError.unavailable }
        guard file.lineIndex.contains(side:side,start:start,end:end,sameHunk:true) else { throw AnchorError.unavailable }
        return ReviewAnchor(commitSHA:side == .left ? baseSHA : headSHA,path:side == .left ? file.previousPath ?? file.path : file.path,side:side.rawValue,startLine:start,endLine:end)
    }
    public struct SearchResult: Sendable {
        public struct Match: Sendable, Identifiable { public let path:String;public let line:DiffLine;public var id:String { path+":"+String(line.id) } }
        public let matches: [Match]
        public let complete: Bool
    }
    public func search(_ term:String) -> SearchResult {
        SearchResult(matches:term.isEmpty ? [] : files.flatMap { file in file.lines.filter { $0.text.localizedCaseInsensitiveContains(term) }.map { SearchResult.Match(path:file.path,line:$0) } },complete:missingFileCount == 0 && files.allSatisfy { $0.patchState == .available })
    }
}
public enum DiffWords {
    public static func onlyWhitespace(old:String,new:String) -> Bool { old.filter { !$0.isWhitespace } == new.filter { !$0.isWhitespace } }
    public static func changedRange(old:String,new:String) -> (old:NSRange,new:NSRange) {
        let a=Array(old),b=Array(new);var prefix=0;var suffix=0
        while prefix < min(a.count,b.count) && a[prefix] == b[prefix] { prefix += 1 }
        while suffix < min(a.count,b.count)-prefix && a[a.count-1-suffix] == b[b.count-1-suffix] { suffix += 1 }
        func range(_ v:[Character]) -> NSRange { NSRange(location:String(v.prefix(prefix)).utf16.count,length:String(v[prefix..<(v.count-suffix)]).utf16.count) }
        return (range(a),range(b))
    }
}

/// Built once per immutable source/presentation; single-line membership is O(1).
public struct DiffLineIndex:Sendable {
    private let left:[Int:Int]
    private let right:[Int:Int]
    public init(_ lines:[DiffLine]) {
        var l:[Int:Int]=[:],r:[Int:Int]=[:]
        for line in lines { if let n=line.oldLine { l[n]=line.hunk };if let n=line.newLine { r[n]=line.hunk } }
        left=l;right=r
    }
    public func contains(side:DiffSide,start:Int,end:Int,sameHunk:Bool = false) -> Bool {
        guard start > 0,end >= start,end-start < 10000 else { return false }
        let index=side == .left ? left : right
        guard let hunk=index[start] else { return false }
        return (start...end).allSatisfy { index[$0].map { !sameHunk || $0 == hunk } ?? false }
    }
}
