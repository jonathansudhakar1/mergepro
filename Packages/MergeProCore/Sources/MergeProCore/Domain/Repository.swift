public struct Repository: Equatable, Codable, Sendable {
    public let key: RepositoryKey
    public let name: String
    public let isPrivate: Bool
    public let capabilities: ProviderCapabilities
    public init(key: RepositoryKey, name: String, isPrivate: Bool, capabilities: ProviderCapabilities) {
        self.key = key; self.name = name; self.isPrivate = isPrivate; self.capabilities = capabilities
    }
}
