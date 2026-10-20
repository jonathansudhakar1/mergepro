import Foundation

public struct RiskEvidence: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case sensitivePath, dependency, sourceWithoutTests, possibleSecret, unusuallyLarge, unviewed }
    public let kind: Kind
    public let path: String?
    public let line: Int?
    public var id: String { kind.rawValue+":"+(path ?? "")+":"+String(line ?? 0) }
    public var title: String {
        switch kind { case .sensitivePath:"Sensitive path";case .dependency:"Dependencies changed";case .sourceWithoutTests:"Source changes without test changes";case .possibleSecret:"Possible credential in added line";case .unusuallyLarge:"Larger than repository baseline";case .unviewed:"File not yet viewed" }
    }
}
public enum RiskRules {
    /// Evidence contains locations only. Possible secret values never leave the scanner.
    public static func evaluate(files:[DiffFile],viewed:Set<String>,usualSize:Int?,sensitivePaths:[String] = []) -> [RiskEvidence] {
        var result:[RiskEvidence]=[]
        let paths=files.map { $0.path.lowercased() }
        for file in files {
            let path=file.path.lowercased();let name=URL(fileURLWithPath:path).lastPathComponent
            func add(_ kind:RiskEvidence.Kind,_ line:Int? = nil) { result.append(RiskEvidence(kind:kind,path:file.path,line:line)) }
            if [".github/workflows/","infra/","terraform/","migrations/","auth/"].contains(where:path.contains) || name == "codeowners" || path.hasSuffix(".tf") || file.collapsedByDefault && name.contains("lock") || sensitivePaths.contains(where:{ path.hasPrefix($0.lowercased()) }) { add(.sensitivePath) }
            if ["package.json","package-lock.json","package.swift","package.resolved","requirements.txt","pyproject.toml","go.mod","cargo.toml","cargo.lock","gemfile","gemfile.lock"].contains(name) || name.hasSuffix(".lock") { add(.dependency) }
            if !viewed.contains(file.path) { add(.unviewed) }
            for line in file.lines where line.kind == .added {
                let t=line.text.lowercased()
                // AWS access key IDs are uppercase `AKIA` + 16 characters; lowercased matching flagged prose such as "Slovakia".
                if ["-----begin private key", "-----begin rsa private key", "ghp_", "github_pat_"].contains(where:t.contains) || line.text.contains("AKIA") && line.text.range(of:"AKIA[0-9A-Z]{16}",options:.regularExpression) != nil || (t.contains("secret") || t.contains("password") || t.contains("api_key")) && t.contains("=") && t.count > 20 { add(.possibleSecret,line.newLine) }
            }
        }
        let source=paths.contains { ["swift","js","jsx","ts","tsx","py","go","rs","java","c","cpp"].contains(URL(fileURLWithPath:$0).pathExtension) }
        if source && !paths.contains(where:{ $0.contains("test") || $0.contains("spec") }) { result.append(.init(kind:.sourceWithoutTests,path:nil,line:nil)) }
        if let usualSize,files.reduce(0,{ $0+$1.additions+$1.deletions }) > max(usualSize*2,500) { result.append(.init(kind:.unusuallyLarge,path:nil,line:nil)) }
        return result
    }
}
