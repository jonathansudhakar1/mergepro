import SwiftUI

extension View {
    /// `onChange(of:)` whose async work is a task tied to the view, built on `task(id:)`: a newer value or the view's
    /// disappearance cancels the previous run. Unlike `task(id:)`, appearing does not run `action`; only a change does.
    func onChangeTask<Value: Equatable & Sendable>(of value: Value, _ action: @escaping @MainActor (Value) async -> Void) -> some View {
        modifier(ChangeTask(value:value, action:action))
    }
}

private struct ChangeTask<Value: Equatable & Sendable>: ViewModifier {
    let value: Value
    let action: @MainActor (Value) async -> Void
    /// The value the view first rendered with, then the value of the last run: appearing with it runs nothing.
    @State private var seen: Value
    init(value: Value, action: @escaping @MainActor (Value) async -> Void) {
        self.value = value; self.action = action
        _seen = State(initialValue:value)
    }
    func body(content: Content) -> some View {
        content.task(id:value) {
            guard seen != value else { return }
            seen = value
            await action(value)
        }
    }
}
