import Foundation

public enum FeatureNotificationRules {
    /// Each feature's saved rules apply to its own events before the single collector summarizes them.
    public static func matchingKeys(events:[ChangeEvent],prRules:[Set<String>],workflowKeys:Set<String>) -> Set<String> {
        let prKeys = prRules.isEmpty
            ? Set(events.filter { $0.locator?.subjectType != "WorkflowRun" }.map(\.key))
            : prRules.reduce(into:Set<String>()) { $0.formUnion($1) }
        return prKeys.union(workflowKeys)
    }
}
