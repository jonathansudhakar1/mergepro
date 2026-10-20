import Foundation

public struct LocalCommitDraft: Equatable, Codable, Sendable {
    public var subject: String
    public var body: String
    public var amend: Bool
    public init(subject: String = "", body: String = "", amend: Bool = false) {
        self.subject = subject; self.body = body; self.amend = amend
    }
}

@MainActor public final class LocalCommitDraftStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load(directory: URL) -> LocalCommitDraft {
        guard let data = defaults.data(forKey: key(directory)), let draft = try? JSONDecoder().decode(LocalCommitDraft.self, from: data) else { return .init() }
        return draft
    }
    public func save(_ draft: LocalCommitDraft, directory: URL) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: key(directory))
    }
    public func clear(directory: URL) { defaults.removeObject(forKey: key(directory)) }
    // A literal, reversible key avoids collisions and never resolves or accesses the directory.
    private func key(_ directory: URL) -> String {
        "localCommitDraft." + Data(directory.standardizedFileURL.path.utf8).base64EncodedString()
    }
}
