import AppKit
import MergeProCore

@MainActor enum EditorNavigation {
    static func map(storage:SetupStorage,repository:RepositoryKey) async -> String {
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false
        panel.prompt="Map repository";panel.message="Select the local clone folder for read-only file navigation."
        guard panel.runModal() == .OK,let url=panel.url else { return "Folder mapping unchanged." }
        let accessed=url.startAccessingSecurityScopedResource();defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data=try url.bookmarkData(options:[.withSecurityScope,.securityScopeAllowOnlyReadAccess],includingResourceValuesForKeys:nil,relativeTo:nil)
            try await storage.saveEditorBookmark(data,repo:repository);return "Mapped \(url.lastPathComponent)."
        } catch { return "Folder mapping could not be saved." }
    }
    static func open(storage:SetupStorage,repository:RepositoryKey,path:String,line:Int) async -> String? {
        do {
            guard let data=try await storage.editorBookmark(repository) else { return "Map this repository’s local clone folder in Settings first." }
            var stale=false
            let root=try URL(resolvingBookmarkData:data,options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale)
            guard !stale else { return "Folder bookmark is stale. Map the repository again in Settings." }
            let access=root.startAccessingSecurityScopedResource();defer { if access { root.stopAccessingSecurityScopedResource() } }
            let location=try EditorLocation(root:root,path:path,line:line)
            let editor=EditorLocation.Editor(rawValue:try await storage.editorPreference()) ?? .vscode
            if editor == .xcode {
                let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/xed");process.arguments=["--line",String(line),location.url.path]
                try process.run()
            } else if let url=location.editorURL(editor) {
                guard NSWorkspace.shared.open(url) else { return "The selected editor is not installed or did not accept its URL." }
            }
            return nil
        } catch { return "The selected path is unavailable or outside the mapped repository." }
    }
}
