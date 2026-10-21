import Foundation

/// Account/resource quota is separate from account-wide secondary throttling and pacing.
public actor RateBudget {
    public enum Resource: String, Sendable { case rest, graphql }
    public enum Priority: Sendable { case background, interactive }
    private struct Key: Hashable { let account: AccountScope; let resource: Resource }
    private struct Quota { var remaining: Int; var reset: Date }
    private var quotas: [Key:Quota] = [:]
    private var notBefore: [AccountScope:Date] = [:]
    private var nextRequest: [AccountScope:ContinuousClock.Instant] = [:]
    private var lastBackgroundStart: [AccountScope:ContinuousClock.Instant] = [:]
    private var lastWrite: [AccountScope:ContinuousClock.Instant] = [:]
    private var interactiveHold: [AccountScope:ContinuousClock.Instant] = [:]
    private var pollIntervals: [AccountScope:TimeInterval] = [:]
    /// Points the last GraphQL query of each account cost (REST requests cost 1).
    private var lastCost: [Key:Int] = [:]
    /// When the last background request of each account/resource was scheduled, for `quotaSpacing`.
    private var lastQuotaStart: [Key:ContinuousClock.Instant] = [:]
    private struct PollKey: Hashable { let account: AccountScope; let feature: String }
    private var lastPoll: [PollKey:ContinuousClock.Instant] = [:]
    private var nextProviderPoll: [PollKey:ContinuousClock.Instant] = [:]
    private struct RequestWaiter { let id: UUID; let priority:Priority;let continuation: CheckedContinuation<Bool,Error> }
    private var requesting: Set<AccountScope> = []
    private var requestWaiters: [AccountScope:[RequestWaiter]] = [:]
    /// Tasks sleeping off pacing, per account; see `waiters(account:)`.
    private var pacing: [AccountScope:Int] = [:]
    private var waiterObservers: [(account: AccountScope, minimum: Waiters, continuation: CheckedContinuation<Void,Never>)] = []
    private var secondaryFailures: [AccountScope:Int] = [:]
    /// Gap between user writes (mutations).
    private let minimumSpacing: Duration
    /// Gap between background (polling) request starts. Background requests are reads; they still go out
    /// one at a time per account, behind any interactive request.
    private let backgroundSpacing: Duration
    private let interactiveReserve: Int
    private let interactiveGrace: Duration
    /// `interactiveGrace` briefly holds background work after an interactive request so a user's chained
    /// reads (detail, files, checks) stay contiguous; it defaults to min(spacing, 200 ms).
    /// `backgroundReadSpacing` defaults to min(spacing, 250 ms): a cycle's many cheap (often conditional) reads
    /// fit its deadline, while writes keep the full `minimumSpacing`.
    /// Whether background reads are spread over the remaining hourly quota (`quotaSpacing`).
    private let pacesQuota: Bool
    public init(minimumSpacing: Duration = .seconds(1), backgroundReadSpacing: Duration? = nil, interactiveReserve: Int = 100, interactiveGrace: Duration? = nil, pacesQuota: Bool = true) {
        self.minimumSpacing = max(.zero,minimumSpacing); self.interactiveReserve = max(0,interactiveReserve); self.pacesQuota = pacesQuota
        backgroundSpacing = max(.zero,backgroundReadSpacing ?? min(max(.zero,minimumSpacing),.milliseconds(250)))
        self.interactiveGrace = max(.zero,interactiveGrace ?? min(max(.zero,minimumSpacing),.milliseconds(200)))
    }
    /// One provider request in flight per account. Interactive waiters take the next free slot ahead of
    /// queued background work; background pacing is slept off before this call, never while holding the slot.
    public func beginRequest(account: AccountScope, priority:Priority = .background) async throws {
        var waited = false
        while true {
            try Task.checkCancellation()
            if priority == .background, let due = backgroundDue(account) {
                waited = true; try await pace(account:account, until:due); continue
            }
            if requesting.insert(account).inserted { started(account,priority:priority,waited:waited); return }
            waited = true
            let id = UUID()
            let granted = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool,Error>) in
                    if Task.isCancelled { continuation.resume(throwing:CancellationError()) }
                    else {
                        let waiter=RequestWaiter(id:id,priority:priority,continuation:continuation)
                        if priority == .interactive {
                            let index=requestWaiters[account,default:[]].firstIndex { $0.priority == .background } ?? requestWaiters[account,default:[]].count
                            requestWaiters[account,default:[]].insert(waiter,at:index)
                        } else { requestWaiters[account,default:[]].append(waiter) }
                        waitersChanged(account)
                    }
                }
            } onCancel: { Task { await self.cancelWaitingRequest(account:account,id:id) } }
            if granted { started(account,priority:priority,waited:waited); return }
        }
    }
    /// Actual starts constrain subsequent admission; a delayed request also advances future reservations.
    private func started(_ account: AccountScope, priority: Priority, waited: Bool) {
        guard priority == .background else { return }
        let now = ContinuousClock.now
        lastBackgroundStart[account] = now
        guard waited else { return }
        nextRequest[account] = max(nextRequest[account] ?? now,now.advanced(by:backgroundSpacing))
    }
    private func backgroundDue(_ account: AccountScope) -> ContinuousClock.Instant? {
        let now = ContinuousClock.now
        let due = max(interactiveHold[account] ?? now,lastBackgroundStart[account].map { $0.advanced(by:backgroundSpacing) } ?? now)
        return due > now ? due : nil
    }
    private func cancelWaitingRequest(account: AccountScope, id: UUID) {
        guard let index = requestWaiters[account]?.firstIndex(where:{ $0.id == id }) else { return }
        requestWaiters[account]?.remove(at:index).continuation.resume(throwing:CancellationError())
    }
    public func endRequest(account: AccountScope, priority:Priority = .background) {
        if priority == .interactive, interactiveGrace > .zero { interactiveHold[account] = ContinuousClock.now.advanced(by:interactiveGrace) }
        guard var waiters = requestWaiters[account], !waiters.isEmpty else { requesting.remove(account); requestWaiters[account] = nil; return }
        if waiters[0].priority == .background, backgroundDue(account) != nil {
            // Interactive waiters always sort first, so all of these are background: free the slot and
            // let them re-admit after pacing/grace (an interactive arrival can take it immediately).
            requesting.remove(account); requestWaiters[account] = nil
            for waiter in waiters { waiter.continuation.resume(returning:false) }
            return
        }
        let first = waiters.removeFirst(); requestWaiters[account] = waiters.isEmpty ? nil : waiters
        first.continuation.resume(returning:true)
    }
    public func acquire(account: AccountScope, resource: Resource, priority: Priority, cost: Int = 1, interactiveRead:Bool = false, reservingQuota:Bool = true) async throws {
        try Task.checkCancellation()
        try checkQuota(account:account,resource:resource,priority:priority,cost:cost,reserve:reservingQuota)
        // Reserve the next start before suspension: concurrent pages/consumers cannot overlap slots.
        // Interactive reads skip pacing; user writes keep `minimumSpacing` between mutations only; background
        // reads keep `backgroundSpacing` between starts.
        let instant = ContinuousClock.now, start: ContinuousClock.Instant
        if interactiveRead { start = instant }
        else if priority == .interactive { start = max(instant,lastWrite[account].map { $0.advanced(by:minimumSpacing) } ?? instant) }
        else {
            let key = Key(account:account,resource:resource)
            let quotaDue = lastQuotaStart[key].map { $0.advanced(by:quotaSpacing(key)) } ?? instant
            start = max(instant,nextRequest[account] ?? instant,quotaDue); nextRequest[account] = start.advanced(by:backgroundSpacing)
            lastQuotaStart[key] = start
        }
        if start > instant { try await pace(account:account, until:start) }
        try Task.checkCancellation()
        try checkBackoff(account:account)
    }
    /// Queued requests only check quota during pacing; charge the newest observed quota at the send.
    func checkQuota(account:AccountScope,resource:Resource,priority:Priority,cost:Int,reserve:Bool) throws {
        let now = Date(); let key = Key(account:account,resource:resource)
        if let until = notBefore[account], until > now { throw GitHubFailure.rateLimited(until:until) }
        if var quota = quotas[key] {
            if quota.reset <= now { quotas[key] = nil }
            else {
                let requiredReserve = priority == .background ? interactiveReserve : 0
                guard cost > 0, quota.remaining - cost >= requiredReserve else { throw GitHubFailure.rateLimited(until:quota.reset) }
                if reserve { quota.remaining -= cost; quotas[key] = quota }
            }
        }
    }
    /// Background reads spread what remains of the hourly quota (above the interactive reserve) evenly until
    /// it resets, so an account with many repositories syncs steadily instead of exhausting the quota and
    /// pausing until the reset. Only a reset inside GitHub's one-hour window paces.
    func quotaSpacing(account: AccountScope, resource: Resource) -> Duration { quotaSpacing(Key(account:account,resource:resource)) }
    private func quotaSpacing(_ key: Key) -> Duration {
        guard pacesQuota, let quota = quotas[key] else { return .zero }
        let window = quota.reset.timeIntervalSinceNow, spendable = quota.remaining - interactiveReserve
        guard window > 0, window <= 3700, spendable > 0 else { return .zero }
        let seconds = window * Double(max(1,lastCost[key] ?? 1)) / Double(spendable)
        return .milliseconds(Int(min(60,seconds) * 1000))
    }
    func checkBackoff(account: AccountScope) throws {
        if let until = notBefore[account], until > Date() { throw GitHubFailure.rateLimited(until:until) }
    }
    func recordWrite(account: AccountScope) { lastWrite[account] = .now }
    /// When the next user write may be sent, if that is still ahead: one spacing after the last write actually
    /// sent. Checked while holding the request slot, so two writes admitted together cannot go back-to-back.
    func writeDue(account: AccountScope) -> ContinuousClock.Instant? {
        guard let last = lastWrite[account] else { return nil }
        let due = last.advanced(by:minimumSpacing)
        return due > .now ? due : nil
    }
    public func observe(_ response: GitHubResponse, account: AccountScope, resource: Resource = .rest) {
        let now = Date()
        if let remaining = response.header("X-RateLimit-Remaining").flatMap(Int.init), let epoch = response.header("X-RateLimit-Reset").flatMap(Double.init) {
            quotas[Key(account:account,resource:resource)] = Quota(remaining:max(0,remaining),reset:Date(timeIntervalSince1970:epoch))
        }
        if let seconds = response.header("X-Poll-Interval").flatMap(Double.init) {
            pollIntervals[account] = max(0,seconds)
        }
        let secondary = response.status == 429 || response.status == 403 && (response.header("Retry-After") != nil || response.header("X-RateLimit-Remaining") == "0" || String(decoding:response.data,as:UTF8.self).localizedCaseInsensitiveContains("rate limit"))
        if secondary {
            let count = min(6,(secondaryFailures[account] ?? 0)+1); secondaryFailures[account] = count
            let seconds = response.header("Retry-After").flatMap(Double.init) ?? min(3600,60*pow(2,Double(count-1)))
            var until = now.addingTimeInterval(max(0,seconds))
            if response.header("X-RateLimit-Remaining") == "0", let epoch = response.header("X-RateLimit-Reset").flatMap(Double.init) { until = max(until,Date(timeIntervalSince1970:epoch)) }
            notBefore[account] = max(notBefore[account] ?? now,until)
        } else if (200..<400).contains(response.status) { secondaryFailures[account] = 0 }
    }
    public func observeGraphQL(_ response: GitHubResponse, account: AccountScope) {
        struct Envelope: Decodable { struct Payload: Decodable { struct Limit: Decodable { let cost: Int; let remaining: Int; let resetAt: String }; let rateLimit: Limit? }; let data: Payload? }
        if let limit = try? JSONDecoder().decode(Envelope.self,from:response.data).data?.rateLimit,
           let reset = GitHubDate.parse(limit.resetAt) {
            quotas[Key(account:account,resource:.graphql)] = Quota(remaining:max(0,limit.remaining),reset:reset)
            lastCost[Key(account:account,resource:.graphql)] = max(1,limit.cost)
        }
    }
    public func observePollInterval(_ response: GitHubResponse, account: AccountScope, feature: String) {
        guard let seconds = response.header("X-Poll-Interval").flatMap(Double.init), seconds.isFinite else { return }
        // Clamp before Duration conversion: a huge finite header (e.g. 1e30) traps on Int128 overflow.
        nextProviderPoll[PollKey(account:account,feature:feature)] = ContinuousClock.now.advanced(by:.seconds(min(86_400,max(0,seconds))))
    }
    public func beginPoll(account: AccountScope, feature: String, interval: TimeInterval, force: Bool = false) -> Bool {
        let key = PollKey(account:account,feature:feature)
        let now = ContinuousClock.now
        guard now >= (nextProviderPoll[key] ?? now) else { return false }
        if force { return true }
        if let last = lastPoll[key],now < last.advanced(by:.seconds(max(0,interval))) { return false }
        return true
    }
    /// Admission is read-only; only a committed successful fetch advances its due time.
    public func completePoll(account: AccountScope, feature: String, interval: TimeInterval) {
        let key = PollKey(account:account,feature:feature)
        lastPoll[key] = interval <= 0 ? nil : ContinuousClock.now
    }
    public func pollInterval(account: AccountScope) -> TimeInterval { pollIntervals[account] ?? 0 }
    public func retryAt(account: AccountScope) -> Date? { notBefore[account] }

    // MARK: Waiters

    /// Sleeps until `due` as pacing of `account`, counted in `waiters(account:)`. Every pacing sleep (start spacing,
    /// interactive grace, the write gap) goes through here.
    func pace(account: AccountScope, until due: ContinuousClock.Instant) async throws {
        pacing[account, default:0] += 1; waitersChanged(account)
        defer { pacing[account, default:0] -= 1 }
        try await ContinuousClock().sleep(until:due)
    }
    /// Tasks suspended in this budget for one account: queued for its request slot, or sleeping off pacing.
    struct Waiters: Sendable {
        var slot = 0
        var pacing = 0
        func covers(_ minimum: Waiters) -> Bool { slot >= minimum.slot && pacing >= minimum.pacing }
    }
    func waiters(account: AccountScope) -> Waiters { Waiters(slot:requestWaiters[account]?.count ?? 0, pacing:pacing[account] ?? 0) }
    /// Returns once at least `slot` tasks queue for `account`'s request slot and `pacing` sleep off its pacing, so a
    /// test knows a competing request reached the budget instead of sleeping and hoping it did.
    func untilWaiting(account: AccountScope, slot: Int = 0, pacing: Int = 0) async {
        let minimum = Waiters(slot:slot, pacing:pacing)
        guard !waiters(account:account).covers(minimum) else { return }
        await withCheckedContinuation { waiterObservers.append((account, minimum, $0)) }
    }
    private func waitersChanged(_ account: AccountScope) {
        guard !waiterObservers.isEmpty else { return }
        let current = waiters(account:account)
        let ready = waiterObservers.filter { $0.account == account && current.covers($0.minimum) }
        waiterObservers.removeAll { $0.account == account && current.covers($0.minimum) }
        for observer in ready { observer.continuation.resume() }
    }
}
/// Apply pacing/quota to every actual HTTP request, including redirects and unconditional retries.
public struct BudgetedGitHubTransport: GitHubTransport {
    public let base: any GitHubTransport
    public let budget: RateBudget
    public let account: AccountScope
    let ownsRequestSlot:Bool
    public let beforeSend: (@Sendable () async throws -> Void)?
    private let interactiveRead:Bool
    public init(base: any GitHubTransport, budget: RateBudget, account: AccountScope, beforeSend:(@Sendable () async throws -> Void)? = nil, interactiveRead:Bool = false) { self.base = base; self.budget = budget; self.account = account;self.beforeSend=beforeSend;self.ownsRequestSlot=true;self.interactiveRead=interactiveRead }
    init(base:any GitHubTransport,budget:RateBudget,account:AccountScope,ownsRequestSlot:Bool,beforeSend:@escaping @Sendable () async throws -> Void) { self.base=base;self.budget=budget;self.account=account;self.beforeSend=beforeSend;self.ownsRequestSlot=ownsRequestSlot;self.interactiveRead=false }
    public func send(_ request: URLRequest) async throws -> GitHubResponse {
        let graphQL=request.httpMethod == "POST" && request.url?.lastPathComponent == "graphql"
        let query=graphQL ? (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with:$0) } as? [String:Any])?["query"] as? String : nil
        let readMethod=request.httpMethod == nil || request.httpMethod == "GET" || request.httpMethod == "HEAD" || graphQL && query?.trimmingCharacters(in:.whitespacesAndNewlines).hasPrefix("query") == true && query?.contains("mutation") == false
        // User-initiated work (interactive reads, writes and their nested preflight reads) is interactive:
        // it may use the reserve and takes the next free slot. Only interactive reads skip pacing.
        let userInitiated=interactiveRead || beforeSend != nil || !ownsRequestSlot
        let priority: RateBudget.Priority = userInitiated ? .interactive : .background
        let resource: RateBudget.Resource = graphQL ? .graphql : .rest
        // Quota check and pacing before the slot: a sleeping background request never blocks the account.
        try await budget.acquire(account:account,resource:resource,priority:priority,cost:resource == .graphql ? 100 : 1,interactiveRead:userInitiated && readMethod,reservingQuota:false)
        if ownsRequestSlot { try await budget.beginRequest(account:account,priority:priority) }
        var holding = ownsRequestSlot
        do {
            // `acquire` checked the write gap before the slot; another write may have been sent since. Re-check
            // inside the slot, and wait with the slot released (no interactive hold) so reads are unaffected.
            if holding && userInitiated && !readMethod {
                while let due = await budget.writeDue(account:account) {
                    holding = false; await budget.endRequest(account:account)
                    try await budget.pace(account:account, until:due)
                    try await budget.beginRequest(account:account,priority:priority); holding = true
                }
            }
            // Backoff may have begun, or the caller been cancelled, while waiting for the slot.
            try Task.checkCancellation()
            try await budget.checkBackoff(account:account)
            try await budget.checkQuota(account:account,resource:resource,priority:priority,cost:resource == .graphql ? 100 : 1,reserve:true)
            try await beforeSend?()
            if userInitiated && !readMethod { await budget.recordWrite(account:account) }
            let response = try await base.send(request)
            // Observe before honoring cancellation: a 429/secondary limit that arrives as a cycle is
            // cancelled must still pause this account.
            await budget.observe(response,account:account,resource:resource)
            if resource == .graphql { await budget.observeGraphQL(response,account:account) }
            // Pass a raw positive 401 to the authenticated client's origin validation;
            // this transport must never classify an anonymous/foreign response as revocation.
            if response.status != 401 && beforeSend == nil { try Task.checkCancellation() }
            if holding { await budget.endRequest(account:account,priority:priority) }
            return response
        } catch {
            if holding { await budget.endRequest(account:account,priority:priority) }
            throw error
        }
    }
}
