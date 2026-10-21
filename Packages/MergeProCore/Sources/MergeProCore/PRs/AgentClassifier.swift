import Foundation

/// Extra signals a user adds for their own agents or team conventions (Settings ▸ Code), applied to every account.
public struct AgentPatterns: Codable, Equatable, Sendable {
    /// Head branch prefixes such as `ai/` or `bot/`.
    public var branchPrefixes: [String]
    /// Label names such as `written-by-ai`.
    public var labels: [String]
    public init(branchPrefixes: [String] = [], labels: [String] = []) { self.branchPrefixes = branchPrefixes; self.labels = labels }
    public var isEmpty: Bool { branchPrefixes.isEmpty && labels.isEmpty }
}

public enum AgentClassifier {
    public enum Classification: String, Codable, Sendable { case agent, automation, human, unknown }

    /// Accounts coding agents open pull requests from.
    static let agentLogins: Set<String> = [
        "copilot", "copilot[bot]", "copilot-swe-agent[bot]", "claude[bot]", "codex[bot]", "chatgpt-codex-connector[bot]",
        "devin-ai-integration[bot]", "cursor[bot]", "google-labs-jules[bot]",
    ]
    /// Head branch prefixes agents create.
    static let agentBranchPrefixes = ["copilot/", "codex/", "claude/", "devin/", "cursor/"]
    /// Labels marking AI-written pull requests; any `agent:` label counts too.
    static let agentLabels: Set<String> = ["ai-generated", "ai-authored", "llm-generated"]
    /// Names (first word) and addresses agents sign `Co-authored-by:` trailers with.
    static let coauthorNames: Set<String> = ["claude", "copilot", "codex", "cursor", "devin", "jules"]
    static let coauthorAddresses = ["noreply@anthropic.com", "cursoragent@cursor.com", "devin-ai-integration[bot]"]
    /// Phrases and links agents leave in a pull request body.
    static let bodyMarkers = ["generated with [claude code]", "generated with claude code", "🤖 generated with", "chatgpt.com/codex/tasks/", "app.devin.ai/sessions/"]

    /// The `Co-authored-by:` trailers of a commit message, as `Name <email>`.
    public static func coauthors(inCommitMessage message: String) -> [String] {
        var result: [String] = []
        for line in message.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.lowercased().hasPrefix("co-authored-by:") else { continue }
            let value = String(text.dropFirst("co-authored-by:".count)).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { result.append(String(value.prefix(200))) }
            if result.count == 10 { break }
        }
        return result
    }
    static func isAgentCoauthor(_ trailer: String) -> Bool {
        let value = trailer.lowercased()
        let name = value.split(whereSeparator: { $0 == " " || $0 == "<" }).first.map(String.init) ?? ""
        return coauthorNames.contains(name) || coauthorAddresses.contains { value.contains($0) }
    }
    static func hasBodyMarker(_ body: String) -> Bool {
        let value = body.lowercased()
        return bodyMarkers.contains { value.contains($0) }
    }

    /// Exact, user-maintained overrides take precedence. Bot identity alone does not imply AI: Dependabot and other
    /// bots are automation unless they are known coding agents.
    public static func classify(login: String?, actorType: String?, manual: [String: Classification] = [:], branch: String = "",
                                labels: [String] = [], coauthors: [String] = [], body: String = "", custom: AgentPatterns = .init()) -> Classification {
        guard let login = login?.lowercased() else { return .unknown }
        if let value = manual.first(where: { $0.key.lowercased() == login })?.value { return value }
        let branch = branch.lowercased(), labels = labels.map { $0.lowercased() }
        let prefixes = agentBranchPrefixes + custom.branchPrefixes.map { $0.lowercased() }.filter { !$0.isEmpty }
        let markedLabels = agentLabels.union(custom.labels.map { $0.lowercased() })
        if prefixes.contains(where: branch.hasPrefix)
            || labels.contains(where: { markedLabels.contains($0) || $0.hasPrefix("agent:") })
            || coauthors.contains(where: isAgentCoauthor)
            || hasBodyMarker(body) { return .agent }
        if agentLogins.contains(login) { return .agent }
        if actorType?.lowercased() == "bot" || login.hasSuffix("[bot]") { return .automation }
        if actorType?.lowercased() == "user" { return .human }
        return .unknown
    }

    /// Classifies stored pull request metadata with every signal it carries.
    public static func classify(_ metadata: PRMetadata, manual: [String: Classification] = [:], custom: AgentPatterns = .init()) -> Classification {
        classify(login: metadata.authorLogin, actorType: metadata.actorType, manual: manual, branch: metadata.headBranch,
                 labels: metadata.labels, coauthors: metadata.coauthors ?? [],
                 body: (metadata.descriptionPreview ?? "") + "\n" + (metadata.bodyTail ?? ""), custom: custom)
    }
}
