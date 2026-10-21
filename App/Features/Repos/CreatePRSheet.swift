import SwiftUI
import MergeProCore

struct CreatePRSheet:View {
    let repository:RepoCatalogEntry
    let head:String
    let branches:[RepositoryBranch]
    let service:RepositoryBrowserService
    var openPR:(ProviderKey) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var headName=""
    @State private var headRepository=""
    @State private var base=""
    @State private var title=""
    @State private var bodyText=""
    @State private var draft=false
    @State private var reviewers=""
    @State private var busy=false
    @State private var error:String?
    @State private var uncertain=false
    @State private var created:CreatedRepositoryPR?
    /// Return in a field moves to the next field and in the description inserts a newline; neither creates the pull
    /// request. Return creates it only when no text input has focus; ⌘Return creates it from anywhere.
    @FocusState private var focus:Field?
    private enum Field:Hashable { case head,fork,base,title,body,reviewers }
    private var reviewerLogins:[String] { reviewers.split(separator:",").map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    /// Mirrors CreatePRCommand.validate() so invalid input is explained before submission instead of failing as a generic ref error.
    private var validationMessage:String? {
        let head=headName.split(separator:":",omittingEmptySubsequences:false).map(String.init)
        if title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || headName.isEmpty || base.isEmpty { return nil }
        if title.count>256 { return "Titles are limited to 256 characters." }
        if !BranchService.validName(base) { return "Enter a valid base branch name." }
        if !(1...2).contains(head.count) || !BranchService.validName(head.last ?? "") { return "Enter a valid head branch, or owner:branch for a fork." }
        if headName==base { return "Choose a head branch that differs from the base branch." }
        if head.count==2,headRepository.split(separator:"/").first.map(String.init) != head[0] { return "For owner:branch, enter the fork repository as owner/name with the same owner." }
        if bodyText.utf8.count>65536 { return "The description is too long for GitHub." }
        if reviewerLogins.count>15 || !reviewerLogins.allSatisfy({ $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) { return "Reviewers must be up to 15 GitHub logins separated by commas." }
        return nil
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Label("Create Pull Request",systemImage:"arrow.triangle.pull").font(.system(.title2,design:.rounded).bold()).foregroundStyle(DesignTokens.cobalt)
            Text(repository.repository.name+" · "+repository.accountLogin).font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    Form {
                        TextField("Head branch (owner:branch for a fork)",text:$headName).focused($focus,equals:.head).onSubmit { focus = .fork }
                        TextField("Fork repository (owner/name, if applicable)",text:$headRepository).focused($focus,equals:.fork).onSubmit { focus = .base }
                        HStack { TextField("Base branch",text:$base).focused($focus,equals:.base).onSubmit { focus = .title };Menu("Branches") { ForEach(branches) { branch in Button(branch.name) { base=branch.name } } } }
                        TextField("Title",text:$title).focused($focus,equals:.title).onSubmit { focus = .body }
                        VStack(alignment:.leading,spacing:8) {
                            Text("Description").font(.callout).foregroundStyle(.secondary)
                            TextEditor(text:$bodyText).frame(minHeight:120).focused($focus,equals:.body).accessibilityLabel("Pull request description")
                                .background(Color(nsColor:.textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:8))
                                .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(Color(nsColor:.separatorColor),lineWidth:1).allowsHitTesting(false))
                        }
                        Toggle("Create as Draft",isOn:$draft)
                        TextField("Reviewers (comma-separated logins)",text:$reviewers).focused($focus,equals:.reviewers)
                    }.formStyle(.grouped).frame(height:360).disabled(busy || uncertain || created != nil)
                    if let validationMessage,created==nil { WorkspaceNotice(message:validationMessage,symbol:"exclamationmark.triangle",tint:.orange) }
                    if let error { WorkspaceNotice(message:error,symbol:"exclamationmark.circle",tint:.red) }
                    if uncertain { WorkspaceNotice(message:"GitHub may have created this PR. Reconcile checks the existing head/base pair before any further write.",symbol:"exclamationmark.triangle",tint:.orange) }
                    if let created,created.reviewersPending { WorkspaceNotice(message:"PR #\(String(created.number)) was created. Reviewer requests could not be confirmed; inspect its existing detail before requesting them again.",symbol:"exclamationmark.triangle",tint:.orange) }
                }
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if let created { Button("Open PR #\(String(created.number))") { openPR(created.key);dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
                else {
                    Button(uncertain ? "Reconcile Creation" : "Create Pull Request") { Task { await create() } }.keyboardShortcut(focus == nil ? .defaultAction : nil).buttonStyle(.borderedProminent).tint(DesignTokens.cobalt).disabled(!canCreate).help("Create (⌘Return)")
                        .background { Button("Create Pull Request") { if canCreate { Task { await create() } } }.keyboardShortcut(.return,modifiers:.command).hidden().accessibilityHidden(true) }
                }
            }
        }.padding(24).frame(width:600,height:560).background { WorkspaceCanvas() }
        .onAppear { headName=head.isEmpty ? repository.defaultBranch : head;base=repository.defaultBranch }
        // An in-flight create must finish (or become an explicit unknown) before the sheet can close.
        .onExitCommand { if !busy { dismiss() } }
        .onChange(of:error) { _,message in if let message { AccessibilityNotification.Announcement(message).post() } }
    }
    private var canCreate:Bool { !busy && !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !headName.isEmpty && !base.isEmpty && validationMessage == nil }
    private func create() async {
        guard !busy else { return }
        busy=true;defer { busy=false };error=nil
        let command=CreatePRCommand(repository:repository.providerKey,repositoryName:repository.repository.name,head:headName,base:base,title:title,body:bodyText,draft:draft,reviewers:reviewerLogins,headRepository:headRepository.isEmpty ? nil : headRepository)
        do {
            let result=try await service.createPR(command);created=result;uncertain=false
            if !result.reviewersPending { openPR(result.key);dismiss() }
            else { AccessibilityNotification.Announcement("Pull request \(result.number) was created. Reviewer requests could not be confirmed.").post() }
        } catch {
            uncertain=(error as? RepositoryBrowserFailure) == .unknownWriteOutcome
            self.error=providerErrorMessage(error)
        }
    }
}
