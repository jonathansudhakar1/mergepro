import MergeProCore

/// Actions wording, kept in the shared `ProviderStateText` namespace so screens never show raw provider values.
extension ProviderStateText {
    /// Outcome of an Actions write (cancel, re-run, approve, dispatch, deployment review) when the provider gave no message.
    static func actionsWrite(_ state: ActionsWriteState) -> String {
        switch state {
        case .prepared: "Request prepared. It has not been sent to GitHub."
        case .sending: "Sending the request to GitHub…"
        case .accepted: "GitHub accepted the request. Refresh to see the updated run."
        case .confirmed: "GitHub confirmed the change."
        case .rejected: "GitHub rejected the request. Nothing changed."
        case .uncertain: "The outcome is unknown. Reconcile before trying again."
        }
    }

    /// A run, job or deployment status or conclusion, e.g. "in_progress" → "In progress". Unknown values keep their words.
    static func actionsStatus(_ value: String) -> String {
        switch value {
        case "": return "Unknown"
        default:
            let words = value.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }
}

/// Confirmation text for run commands that stop work or run fork code; each names the workflow, branch and actor.
enum ActionsRunConfirmation {
    static func cancelMessage(_ run: WorkflowRun) -> String {
        "\(run.name) on \(run.branch), triggered by \(run.actor) (attempt \(run.attempt)). Running jobs stop and the run ends as cancelled."
    }
    /// Re-runs repeat everything the workflow does, including deployments, so they are confirmed like cancel.
    static func rerunMessage(_ run: WorkflowRun, failedOnly: Bool) -> String {
        "\(run.name) on \(run.branch) at \(run.headSHA.prefix(8)) starts attempt \(run.attempt + 1)\(failedOnly ? " for its failed jobs" : ""). If the workflow deploys or publishes, it does so again; environment protection rules still apply."
    }
    static func approveForkMessage(_ run: WorkflowRun) -> String {
        "\(run.name) on \(run.branch), triggered by \(run.actor), comes from a fork. Approving lets its workflow code run on this repository's Actions runners."
    }
}
