import Foundation
public enum AgentClassifier {
    public enum Classification: String, Codable, Sendable { case agent, automation, human, unknown }
    /// Exact, user-maintained overrides take precedence. Bot identity alone does not imply AI.
    public static func classify(login:String?,actorType:String?,manual:[String:Classification] = [:],branch:String = "",labels:[String] = [],coauthors:[String] = []) -> Classification {
        guard let login=login?.lowercased() else { return .unknown }
        if let value=manual.first(where:{ $0.key.lowercased() == login })?.value { return value }
        if ["copilot/","codex/","claude/","devin/"].contains(where:branch.lowercased().hasPrefix) || labels.contains(where:{ ["agent:copilot","agent:codex","agent:claude","ai-generated"].contains($0.lowercased()) }) || coauthors.contains(where:{ trailer in ["copilot","codex","claude"].contains { trailer.lowercased().hasPrefix($0+" ") } }) { return .agent }
        if ["copilot","copilot[bot]","claude[bot]","codex[bot]","devin-ai-integration[bot]"].contains(login) { return .agent }
        if actorType?.lowercased() == "bot" || login.hasSuffix("[bot]") { return .automation }
        if actorType?.lowercased() == "user" { return .human }
        return .unknown
    }
}
