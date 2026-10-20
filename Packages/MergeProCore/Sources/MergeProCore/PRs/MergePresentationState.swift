import Foundation

/// Ephemeral commit text belongs to one action-account PR presentation.
public struct MergeOptionsPresentationState: Sendable {
    private var identity = PRActionLoadState()
    private var editorKey: ProviderKey?
    /// Edits survive method switches and same-account refreshes; prefill is head-bound.
    public var text = MergeCommitText()
    public var title:String { get { text.title } set { text.title=newValue } }
    public var message:String { get { text.message } set { text.message=newValue } }
    public var titleUsesProviderDefault:Bool { text.titleUsesProviderDefault }
    public var messageUsesProviderDefault:Bool { text.messageUsesProviderDefault }
    public init() {}
    /// Applies prefill read for `evidence` to this editor. Prefill for another head is discarded
    /// (unedited fields become empty); evidence for another PR is ignored and returns false.
    @discardableResult public mutating func applyDefaults(_ defaults:MergeMessageDefaults?,method:MergeMethod,evidence:MergeEvidence?) -> Bool {
        guard let evidence,editorKey == nil || editorKey == evidence.key else { return false }
        text.applyDefaults(defaults?.head == evidence.head ? defaults : nil,method:method);return true
    }
    public func overrides(keepTrailers:Bool=true,action:MergeAction) -> (title:String?,message:String?) { text.overrides(keepTrailers:keepTrailers,action:action) }
    public var key: ProviderKey? { identity.key }
    public mutating func begin(account: AccountScope?) -> UUID {
        if editorKey?.account != account { retireText() }
        return identity.begin()
    }
    public mutating func select(_ key: ProviderKey, request: UUID) {
        guard identity.isCurrent(request) else { return }
        if editorKey != key { retireText() }
        editorKey = key
        identity.select(key, request:request)
    }
    public mutating func invalidate() {
        identity.invalidate()
        retireText()
    }
    private mutating func retireText() {
        editorKey = nil
        text = MergeCommitText(method:text.method)
    }
    public func isCurrent(_ request: UUID) -> Bool { identity.isCurrent(request) }
    public func accepts(_ key: ProviderKey, request: UUID, available: Bool) -> Bool { identity.accepts(key,request:request,available:available) }
    public mutating func present(_ key: ProviderKey, request: UUID, available: Bool) -> Bool { identity.present(key,request:request,available:available) }
    public mutating func fail(request: UUID) -> Bool { identity.fail(request:request) }
    public func canDisplay(_ key: ProviderKey?, available: Bool) -> Bool { identity.canDisplay(key,available:available) }
    public func presentationRequest(for key: ProviderKey, available: Bool) -> UUID? { identity.presentationRequest(for:key,available:available) }
}

/// One generation for every producer of the detail comparison presentation.
public struct PRComparisonPresentationState: Sendable {
    public enum Choice: Sendable { case aggregate, comparison, refresh, canonical }
    private var generation: UUID?
    public init() {}
    @discardableResult public mutating func choose(_ choice: Choice) -> UUID {
        generation = UUID()
        return generation!
    }
    public func accepts(_ request: UUID, available: Bool) -> Bool { available && generation == request }
}
