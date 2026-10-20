import Foundation

public enum DeviceFlowState: Equatable, Sendable {
    case awaitingUser(code: String, verificationURL: URL), polling(nextAttemptAt: Date), authorized(accountID: String), cancelled, expired, failed(message: String)
}
public struct GitHubCredential: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let refreshExpiresAt: Date?
    public let scopes: Set<String>
    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, refreshExpiresAt: Date? = nil, scopes: Set<String> = []) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt; self.refreshExpiresAt = refreshExpiresAt; self.scopes = scopes
    }
}
public protocol DeviceFlowClock: Sendable {
    func elapsed() async -> TimeInterval
    func date() async -> Date
    func sleep(seconds: TimeInterval) async throws
}
public struct SystemDeviceFlowClock: DeviceFlowClock {
    public init() {}
    public func elapsed() async -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func date() async -> Date { Date() }
    /// Clamped before Duration conversion: a non-finite or huge value would trap on Int128 overflow.
    public func sleep(seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(DeviceFlowClient.boundedSeconds(seconds, maximum: 86_400))) }
}
public struct AuthorizedGitHubAccount: Sendable {
    public let scope: AccountScope
    public let login: String
    public let credential: GitHubCredential
    public init(scope: AccountScope, login: String, credential: GitHubCredential) {
        self.scope = scope; self.login = login; self.credential = credential
    }
}
public enum DeviceFlowFailure: Error, Sendable { case cancelled, expired, rejected(String), invalidResponse }

public actor DeviceFlowClient {
    public static let requestedScopes: Set<String> = ["repo", "read:org", "read:user", "notifications"]
    private let clientID: String
    private let transport: any GitHubTransport
    private let clock: any DeviceFlowClock
    private var generation = UUID()
    private var worker: Task<AuthorizedGitHubAccount, Error>?
    public init(clientID: String, transport: any GitHubTransport, clock: any DeviceFlowClock = SystemDeviceFlowClock()) {
        self.clientID = clientID; self.transport = transport; self.clock = clock
    }
    public func cancel() { generation = UUID(); worker?.cancel() }
    static let maximumInterval: TimeInterval = 900
    static let maximumExpiry: TimeInterval = 3_600
    static func boundedSeconds(_ value: TimeInterval, maximum: TimeInterval) -> TimeInterval {
        value.isFinite ? min(maximum, max(0, value)) : maximum
    }

    public func authorize(onState: @escaping @Sendable (DeviceFlowState) async -> Void) async throws -> AuthorizedGitHubAccount {
        worker?.cancel()
        let sessionID = UUID(); generation = sessionID
        let task = Task { try await self.run(sessionID:sessionID, onState:onState) }
        worker = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }
    private func run(sessionID: UUID, onState: @escaping @Sendable (DeviceFlowState) async -> Void) async throws -> AuthorizedGitHubAccount {
        func check() throws { try Task.checkCancellation(); guard generation == sessionID else { throw DeviceFlowFailure.cancelled } }
        do {
            guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DeviceFlowFailure.rejected("Configure your GitHub OAuth App client ID before connecting.") }
            let started = await clock.elapsed()
            let response = try await form("https://github.com/login/device/code", parameters: ["client_id":clientID, "scope":Self.requestedScopes.sorted().joined(separator:" ")])
            try check()
            let challenge = try decode(DeviceChallenge.self, response: response)
            guard challenge.interval.isFinite, challenge.expires_in.isFinite, challenge.interval > 0, challenge.expires_in > 0,
                  let url = URL(string:challenge.verification_uri), url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil, (url.port ?? 443) == 443 else { throw DeviceFlowFailure.invalidResponse }
            // Provider values are untrusted: clamp to device-code lifetimes before any Duration conversion.
            let expires = started + Self.boundedSeconds(challenge.expires_in, maximum: Self.maximumExpiry)
            var interval = Self.boundedSeconds(challenge.interval, maximum: Self.maximumInterval)
            await onState(.awaitingUser(code:challenge.user_code, verificationURL:url))
            while true {
                try check()
                let remaining = expires - (await clock.elapsed())
                guard remaining > 0 else { throw DeviceFlowFailure.expired }
                await onState(.polling(nextAttemptAt: (await clock.date()).addingTimeInterval(interval)))
                try check()
                try await clock.sleep(seconds:min(interval, remaining))
                try check()
                guard await clock.elapsed() < expires else { throw DeviceFlowFailure.expired }
                let tokenResponse = try await form("https://github.com/login/oauth/access_token", parameters:["client_id":clientID, "device_code":challenge.device_code, "grant_type":"urn:ietf:params:oauth:grant-type:device_code"])
                try check()
                if let error = try? JSONDecoder().decode(OAuthError.self, from:tokenResponse.data) {
                    if error.error == "authorization_pending" { continue }
                    if error.error == "slow_down" { interval = Self.boundedSeconds(max(interval + 5, error.interval ?? 0), maximum: Self.maximumInterval); continue }
                    throw oauthFailure(error.error)
                }
                let credential = try await credential(from: tokenResponse)
                try check()
                let http = GitHubHTTPClient(transport:transport)
                let identityResponse = try await http.get(URL(string:"https://api.github.com/user")!, token:credential.accessToken)
                try check()
                let identity = try JSONDecoder().decode(Identity.self, from:identityResponse.data)
                let account = AuthorizedGitHubAccount(scope: AccountScope(host:"github.com", accountID:String(identity.id)), login:identity.login, credential:credential)
                await onState(.authorized(accountID:account.scope.accountID))
                try check()
                return account
            }
        } catch {
            if error is CancellationError || generation != sessionID || (error as? DeviceFlowFailure)?.isCancelled == true {
                await onState(.cancelled); throw DeviceFlowFailure.cancelled
            }
            if (error as? DeviceFlowFailure)?.isExpired == true { await onState(.expired) }
            else if case .rejected(let message) = error as? DeviceFlowFailure { await onState(.failed(message:message)) }
            else { await onState(.failed(message:"GitHub connection failed. Check your connection and try again.")) }
            throw error
        }
    }
    public func refresh(_ credential: GitHubCredential) async throws -> GitHubCredential {
        let now = await clock.date()
        guard let refreshToken = credential.refreshToken, credential.refreshExpiresAt.map({ $0 > now }) ?? true else { throw GitHubFailure.invalidAuthentication }
        let response = try await form("https://github.com/login/oauth/access_token", parameters:["client_id":clientID, "grant_type":"refresh_token", "refresh_token":refreshToken])
        try Task.checkCancellation()
        if response.status == 401 { throw GitHubFailure.invalidAuthentication }
        if let error = try? JSONDecoder().decode(OAuthError.self,from:response.data) {
            if ["bad_refresh_token", "invalid_grant", "expired_token", "token_expired"].contains(error.error) { throw GitHubFailure.invalidAuthentication }
            throw GitHubFailure.invalidResponse
        }
        let refreshed: GitHubCredential
        do { refreshed = try await self.credential(from:response) }
        catch { throw GitHubFailure.invalidResponse }
        // Refresh responses may omit scope; retain the originally confirmed grant.
        return GitHubCredential(accessToken:refreshed.accessToken, refreshToken:refreshed.refreshToken, expiresAt:refreshed.expiresAt,
                                refreshExpiresAt:refreshed.refreshExpiresAt, scopes:refreshed.scopes.isEmpty ? credential.scopes : refreshed.scopes)
    }
    private func credential(from response: GitHubResponse) async throws -> GitHubCredential {
        let payload = try decode(TokenPayload.self, response:response)
        guard payload.token_type.lowercased() == "bearer", !payload.access_token.isEmpty else { throw DeviceFlowFailure.invalidResponse }
        let now = await clock.date()
        return GitHubCredential(accessToken:payload.access_token, refreshToken:payload.refresh_token, expiresAt:payload.expires_in.map { now.addingTimeInterval($0) },
                                refreshExpiresAt:payload.refresh_token_expires_in.map { now.addingTimeInterval($0) }, scopes:Set((payload.scope ?? "").split(whereSeparator:{ $0 == "," || $0 == " " }).map(String.init)))
    }
    private func decode<T: Decodable>(_ type: T.Type, response: GitHubResponse) throws -> T {
        if let error = try? JSONDecoder().decode(OAuthError.self, from:response.data) { throw oauthFailure(error.error) }
        guard (200..<300).contains(response.status) else { throw DeviceFlowFailure.invalidResponse }
        return try JSONDecoder().decode(type, from:response.data)
    }
    private func oauthFailure(_ code: String) -> DeviceFlowFailure {
        switch code {
        case "expired_token", "token_expired": .expired
        case "access_denied": .rejected("GitHub authorization was denied.")
        case "device_flow_disabled": .rejected("Enable device flow in your GitHub OAuth App settings.")
        case "incorrect_client_credentials": .rejected("Check your GitHub OAuth App client ID.")
        case "invalid_grant", "bad_refresh_token": .rejected("Your GitHub session expired. Connect your account again.")
        default: .rejected("GitHub authorization could not complete. Start a new connection.")
        }
    }
    private func form(_ endpoint: String, parameters: [String:String]) async throws -> GitHubResponse {
        let allowed = CharacterSet(charactersIn:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = parameters.sorted(by:{ $0.key < $1.key }).map { key, value in
            key.addingPercentEncoding(withAllowedCharacters:allowed)! + "=" + value.addingPercentEncoding(withAllowedCharacters:allowed)!
        }.joined(separator:"&")
        var request = URLRequest(url:URL(string:endpoint)!)
        request.httpMethod = "POST"; request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField:"Content-Type")
        request.setValue("application/json", forHTTPHeaderField:"Accept")
        // Redirects are never followed for OAuth forms containing private codes/tokens.
        return try await transport.send(request)
    }
}
private struct DeviceChallenge: Decodable { let device_code: String; let user_code: String; let verification_uri: String; let expires_in: Double; let interval: Double }
private struct OAuthError: Decodable { let error: String; let interval: Double? }
private struct TokenPayload: Decodable {
    let access_token: String; let token_type: String; let scope: String?; let expires_in: Double?; let refresh_token: String?; let refresh_token_expires_in: Double?
}
private struct Identity: Decodable { let id: Int64; let login: String }
private extension DeviceFlowFailure {
    var isCancelled: Bool { if case .cancelled = self { true } else { false } }
    var isExpired: Bool { if case .expired = self { true } else { false } }
}
