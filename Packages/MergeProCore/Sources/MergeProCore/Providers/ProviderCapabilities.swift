public struct ProviderCapabilities: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let readPullRequests = Self(rawValue: 1 << 0)
    public static let review = Self(rawValue: 1 << 1)
    public static let merge = Self(rawValue: 1 << 2)
    public static let readWorkflows = Self(rawValue: 1 << 3)
    public static let runWorkflows = Self(rawValue: 1 << 4)
}
