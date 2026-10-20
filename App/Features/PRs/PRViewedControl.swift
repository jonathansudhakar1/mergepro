import MergeProCore
import SwiftUI

/// Provider viewed marks for one file, independent of local reading progress. All files share the
/// window's single viewed-states read; a confirmed write updates it in memory without a re-read.
struct PRViewedControl:View {
    let pr:PullRequest
    let snapshot:PRDetailSnapshot
    let path:String
    let account:PRDetailAccountModel
    @State private var busy=false
    @State private var message:String?
    private var head:String { snapshot.headSHA }
    var body:some View {
        VStack(alignment:.leading,spacing:4) {
            HStack(spacing:8) {
                let state=account.providerViewed(path,head:head)
                Image(systemName:state == true ? "checkmark.seal.fill" : state == nil ? "questionmark.diamond" : "seal").foregroundStyle(state == true ? Color.green : Color.secondary).font(.caption).accessibilityHidden(true)
                Text(statusText(state)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(statusText(state))
                Spacer(minLength:4)
                if account.viewedLoading || busy { ProgressView().controlSize(.mini) }
                Button(state == true ? "Unmark on GitHub" : "Mark on GitHub") { Task { await change(!(state ?? false)) } }
                    .disabled(busy || account.actionPR == nil || account.uncertainViewed.contains(path))
                    .help(account.uncertainViewed.contains(path) ? "A previous change has an unknown outcome. Read the provider result first." : "Change the viewed mark on GitHub")
                Button { Task { await account.loadViewed(head:head,refresh:true) } } label: { Image(systemName:"arrow.clockwise") }
                    .disabled(busy || account.viewedLoading).help("Read provider viewed marks").accessibilityLabel("Read provider state")
            }.controlSize(.small)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled) }
            if let key=account.actionPR?.key,!account.uncertainViewed.isEmpty {
                PRWriteStatusView(key:key,storage:account.storage,changeSignal:account.operationRevision) { await account.loadViewed(head:head,refresh:true) }.font(.caption)
            }
        }
        .task(id:account.epoch.uuidString+head) { await account.loadViewed(head:head) }
        .onChange(of:path) { message=nil }
    }
    private func statusText(_ state:Bool?) -> String {
        if let error=account.actionError { return error }
        if account.uncertainViewed.contains(path) { return "GitHub viewed state unknown · last change unconfirmed" }
        let who=account.login.isEmpty ? "" : " · as \(account.login)"
        switch state {
        case true?:return "GitHub: viewed"+who
        case false?:return "GitHub: not viewed"+who
        case nil:
            if account.viewedLoading { return "Reading GitHub viewed marks…" }
            if let error=account.viewedError { return "GitHub viewed state unknown: "+error }
            if account.viewed?.complete == false { return "GitHub viewed state unknown · provider list incomplete"+who }
            return "GitHub viewed state unknown"+who
        }
    }
    private func change(_ viewed:Bool) async {
        busy=true;defer { busy=false }
        let file=path
        let result=await account.setViewed(file,viewed:viewed,snapshot:snapshot)
        if path == file { message=result }
    }
}
