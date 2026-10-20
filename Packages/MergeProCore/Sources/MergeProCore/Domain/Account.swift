public struct Account: Equatable, Codable, Sendable {
    public let scope: AccountScope
    public let login: String
    /// Keychain lookup reference only; never an access token.
    public let tokenReference: String?
    public init(scope: AccountScope, login: String, tokenReference: String? = nil) {
        self.scope = scope; self.login = login; self.tokenReference = tokenReference
    }
}
