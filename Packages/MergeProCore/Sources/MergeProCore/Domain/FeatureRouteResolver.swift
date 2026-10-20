import Foundation

public enum FeatureRouteResolution:Equatable,Sendable {
    case repository(RepositoryKey,ref:String?,path:String?,section:String,line:Int?)
    case actions(repository:RepositoryKey,runID:Int64?)
    case chooseAccount([RepositoryKey])
    case web(URL)
    case unavailable
}

/// Resolve only provider paths whose scoped identity and ref boundary are known.
public enum FeatureRouteResolver {
    public static func resolve(_ url:URL,repositories:[Repository],activeAccount:AccountScope?,refs:[RepositoryKey:Set<String>] = [:]) -> FeatureRouteResolution {
        guard url.scheme == "https",url.host?.lowercased() == "github.com",url.user == nil,url.password == nil,url.port == nil else { return .web(url) }
        let components = url.path.split(separator:"/",omittingEmptySubsequences:true).map(String.init)
        guard components.count >= 2,!components.contains(where:{ $0 == "." || $0 == ".." || $0.contains("\0") || $0.contains("\\") }) else { return .web(url) }
        let name = components.prefix(2).joined(separator:"/")
        let candidates = repositories.filter { $0.key.account.host == "github.com" && $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.key).sorted { ($0.account.accountID,$0.repositoryID) < ($1.account.accountID,$1.repositoryID) }
        guard !candidates.isEmpty else { return .web(url) }
        let key:RepositoryKey
        if let activeAccount {
            guard let scoped = candidates.first(where:{ $0.account == activeAccount }) else { return .unavailable }
            key = scoped
        } else if candidates.count > 1 { return .chooseAccount(candidates) }
        else { key = candidates[0] }
        if components.count == 2 { return .repository(key,ref:nil,path:nil,section:"code",line:nil) }
        switch components[2] {
        case "actions":
            if components.count == 3 { return .actions(repository:key,runID:nil) }
            if components.count == 5,components[3] == "runs",let id = Int64(components[4]),id > 0 { return .actions(repository:key,runID:id) }
        case "releases":return .repository(key,ref:nil,path:nil,section:"releases",line:nil)
        case "branches","tags":return .repository(key,ref:nil,path:nil,section:"branches",line:nil)
        case "commits":return .repository(key,ref:nil,path:nil,section:"history",line:nil)
        case "pulls":return .repository(key,ref:nil,path:nil,section:"pullRequests",line:nil)
        case "blob","tree":
            guard components.count >= 4 else { return .web(url) }
            let suffix = components.dropFirst(3).joined(separator:"/")
            let known = (refs[key] ?? []).filter { suffix == $0 || suffix.hasPrefix($0+"/") }.sorted { $0.count > $1.count }
            let token = components[3]
            let immutable = token.count == 40 && token.allSatisfy(\.isHexDigit)
            guard let ref = known.first ?? (immutable ? token : nil) else { return .web(url) }
            let path = suffix == ref ? nil : String(suffix.dropFirst(ref.count+1))
            let line = url.fragment.flatMap { fragment -> Int? in
                guard fragment.hasPrefix("L"),let n = Int(fragment.dropFirst().split(separator:"-").first ?? ""),n > 0 else { return nil }
                return n
            }
            return .repository(key,ref:ref,path:path,section:"code",line:line)
        default:break
        }
        return .web(url)
    }
}
