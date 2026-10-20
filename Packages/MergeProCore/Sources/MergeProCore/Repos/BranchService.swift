import Foundation

public enum BranchService {
    /// `git check-ref-format --branch` rules (plus `HEAD`, which git refuses as a branch name).
    /// Every accepted name is also a browsable ref, so a branch created here can always be opened.
    public static func validName(_ name:String) -> Bool {
        guard !name.isEmpty,name != "@",name != "HEAD",!name.hasPrefix("-"),!name.hasPrefix("/"),!name.hasSuffix("/"),!name.hasSuffix("."),!name.contains(".."),!name.contains("@{"),!name.contains("//"),!name.contains(where:{ $0.isWhitespace || $0.isNewline || $0.asciiValue.map { $0<32 || $0==127 } == true || "~^:?*[\\".contains($0) }) else { return false }
        return name.split(separator:"/").allSatisfy { !$0.hasPrefix(".") && !$0.hasSuffix(".lock") } && (try? GitHubRepoReader.refComponent(name)) != nil
    }
    public static func validateDeletion(_ branch:RepositoryBranch,defaultBranch:String) throws {
        guard branch.name != defaultBranch else { throw RepositoryBrowserFailure.defaultBranch }
        guard !branch.protected else { throw RepositoryBrowserFailure.protectedBranch }
        guard validName(branch.name) else { throw RepositoryBrowserFailure.invalidRef }
    }
}

public enum RepositoryBranchMutation:Equatable,Sendable,Identifiable {
    case create(name:String,sha:String)
    case delete(name:String,sha:String)
    public var name:String { switch self { case .create(let name,_),.delete(let name,_):name } }
    public var sha:String { switch self { case .create(_,let sha),.delete(_,let sha):sha } }
    public var id:String { description+"|"+sha }
    public var description:String { switch self { case .create:"create "+name;case .delete:"delete "+name } }
    func identity(repository:RepositoryKey) -> String { switch self { case .create:"branch-create|"+repository.repositoryID+"|"+name;case .delete:"branch-delete|"+repository.repositoryID+"|"+name+"|"+sha } }
}
public enum RepositoryBranchReconciliation:Equatable,Sendable { case applied,notApplied }
