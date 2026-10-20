import MergeProCore
import SwiftUI

/// Durable uncertain results remain discoverable in every native write surface after relaunch.
struct PRWriteStatusView:View {
    let key:ProviderKey
    let storage:SetupStorage
    var changeSignal:Int=0
    var changed:(@MainActor () async -> Void)?
    @State private var operations:[PRWriteOperation]=[]
    @State private var message:String?
    @State private var busy=false
    var body:some View {
        VStack(alignment:.leading) {
            ForEach(operations.filter { [.prepared,.sending,.uncertain,.postedOutdated].contains($0.state) }) { operation in
                HStack {
                    Label { Text("\(ProviderStateText.writeIntent(operation.command.intent)): \(ProviderStateText.writeState(operation.state))") } icon: { Image(systemName:"exclamationmark.arrow.triangle.2.circlepath").foregroundStyle(.orange) }
                        .help("Command \(operation.id.uuidString.prefix(8))")
                    if operation.state == .prepared { Button("Release unsent command") { Task { await release(operation) } }.disabled(busy) }
                    else if operation.state != .postedOutdated {
                        Button("Read provider result") { Task { await reconcile(operation) } }.disabled(busy)
                        // Idempotent deltas only (labels, assignees, review requests, subscription): applying them again is harmless.
                        if operation.canStopWaiting {
                            Button("Stop waiting") { Task { await stopWaiting(operation) } }.disabled(busy)
                                .help("Stop tracking this change and allow new changes. Nothing is resent; check the pull request on GitHub.")
                                .accessibilityIdentifier("stopWaitingWrite")
                        }
                    }
                    else { Text("Already posted against an older comparison; review the original coordinates.").font(.caption) }
                }
            }
            if let message { Text(message).font(.caption).textSelection(.enabled) }
        }.task(id:changeSignal) { operations=[];await load() }
    }
    private func load() async {
        do { let saved=try await storage.writeOperations(key);guard !Task.isCancelled else { return };operations=saved }
        catch { guard !Task.isCancelled else { return };message=error.localizedDescription }
    }
    private func release(_ operation:PRWriteOperation) async { busy=true;defer { busy=false };do { try await storage.releaseUnsentWrite(operation.id);await load();await changed?() } catch { message=error.localizedDescription } }
    private func reconcile(_ operation:PRWriteOperation) async { busy=true;defer { busy=false };do { let result=try await storage.reconcileWrite(operation.id);message=Self.text(result);await load();await changed?() } catch { message=error.localizedDescription } }
    private func stopWaiting(_ operation:PRWriteOperation) async { busy=true;defer { busy=false };do { let result=try await storage.writeCoordinator().abandonUncertain(operation.id);message=Self.text(result);await load();await changed?() } catch { message=error.localizedDescription } }
    private static func text(_ operation:PRWriteOperation) -> String {
        if case .merge=operation.command.intent { return ProviderStateText.mergeOperation(operation) }
        return [ProviderStateText.writeState(operation.state),operation.message].compactMap { $0 }.joined(separator:" · ")
    }
}
