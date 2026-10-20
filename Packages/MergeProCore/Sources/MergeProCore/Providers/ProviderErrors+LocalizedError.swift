import Foundation

// User-facing text for `error.localizedDescription`. Switches are exhaustive so new cases need wording;
// messages never include credentials, raw server text, or internal type names.

private func rateLimitedMessage(_ until: Date?) -> String {
    "GitHub rate limited this account."+(until.map { " Retry after "+$0.formatted(date:.omitted,time:.shortened)+"." } ?? " Retry later.")
}

extension GitHubFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidAuthentication: "GitHub rejected this account's authorization. Reconnect it in Setup."
        case .scopeRequired: "This account needs additional GitHub permissions. Reconnect it in Setup."
        case .organizationRestricted: "The organization restricts this app's access. Ask an organization owner to approve it."
        case .resourceDenied: "GitHub could not find this resource, or the account cannot access it."
        case .rateLimited(let until): rateLimitedMessage(until)
        case .unsafeURL: "GitHub returned an unsafe link, so it was not followed."
        case .invalidResponse: "GitHub returned an unexpected response. Refresh and try again."
        }
    }
}

extension RepositoryBrowserFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPath: "This path is not available at the selected ref."
        case .invalidRef: "The branch, tag, commit or name is invalid, or it changed since it was loaded. Refresh and try again."
        case .permissionDenied: "The active account cannot make this change, or the repository identity changed."
        case .protectedBranch: "Protected branches cannot be deleted here."
        case .defaultBranch: "The default branch cannot be deleted."
        case .existingBranch: "A branch with this name already exists."
        case .unknownWriteOutcome: "GitHub did not confirm the outcome. Reconcile before trying again."
        case .missingRefs: "GitHub could not compare these refs. Check both names and try again."
        case .assetTooLarge: "This asset exceeds the supported download size. Download it on GitHub."
        case .invalidAsset: "This asset is unavailable or its download link is invalid."
        case .reviewersNotRequested: "The pull request exists, but reviewer requests could not be confirmed."
        }
    }
}

extension PRDetailFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .revisionChanged: "The pull request head changed for the selected account. Refresh before acting."
        case .unavailable: "This pull request is unavailable for the selected account."
        case .oversized: "GitHub returned more data than MergePro reads natively. Open the pull request on GitHub."
        case .invalidPath: "This path or revision is not available."
        }
    }
}

extension StorageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .accountMissing: "This account is no longer connected. Reconnect it in Setup."
        case .revisionConflict: "Saved offline data for this item no longer matches. Refresh to load it again."
        case .invalidCacheBudget: "The offline cache size limit is not valid. Choose a different limit."
        case .payloadExceedsBudget: "This content is larger than the offline cache allows, so it was not saved for offline use."
        case .draftIdentityConflict: "This draft no longer matches its pull request, so it was not saved. Copy your text and try again."
        }
    }
}

extension ProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthenticated: "GitHub rejected this account's authorization. Reconnect it in Setup."
        case .restrictedOrganization: "The organization restricts this app's access. Ask an organization owner to approve it."
        case .forbidden: "The active account doesn't have permission for this item."
        case .rateLimited(_, let retryAfter): rateLimitedMessage(retryAfter)
        case .incompleteData: "GitHub returned incomplete data for this item. Refresh and try again."
        case .uncertainWriteOutcome: "GitHub did not confirm the outcome. Reconcile before trying again."
        }
    }
}

extension DeviceFlowFailure: LocalizedError {
    /// Rejection text written by `DeviceFlowClient`; anything else is replaced by a fixed message.
    static let knownRejections: Set<String> = [
        "Configure your GitHub OAuth App client ID before connecting.", "GitHub authorization was denied.",
        "Enable device flow in your GitHub OAuth App settings.", "Check your GitHub OAuth App client ID.",
        "Your GitHub session expired. Connect your account again.", "GitHub authorization could not complete. Start a new connection."
    ]
    public var errorDescription: String? {
        switch self {
        case .cancelled: "The GitHub connection was cancelled."
        case .expired: "The GitHub sign-in code expired. Start a new connection."
        case .rejected(let message): Self.knownRejections.contains(message) ? message : "GitHub authorization could not complete. Start a new connection."
        case .invalidResponse: "GitHub returned an unexpected response while connecting. Start a new connection."
        }
    }
}
