import Foundation

public struct PRNavigationVisit: Equatable, Codable, Sendable {
  public var key: ProviderKey
  public var opens: Int
  public var lastOpenedAt: Date
}
public struct PRGlobalShortcut: Equatable, Codable, Sendable {
  public var key: String
  public var command: Bool
  public var control: Bool
  public var option: Bool
  public var shift: Bool
  public var enabled: Bool
  public init(
    key: String, command: Bool = false, control: Bool = true, option: Bool = false,
    shift: Bool = false, enabled: Bool = true
  ) {
    self.key = key
    self.command = command
    self.control = control
    self.option = option
    self.shift = shift
    self.enabled = enabled
  }
}
public struct PRGlobalShortcuts: Equatable, Codable, Sendable {
  public var palette = PRGlobalShortcut(key: "k", command: true)
  public var menuBar = PRGlobalShortcut(key: "g", option: true)
  public init() {}
}

public enum PRRouteResolution: Equatable, Sendable {
  case native(ProviderKey)
  case chooseAccount([ProviderKey])
  case web(URL)
  case unavailable
}
extension ProviderKey {
  public var routeURL: URL {
    var parts = URLComponents()
    parts.scheme = "mergepro"
    parts.host = "pull"
    parts.queryItems = [
      URLQueryItem(name: "host", value: host), URLQueryItem(name: "account", value: accountID),
      URLQueryItem(name: "repository", value: repositoryID),
      URLQueryItem(name: "object", value: objectID),
    ]
    return parts.url!
  }
}
public enum PRRouteResolver {
  public static func resolve(_ url: URL, cached: [PullRequest], activeAccount: AccountScope?)
    -> PRRouteResolution
  {
    if url.scheme == "mergepro", url.host == "pull",
      let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    {
      let fields = parts.queryItems ?? []
      func field(_ name: String) -> String? {
        let items = fields.filter { $0.name == name }
        return items.count == 1 ? items[0].value : nil
      }
      guard let host = field("host"), let account = field("account"),
        let repository = field("repository"), let object = field("object")
      else { return .unavailable }
      let key = ProviderKey(
        host: host, accountID: account, repositoryID: repository, objectID: object)
      return cached.contains(where: { $0.key == key }) ? .native(key) : .unavailable
    }
    guard url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil,
      url.password == nil
    else { return .unavailable }
    let candidates = cached.filter { $0.metadata?.webURL == url }.map(\.key).sorted {
      [$0.host, $0.accountID, $0.repositoryID, $0.objectID].lexicographicallyPrecedes([
        $1.host, $1.accountID, $1.repositoryID, $1.objectID,
      ])
    }
    if let activeAccount, let key = candidates.first(where: { $0.account == activeAccount }) {
      return .native(key)
    }
    if candidates.count == 1 { return .native(candidates[0]) }
    if candidates.count > 1 { return .chooseAccount(candidates) }
    return .web(url)
  }
}
