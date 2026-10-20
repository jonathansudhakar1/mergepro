import Foundation

public enum LocalGitPathAccess {
    /// Resolve each existing symlink component, including a symlink followed by a missing leaf.
    /// Foundation's resolvingSymlinksInPath alone can leave that combination unresolved.
    public static func canonicalURL(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw LocalGitError.invalidPath }
        var components = Array(url.pathComponents.dropFirst())
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        var links = 0
        while !components.isEmpty {
            let component = components.removeFirst()
            if component == "." { continue }
            if component == ".." { current.deleteLastPathComponent(); continue }
            let candidate = current.appendingPathComponent(component)
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path) {
                links += 1
                guard links <= 40 else { throw LocalGitError.invalidPath }
                let target = destination.hasPrefix("/") ? URL(fileURLWithPath: destination) : current.appendingPathComponent(destination)
                components = Array(target.pathComponents.dropFirst()) + components
                current = URL(fileURLWithPath: "/", isDirectory: true)
            } else { current = candidate }
        }
        return current
    }
    public static func requireAuthorized(_ target: URL, roots: [URL]) throws {
        let canonical = try canonicalURL(target)
        let grants = try roots.map { try canonicalURL($0).path }
        guard grants.contains(where: { canonical.path == $0 || canonical.path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) else {
            throw LocalGitError.authorizationRequired(canonical)
        }
    }
}
