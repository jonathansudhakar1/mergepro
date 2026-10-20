import Foundation

/// Exact old/new snapshot candidates. Provider three-dot patches are used only as inventories.
public enum SnapshotInterdiff {
    public static let maximumFiles=200
    public static func candidates(forward:DiffDocument,reverse:DiffDocument,requestedOld:String,requestedNew:String) throws -> DiffDocument {
        guard forward.baseSHA == reverse.baseSHA else { throw PRDetailFailure.unavailable }
        func indexed(_ files:[DiffFile]) throws -> [String:DiffFile] {
            var values:[String:DiffFile]=[:]
            for file in files {
                let origin=file.previousPath ?? file.path
                guard values.updateValue(file,forKey:origin) == nil else { throw PRDetailFailure.unavailable }
            }
            return values
        }
        let new=try indexed(forward.files),old=try indexed(reverse.files)
        var files:[DiffFile]=[],paths=Set<String>(),unresolved=0
        for origin in Set(new.keys).union(old.keys).sorted() {
            let a=old[origin],b=new[origin]
            // Absence from an incomplete inventory does not imply unchanged or missing content.
            if (a == nil && reverse.missingFileCount > 0) || (b == nil && forward.missingFileCount > 0) { unresolved += 1;continue }
            let oldExists=a.map { $0.status != .removed } ?? (b?.status != .added)
            let newExists=b.map { $0.status != .removed } ?? (a?.status != .added)
            if !oldExists && !newExists { continue }
            let oldPath=a?.path ?? origin,newPath=b?.path ?? origin,path=newExists ? newPath : oldPath
            guard paths.insert(path).inserted else { throw PRDetailFailure.unavailable }
            let status:DiffFile.Status = !oldExists ? .added : !newExists ? .removed : oldPath != newPath ? .renamed : .modified
            files.append(.init(path:path,previousPath:oldExists && newExists && oldPath != newPath ? oldPath : nil,status:status,patch:nil))
        }
        // At either provider's 300-file cap, missing candidates cannot be inferred away.
        let missing=max(forward.missingFileCount,reverse.missingFileCount,unresolved)
        return .init(baseSHA:reverse.headSHA,headSHA:forward.headSHA,files:Array(files.prefix(maximumFiles)),expectedFiles:files.count+missing,requestedBase:requestedOld,requestedHead:requestedNew,resolvedBaseSHA:reverse.headSHA,comparison:.snapshot)
    }
}

/// Bounded exact LCS on decoded immutable source snapshots, never a provider merge-base patch.
public actor SnapshotDiffWorker {
    public static let shared=SnapshotDiffWorker()
    public static let maximumCells=1_000_000
    public func diff(file:DiffFile,before:String?,after:String?) throws -> DiffFile {
        try Task.checkCancellation()
        guard (before != nil || file.status == .added),(after != nil || file.status == .removed) else { throw PRDetailFailure.unavailable }
        func lines(_ text:String?) throws -> [String] {
            guard let text else { return [] }
            guard text.utf8.count <= 2_000_000 else { throw PRDetailFailure.oversized }
            if text.isEmpty { return [] }
            var value=text.components(separatedBy:"\n");if text.hasSuffix("\n") { value.removeLast() }
            guard value.count <= 100_000 else { throw PRDetailFailure.oversized }
            return value.enumerated().map { index,line in line+(index < value.count-1 || text.hasSuffix("\n") ? "\n" : "") }
        }
        let a=try lines(before),b=try lines(after)
        var prefix=0,suffix=0
        while prefix < min(a.count,b.count),a[prefix] == b[prefix] { prefix += 1 }
        while suffix < min(a.count,b.count)-prefix,a[a.count-1-suffix] == b[b.count-1-suffix] { suffix += 1 }
        let n=a.count-prefix-suffix,m=b.count-prefix-suffix
        guard n == 0 || m == 0 || (n+1) <= Self.maximumCells/(m+1) else { throw PRDetailFailure.oversized }
        var table=[Int32]()
        if n > 0 && m > 0 {
            table=Array(repeating:0,count:(n+1)*(m+1))
            for i in stride(from:n-1,through:0,by:-1) {
                try Task.checkCancellation()
                for j in stride(from:m-1,through:0,by:-1) {
                    table[i*(m+1)+j] = a[prefix+i] == b[prefix+j] ? 1+table[(i+1)*(m+1)+j+1] : max(table[(i+1)*(m+1)+j],table[i*(m+1)+j+1])
                }
            }
        }
        var edits:[(DiffLine.Kind,String)]=a.prefix(prefix).map { (.context,$0) },i=0,j=0
        while i < n || j < m {
            if i < n,j < m,a[prefix+i] == b[prefix+j] { edits.append((.context,a[prefix+i]));i += 1;j += 1 }
            else if i < n && (j == m || table[(i+1)*(m+1)+j] >= table[i*(m+1)+j+1]) { edits.append((.removed,a[prefix+i]));i += 1 }
            else { edits.append((.added,b[prefix+j]));j += 1 }
        }
        edits += a.suffix(suffix).map { (.context,$0) }
        var patch="@@ -\(a.isEmpty ? 0 : 1),\(a.count) +\(b.isEmpty ? 0 : 1),\(b.count) @@\n",oldLine=0,newLine=0,added=0,removed=0
        for (kind,text) in edits {
            switch kind { case .context:patch += " ";oldLine += 1;newLine += 1;case .removed:patch += "-";oldLine += 1;removed += 1;case .added:patch += "+";newLine += 1;added += 1 }
            patch += (text.hasSuffix("\n") ? String(text.dropLast()) : text)+"\n"
            if (kind != .added && oldLine == a.count && before?.hasSuffix("\n") == false) || (kind != .removed && newLine == b.count && after?.hasSuffix("\n") == false) { patch += "\\ No newline at end of file\n" }
        }
        guard patch.utf8.count <= 4_000_000 else { throw PRDetailFailure.oversized }
        return .init(path:file.path,previousPath:file.previousPath,status:before == after && file.status == .modified ? .unchanged : file.status,patch:patch,additions:added,deletions:removed,sha:file.sha)
    }
}
