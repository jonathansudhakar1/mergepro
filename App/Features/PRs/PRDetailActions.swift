import AppKit
import MergeProCore
import SwiftUI

/// One per detail window: the active action account's row for this PR plus the light provider reads
/// shared by the header, the Overview reviewers panel, the metadata pickers and every file's viewed
/// control. `epoch` changes on account change/reset; late results from an older epoch are dropped.
@MainActor @Observable final class PRDetailAccountModel {
    let readPR:PullRequest
    let storage:SetupStorage
    private(set) var epoch=UUID()
    private(set) var actionPR:PullRequest?
    private(set) var login=""
    private(set) var actionError:String?
    private(set) var resolving=false
    /// Set when the window found the action account unavailable; only an explicit reset reads again.
    private(set) var blocked=false
    private(set) var viewed:PRViewedStates?
    private(set) var viewedError:String?
    private(set) var viewedLoading=false
    /// Provider-confirmed writes since the last read, and paths whose write outcome is not known.
    private(set) var confirmedViewed:[String:Bool]=[:]
    private(set) var uncertainViewed:Set<String>=[]
    private(set) var administration:PRReviewAdministration?
    private(set) var administrationError:String?
    private(set) var administrationLoading=false
    private(set) var options:PRMetadataOptions?
    private(set) var optionsError:String?
    private(set) var optionsLoading=false
    /// Bumped after every write so PRWriteStatusView rereads durable operations.
    private(set) var operationRevision=0
    /// The latest write outcome shown under the header.
    var status:String?
    @ObservationIgnored private var resolution:Task<PullRequest?,Never>?
    init(readPR:PullRequest,storage:SetupStorage) { self.readPR=readPR;self.storage=storage }

    /// Drops every account-bound value; the next read resolves the action account again.
    func reset() {
        epoch=UUID();resolution=nil;actionPR=nil;login="";actionError=nil;resolving=false;blocked=false
        viewed=nil;viewedError=nil;viewedLoading=false;confirmedViewed=[:];uncertainViewed=[]
        administration=nil;administrationError=nil;administrationLoading=false
        options=nil;optionsError=nil;optionsLoading=false;status=nil
    }
    func invalidate() { reset();blocked=true;actionError="Action account unavailable. Reconnect it or choose another action account; local drafts and reading marks are kept." }
    @discardableResult func resolve() async -> PullRequest? {
        if let actionPR { return actionPR }
        guard !blocked else { return nil }
        if let resolution { return await resolution.value }
        let token=epoch;resolving=true;actionError=nil
        let task=Task { () -> PullRequest? in
            defer { if self.epoch == token { self.resolving=false } }
            do {
                let chosen=try await self.storage.detailActionPR(self.readPR),name=try await self.storage.actionLogin(chosen.key)
                guard self.epoch == token else { return nil }
                self.actionPR=chosen;self.login=name;return chosen
            } catch {
                if self.epoch == token { self.actionError=prDetailErrorMessage(error);self.resolution=nil }
                return nil
            }
        }
        resolution=task
        return await task.value
    }

    // MARK: Viewed marks

    /// ONE provider read per window and head; switching files reuses it.
    func loadViewed(head:String,refresh:Bool=false) async {
        guard refresh || viewed?.headSHA != head,refresh || !viewedLoading else { return }
        let token=epoch;viewedLoading=true;viewedError=nil
        defer { if epoch == token { viewedLoading=false } }
        guard let pr=await resolve(),epoch == token else { return }
        do {
            let value=try await storage.viewedStates(pr,revision:head,refresh:refresh)
            guard epoch == token else { return }
            viewed=value;confirmedViewed=[:];uncertainViewed=[]
        } catch { if epoch == token,!(error is CancellationError) { viewedError=prDetailErrorMessage(error) } }
    }
    /// True/false only with provider evidence for this head; nil is unknown.
    func providerViewed(_ path:String,head:String) -> Bool? {
        guard !uncertainViewed.contains(path) else { return nil }
        if let value=confirmedViewed[path] { return value }
        guard let viewed,viewed.headSHA == head else { return nil }
        return viewed.isViewed(path)
    }
    func setViewed(_ path:String,viewed value:Bool,snapshot:PRDetailSnapshot) async -> String {
        guard let pr=await resolve() else { return actionError ?? "Action account unavailable." }
        let token=epoch
        do {
            let result=try await storage.performWrite(.viewed(readPR:readPR,actionPR:pr,revision:PRWriteRevision(snapshot),path:path,viewed:value))
            guard epoch == token else { return "The action account changed; read the provider result before retrying." }
            operationRevision += 1
            if result.state == .confirmed {
                try? await storage.recordViewedState(pr,revision:snapshot.headSHA,path:path,viewed:value)
                confirmedViewed[path]=value;uncertainViewed.remove(path)
                return "GitHub confirmed: \(value ? "viewed" : "not viewed")"
            }
            uncertainViewed.insert(path);try? await storage.invalidateViewedStates(pr)
            return prWriteStateText(result.state)+" viewed change. Read the provider result before retrying; nothing was resent."
        } catch { if epoch == token { operationRevision += 1 };return "Provider viewed change failed: "+prDetailErrorMessage(error) }
    }

    // MARK: Light reads

    func loadAdministration() async {
        let token=epoch;administrationLoading=true;administrationError=nil
        defer { if epoch == token { administrationLoading=false } }
        guard let pr=await resolve(),epoch == token else { if epoch == token { administrationError=actionError };return }
        do { let value=try await storage.reviewAdministration(pr);guard epoch == token else { return };administration=value }
        catch { if epoch == token,!(error is CancellationError) { administrationError=prDetailErrorMessage(error) } }
    }
    func loadOptions() async {
        let token=epoch;optionsLoading=true;optionsError=nil
        defer { if epoch == token { optionsLoading=false } }
        guard let pr=await resolve(),epoch == token else { if epoch == token { optionsError=actionError };return }
        do { let value=try await storage.metadataOptions(pr);guard epoch == token else { return };options=value }
        catch { if epoch == token,!(error is CancellationError) { optionsError=prDetailErrorMessage(error) } }
    }

    // MARK: Writes

    /// One revision-independent write under the action account. A non-confirmed outcome is reported, never resent.
    func perform(_ intent:PRWriteIntent) async -> (state:PRWriteOperation.State?,message:String) {
        guard let pr=await resolve() else { return (nil,actionError ?? "Action account unavailable.") }
        do {
            let result=try await storage.performLightWrite(pr,intent:intent)
            operationRevision += 1
            return (result.state,result.state == .confirmed ? "GitHub confirmed the change." : prWriteStateText(result.state)+". Read the provider result before retrying; nothing was resent.")
        } catch { operationRevision += 1;return (nil,prDetailErrorMessage(error)) }
    }
    /// After an operation was reconciled elsewhere, reread the light state it may have changed.
    func reconciled() async { await loadAdministration();if options != nil { await loadOptions() } }
    /// A review write elsewhere in the window (e.g. quick approve) reached the ledger; status views reread it.
    func wrote() { operationRevision += 1 }
}

// MARK: Shared helpers

/// User-facing text for detail-window failures; PR detail failures get specific wording.
func prDetailErrorMessage(_ error:any Error) -> String {
    switch error as? PRDetailFailure {
    case .revisionChanged?:return "The pull request head changed for the selected account. Refresh before acting."
    case .unavailable?:return "This pull request is unavailable for the selected account."
    case .oversized?:return "GitHub returned more data than MergePro reads natively. Open the pull request on GitHub."
    case .invalidPath?:return "This path or revision is not available."
    case nil:return providerErrorMessage(error)
    }
}
func prWriteStateText(_ state:PRWriteOperation.State) -> String {
    switch state {
    case .confirmed:"Confirmed"
    case .postedOutdated:"Posted against an older comparison"
    case .uncertain:"Outcome unknown"
    case .sending:"Still sending"
    case .prepared:"Prepared but not sent"
    case .rejected:"Rejected"
    }
}
/// "cached 5 min. ago"; an unknown age is said explicitly.
func prCachedAge(_ date:Date?,now:Date=Date()) -> String {
    guard let date else { return "cached · age unknown" }
    if now.timeIntervalSince(date) < 60 { return "cached just now" }
    return "cached "+date.formatted(.relative(presentation:.numeric,unitsStyle:.abbreviated))
}

struct PRAvatarPlaceholder:View {
    let name:String
    var size:CGFloat=22
    var team=false
    private var hue:Double { Double(name.lowercased().unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) % 3600 })/3600 }
    var body:some View {
        Circle().fill(Color(hue:hue,saturation:0.42,brightness:0.78))
            .frame(width:size,height:size)
            .overlay {
                if team { Image(systemName:"person.2.fill").font(.system(size:size*0.42,weight:.semibold)) }
                else { Text(name.first.map { String($0).uppercased() } ?? "?").font(.system(size:size*0.48,weight:.semibold,design:.rounded)) }
            }
            .foregroundStyle(.white).accessibilityHidden(true)
    }
}

struct PRReviewStateBadge:View {
    let state:PRReviewState?
    var requested=false
    var body:some View {
        let style=Self.style(state,requested:requested)
        HStack(spacing:4) {
            Image(systemName:style.symbol).accessibilityHidden(true)
            Text(style.text).strikethrough(state == .dismissed)
        }
        .font(.system(size:11,weight:.semibold)).foregroundStyle(style.tint)
        .padding(.horizontal,8).padding(.vertical,3)
        .background(style.tint.opacity(0.10),in:Capsule()).fixedSize()
        .accessibilityElement(children:.combine)
    }
    static func style(_ state:PRReviewState?,requested:Bool) -> (text:String,symbol:String,tint:Color) {
        switch state {
        case .approved?:("Approved","checkmark.circle.fill",.green)
        case .changesRequested?:("Changes requested","exclamationmark.circle.fill",.red)
        case .commented?:("Commented","text.bubble",Color.secondary)
        case .dismissed?:("Dismissed","xmark.circle",Color.secondary)
        case .pending?:("Pending","clock",.orange)
        case .unknown?:("Unknown state","questionmark.circle",Color.secondary)
        case nil:requested ? ("Awaiting review","clock",.orange) : ("No review","circle.dashed",Color.secondary)
        }
    }
}

struct PRPickerOption:Identifiable,Hashable {
    let id:String
    let title:String
    var detail:String? = nil
    var team=false
}
/// Searchable multi-select list; the caller orders options and owns the selection, and learns through `filterFocus`
/// when the filter is being typed in (its Apply button then drops Return, so Return never applies a half-typed filter).
struct PRMultiSelectList:View {
    let options:[PRPickerOption]
    @Binding var selection:Set<String>
    var prompt="Filter"
    var identifier="prPicker"
    let filterFocus:FocusState<Bool>.Binding
    @State private var query=""
    private var visible:[PRPickerOption] {
        let text=query.trimmingCharacters(in:.whitespaces)
        return text.isEmpty ? options : options.filter { $0.title.localizedCaseInsensitiveContains(text) || $0.detail?.localizedCaseInsensitiveContains(text) == true }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            TextField(prompt,text:$query).textFieldStyle(.roundedBorder).focused(filterFocus).accessibilityIdentifier(identifier+"Filter")
            List {
                ForEach(visible) { option in
                    Toggle(isOn:Binding(get:{ selection.contains(option.id) },set:{ on in if on { selection.insert(option.id) } else { selection.remove(option.id) } })) {
                        HStack(spacing:8) {
                            PRAvatarPlaceholder(name:option.title,size:18,team:option.team)
                            Text(option.title).lineLimit(1)
                            if let detail=option.detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }.toggleStyle(.checkbox)
                }
                if visible.isEmpty { Text(query.isEmpty ? "No options available" : "No matches").foregroundStyle(.secondary) }
            }.listStyle(.bordered).frame(minHeight:170).accessibilityIdentifier(identifier)
        }
    }
}

// MARK: Assignees

/// Assignees as ONE delta write by node ID; unrelated concurrent changes survive.
struct PRAssigneePicker:View {
    let account:PRDetailAccountModel
    var didWrite:() -> Void = {}
    @State private var selection:Set<String>=[]
    @State private var baseline:Set<String>?
    @State private var busy=false
    @State private var unresolved=false
    @State private var message:String?
    /// Return in the filter only filters; ⌘Return or the button applies.
    @FocusState private var filtering:Bool
    private var canApply:Bool { !busy && !unresolved && account.options?.canAssign == true && delta(account.options) != nil }
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack { Text("Assignees").font(.headline);Spacer();if !account.login.isEmpty { Text("as \(account.login)").font(.caption).foregroundStyle(.secondary) } }
            if let options=account.options {
                if !options.canAssign { WorkspaceNotice(message:"This account cannot assign people on this pull request.",symbol:"lock",tint:.orange) }
                if !options.assigneesComplete { Text("This pull request has more than 100 assignees; unlisted assignees are kept.").font(.caption).foregroundStyle(.orange) }
                PRMultiSelectList(options:candidates(options),selection:$selection,prompt:"Filter people",identifier:"assigneePicker",filterFocus:$filtering)
                if !options.assignableUsersComplete { Text("Showing the first 100 assignable users; assign others on GitHub.").font(.caption).foregroundStyle(.secondary) }
                Text(summary(options)).font(.caption).foregroundStyle(.secondary)
            } else if account.optionsLoading { ProgressView("Reading assignable people…").controlSize(.small).frame(maxWidth:.infinity,minHeight:120) }
            else {
                WorkspaceNotice(message:account.optionsError ?? "Assignable people are not loaded.",symbol:"exclamationmark.triangle",tint:.orange)
                Button("Retry") { Task { await account.loadOptions() } }.controlSize(.small)
            }
            if let message { Text(message).font(.caption).textSelection(.enabled) }
            HStack {
                Button("Reread") { unresolved=false;Task { await account.loadOptions() } }.disabled(busy || account.optionsLoading)
                Spacer()
                Button("Apply assignees") { Task { await apply() } }.buttonStyle(.borderedProminent).keyboardShortcut(filtering ? nil : .defaultAction)
                    .disabled(!canApply).help("Apply assignees (⌘Return)").accessibilityIdentifier("applyAssignees")
            }.controlSize(.small)
            .background { Button("Apply assignees") { if canApply { Task { await apply() } } }.keyboardShortcut(.return,modifiers:.command).hidden().accessibilityHidden(true) }
        }
        .task(id:account.epoch) { if account.options == nil { await account.loadOptions() };sync() }
        .onChange(of:account.options) { sync() }
    }
    private func sync() {
        guard let options=account.options else { return }
        let current=Set(options.assignees.map(\.id))
        if baseline != current { baseline=current;selection=current }
    }
    private func candidates(_ options:PRMetadataOptions) -> [PRPickerOption] {
        let current=Set(options.assignees.map(\.id))
        var seen=Set<String>()
        return (options.assignees+options.assignableUsers).filter { seen.insert($0.id).inserted }
            .sorted { (current.contains($0.id) ? 0 : 1,$0.login.lowercased()) < (current.contains($1.id) ? 0 : 1,$1.login.lowercased()) }
            .map { PRPickerOption(id:$0.id,title:$0.login,detail:current.contains($0.id) ? "assigned" : nil) }
    }
    private func delta(_ options:PRMetadataOptions?) -> (add:[PRUserRef],remove:[PRUserRef])? {
        guard let options,let baseline else { return nil }
        var refs:[String:PRUserRef]=[:]
        for ref in options.assignees+options.assignableUsers { refs[ref.id]=ref }
        let add=selection.subtracting(baseline).compactMap { refs[$0] }.sorted { $0.login < $1.login }
        let remove=baseline.subtracting(selection).compactMap { refs[$0] }.sorted { $0.login < $1.login }
        return add.isEmpty && remove.isEmpty ? nil : (add,remove)
    }
    private func summary(_ options:PRMetadataOptions) -> String {
        guard let change=delta(options) else { return "No changes. Toggle people, then apply once." }
        return (change.add.isEmpty ? "" : "Add "+change.add.map(\.login).joined(separator:", "))+(change.add.isEmpty || change.remove.isEmpty ? "" : " · ")+(change.remove.isEmpty ? "" : "Remove "+change.remove.map(\.login).joined(separator:", "))
    }
    private func apply() async {
        guard let change=delta(account.options) else { return }
        busy=true;defer { busy=false }
        let outcome=await account.perform(.metadata(.assigneeChanges(add:change.add,remove:change.remove)))
        message=outcome.message
        if outcome.state == .confirmed { await account.loadOptions();didWrite() } else if outcome.state != nil { unresolved=true }
    }
}

// MARK: Review requests

/// Request or remove reviewers as ONE delta write; re-requesting a reviewer adds them again.
struct PRReviewerRequestPicker:View {
    let account:PRDetailAccountModel
    var author:String? = nil
    var didWrite:() -> Void = {}
    @State private var selection:Set<String>=[]
    @State private var baseline:Set<String>?
    @State private var busy=false
    @State private var unresolved=false
    @State private var message:String?
    /// Return in the filter only filters; ⌘Return or the button applies.
    @FocusState private var filtering:Bool
    private var canApply:Bool { !busy && !unresolved && account.administration?.canRequestReviews == true && account.administration.flatMap(delta) != nil }
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack { Text("Request reviewers").font(.headline);Spacer();if !account.login.isEmpty { Text("as \(account.login)").font(.caption).foregroundStyle(.secondary) } }
            if let administration=account.administration {
                if !administration.canRequestReviews { WorkspaceNotice(message:"This account needs triage or write access to request reviews.",symbol:"lock",tint:.orange) }
                if !administration.requestsComplete { Text("More than 100 requests exist; unlisted requests are kept.").font(.caption).foregroundStyle(.orange) }
                PRMultiSelectList(options:candidates(administration),selection:$selection,prompt:"Filter people and teams",identifier:"reviewerPicker",filterFocus:$filtering)
                if account.options == nil { Text(account.optionsLoading ? "Reading requestable people…" : (account.optionsError.map { "Requestable people unavailable: "+$0 } ?? "Requestable people not loaded.")).font(.caption).foregroundStyle(.secondary) }
                else if account.options?.assignableUsersComplete == false { Text("Showing the first 100 collaborators. Request others, or new teams, on GitHub.").font(.caption).foregroundStyle(.secondary) }
                else { Text("New team requests are made on GitHub; requested teams can be removed here.").font(.caption).foregroundStyle(.secondary) }
                Text(summary(administration)).font(.caption).foregroundStyle(.secondary)
            } else if account.administrationLoading { ProgressView("Reading review requests…").controlSize(.small).frame(maxWidth:.infinity,minHeight:120) }
            else {
                WorkspaceNotice(message:account.administrationError ?? "Review requests are not loaded.",symbol:"exclamationmark.triangle",tint:.orange)
                Button("Retry") { Task { await account.loadAdministration() } }.controlSize(.small)
            }
            if let message { Text(message).font(.caption).textSelection(.enabled) }
            HStack {
                Button("Reread") { unresolved=false;Task { await account.loadAdministration();await account.loadOptions() } }.disabled(busy || account.administrationLoading)
                Spacer()
                Button("Apply requests") { Task { await apply() } }.buttonStyle(.borderedProminent).keyboardShortcut(filtering ? nil : .defaultAction)
                    .disabled(!canApply).help("Apply review requests (⌘Return)").accessibilityIdentifier("applyReviewRequests")
            }.controlSize(.small)
            .background { Button("Apply requests") { if canApply { Task { await apply() } } }.keyboardShortcut(.return,modifiers:.command).hidden().accessibilityHidden(true) }
        }
        .task(id:account.epoch) {
            if account.administration == nil { await account.loadAdministration() }
            sync()
            if account.options == nil { await account.loadOptions() }
        }
        .onChange(of:account.administration) { sync() }
    }
    private func sync() {
        guard let administration=account.administration else { return }
        let current=Set(administration.requestedUsers.map(\.id)+administration.requestedTeams.map(\.id))
        if baseline != current { baseline=current;selection=current }
    }
    private func users(_ administration:PRReviewAdministration) -> [String:PRUserRef] {
        var refs:[String:PRUserRef]=[:]
        for ref in (account.options?.assignableUsers ?? [])+administration.reviews.compactMap({ review in review.authorID.flatMap { id in review.authorLogin.map { PRUserRef(id:id,login:$0) } } })+administration.requestedUsers { refs[ref.id]=ref }
        if let author { refs=refs.filter { $0.value.login.lowercased() != author.lowercased() } }
        return refs
    }
    private func candidates(_ administration:PRReviewAdministration) -> [PRPickerOption] {
        let requested=Set(administration.requestedUsers.map(\.id)+administration.requestedTeams.map(\.id))
        let reviewed=Set(administration.reviews.compactMap(\.authorID))
        let people=users(administration).values.sorted { (requested.contains($0.id) ? 0 : 1,$0.login.lowercased()) < (requested.contains($1.id) ? 0 : 1,$1.login.lowercased()) }
            .map { PRPickerOption(id:$0.id,title:$0.login,detail:requested.contains($0.id) ? "requested" : reviewed.contains($0.id) ? "reviewed · select to re-request" : nil) }
        return administration.requestedTeams.map { PRPickerOption(id:$0.id,title:$0.slug,detail:"team · requested",team:true) }+people
    }
    private func delta(_ administration:PRReviewAdministration) -> (users:[PRUserRef],teams:[PRTeamRef],removeUsers:[PRUserRef],removeTeams:[PRTeamRef])? {
        guard let baseline else { return nil }
        let people=users(administration),teams=Dictionary(administration.requestedTeams.map { ($0.id,$0) },uniquingKeysWith:{ first,_ in first })
        let added=selection.subtracting(baseline),removed=baseline.subtracting(selection)
        let value=(added.compactMap { people[$0] }.sorted { $0.login < $1.login },added.compactMap { teams[$0] },
                   removed.compactMap { id in administration.requestedUsers.first { $0.id == id } }.sorted { $0.login < $1.login },removed.compactMap { teams[$0] })
        return value.0.isEmpty && value.1.isEmpty && value.2.isEmpty && value.3.isEmpty ? nil : value
    }
    private func summary(_ administration:PRReviewAdministration) -> String {
        guard let change=delta(administration) else { return "No changes. Toggle reviewers, then apply once." }
        let add=change.users.map(\.login)+change.teams.map(\.slug),remove=change.removeUsers.map(\.login)+change.removeTeams.map(\.slug)
        return (add.isEmpty ? "" : "Request "+add.joined(separator:", "))+(add.isEmpty || remove.isEmpty ? "" : " · ")+(remove.isEmpty ? "" : "Remove "+remove.joined(separator:", "))
    }
    private func apply() async {
        guard let administration=account.administration,let change=delta(administration) else { return }
        busy=true;defer { busy=false }
        let outcome=await account.perform(.metadata(.reviewRequestChanges(addUsers:change.users,addTeams:change.teams,removeUsers:change.removeUsers,removeTeams:change.removeTeams)))
        message=outcome.message
        if outcome.state == .confirmed { await account.loadAdministration();didWrite() } else if outcome.state != nil { unresolved=true }
    }
}

// MARK: Reviewers panel

struct PRReviewerRow:Identifiable {
    let id:String
    let login:String
    let userID:String?
    let team:Bool
    let review:PRReviewSummary?
    let requested:Bool
    /// Latest decisive review per author (a later comment never hides an approval, change request or
    /// dismissal), then outstanding user and team requests.
    static func rows(_ administration:PRReviewAdministration) -> [PRReviewerRow] {
        var latest:[String:PRReviewSummary]=[:]
        for review in administration.reviews {
            let key=(review.authorLogin ?? "unknown reviewer").lowercased()
            if let existing=latest[key],[.approved,.changesRequested,.dismissed].contains(existing.state),[.commented,.pending,.unknown].contains(review.state) { continue }
            latest[key]=review
        }
        var rows=latest.map { key,review in
            let request=administration.requestedUsers.first { $0.login.lowercased() == key || $0.id == review.authorID }
            return PRReviewerRow(id:"user:"+key,login:review.authorLogin ?? "Unknown reviewer",userID:review.authorID ?? request?.id,team:false,review:review,requested:request != nil)
        }
        rows += administration.requestedUsers.filter { latest[$0.login.lowercased()] == nil }.map { PRReviewerRow(id:"user:"+$0.login.lowercased(),login:$0.login,userID:$0.id,team:false,review:nil,requested:true) }
        rows.sort { $0.login.lowercased() < $1.login.lowercased() }
        return rows+administration.requestedTeams.map { PRReviewerRow(id:"team:"+$0.id,login:$0.slug,userID:$0.id,team:true,review:nil,requested:true) }
    }
}
/// Reviewer rows with Re-request and Dismiss…, from ONE action-account read. Until it loads (or when it
/// fails) the read-only overview context is shown, labeled as such.
struct PRReviewersPanel:View {
    let pr:PullRequest
    let account:PRDetailAccountModel
    let context:PROverviewContext?
    var didWrite:() -> Void = {}
    @State private var requesting=false
    @State private var dismissing:PRReviewSummary?
    @State private var busy:Set<String>=[]
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:8) {
                Label("Reviewers",systemImage:"person.2").font(.headline)
                if let decision=account.administration?.reviewDecision { Text(decision.replacingOccurrences(of:"_",with:" ").capitalized).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
                Spacer()
                if account.administrationLoading { ProgressView().controlSize(.small) }
                Button("Request reviewers…",systemImage:"person.badge.plus") { requesting=true }
                    .disabled(account.administration?.canRequestReviews != true).accessibilityIdentifier("requestReviewers")
                    .popover(isPresented:$requesting,arrowEdge:.bottom) {
                        PRReviewerRequestPicker(account:account,author:pr.metadata?.authorLogin,didWrite:{ account.status="Review requests updated.";didWrite() }).padding(14).frame(width:380,height:430)
                    }
                Button("Reread reviewers",systemImage:"arrow.clockwise") { Task { await account.loadAdministration() } }.labelStyle(.iconOnly).disabled(account.administrationLoading).help("Read reviewers with the action account")
            }.controlSize(.small)
            if let administration=account.administration {
                let rows=PRReviewerRow.rows(administration)
                if rows.isEmpty { Text(administration.reviewsComplete && administration.requestsComplete ? "No reviewers" : "Reviewers unknown or incomplete").foregroundStyle(.secondary) }
                ForEach(rows) { row in reviewerRow(row,administration:administration) }
                if !administration.reviewsComplete { Text("Older reviews exist; rows use the newest 100 reviews.").font(.caption).foregroundStyle(.secondary) }
                if !administration.requestsComplete { Text("More than 100 review requests; the list is partial.").font(.caption).foregroundStyle(.secondary) }
                if let pending=administration.pendingReview { Text("You have a pending review\(pending.commitOID.map { " on \($0.prefix(8))" } ?? ""). Continue or discard it from Approve, Request changes or Comment.").font(.caption).foregroundStyle(.orange) }
            } else {
                if let error=account.administrationError { WorkspaceNotice(message:"Reviewer actions unavailable: "+error,symbol:"exclamationmark.triangle",tint:.orange) }
                if let context {
                    if context.reviewers.isEmpty { Text(context.reviewersComplete ? "No reviewers" : "Reviewers unknown or incomplete").foregroundStyle(.secondary) }
                    ForEach(Array(context.reviewers.enumerated()),id:\.offset) { _,reviewer in
                        HStack(spacing:8) {
                            PRAvatarPlaceholder(name:reviewer.name)
                            Text(reviewer.name).fontWeight(.medium)
                            PRReviewStateBadge(state:reviewer.state.map { PRReviewState(rawValue:$0) ?? .unknown },requested:reviewer.requested)
                            if reviewer.requested,reviewer.state != nil { Text("Review requested").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if !context.reviewersComplete { Text("Reviewer history is partial (up to 100 latest reviewer states and 100 requests).").font(.caption).foregroundStyle(.secondary) }
                } else if !account.administrationLoading { Text("Reviewers unknown").foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth:.infinity,alignment:.leading).padding(18).workspacePanel(radius:16)
        .sheet(item:$dismissing) { review in PRDismissReviewSheet(review:review,account:account,dismissed:didWrite) }
    }
    private func reviewerRow(_ row:PRReviewerRow,administration:PRReviewAdministration) -> some View {
        HStack(spacing:8) {
            PRAvatarPlaceholder(name:row.login,team:row.team)
            Text(row.login).fontWeight(.medium).lineLimit(1).textSelection(.enabled)
            if row.team { Text("team").font(.caption).foregroundStyle(.secondary) }
            PRReviewStateBadge(state:row.review?.state,requested:row.requested)
            if row.requested,row.review != nil { Text("Re-requested").font(.caption).foregroundStyle(.secondary) }
            if let date=row.review?.submittedAt { Text(date.formatted(.relative(presentation:.named))).font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength:8)
            if let review=row.review,!row.team,!row.requested,review.state != .pending,let id=row.userID,row.login.lowercased() != pr.metadata?.authorLogin?.lowercased() {
                Button("Re-request") { Task { await rerequest(PRUserRef(id:id,login:row.login),row:row.id) } }
                    .disabled(!administration.canRequestReviews || busy.contains(row.id)).help(administration.canRequestReviews ? "Ask \(row.login) to review again" : "This account cannot request reviews")
                    .accessibilityIdentifier("rerequest-"+row.login)
            }
            if let review=row.review,[.approved,.changesRequested].contains(review.state),review.viewerCanDismiss != false {
                Button("Dismiss…") { dismissing=review }.help(review.viewerCanDismiss == nil ? "Permission unknown; GitHub decides when you submit." : "Dismiss this review with a message")
                    .accessibilityIdentifier("dismiss-"+row.login)
            }
        }.controlSize(.small)
    }
    private func rerequest(_ user:PRUserRef,row:String) async {
        busy.insert(row);defer { busy.remove(row) }
        let outcome=await account.perform(.metadata(.reviewRequestChanges(addUsers:[user],addTeams:[],removeUsers:[],removeTeams:[])))
        account.status=outcome.state == .confirmed ? "Review re-requested from \(user.login)." : outcome.message
        if outcome.state == .confirmed { await account.loadAdministration();didWrite() }
    }
}

struct PRDismissReviewSheet:View {
    let review:PRReviewSummary
    let account:PRDetailAccountModel
    var dismissed:() -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var message=""
    @State private var busy=false
    @State private var sent=false
    @State private var status:String?
    /// Return in the message inserts a newline; it must never reach the dismiss button.
    @FocusState private var messageFocused:Bool
    private var trimmed:String { message.trimmingCharacters(in:.whitespacesAndNewlines) }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Dismiss review").font(.system(.title2,design:.rounded).bold())
            Text("Dismiss \(review.authorLogin ?? "this reviewer")'s \(PRReviewStateBadge.style(review.state,requested:false).text.lowercased()) review as \(account.login.isEmpty ? "the action account" : account.login). GitHub shows your message on the pull request, and the review no longer counts toward merge requirements.").fixedSize(horizontal:false,vertical:true)
            if review.viewerCanDismiss == nil { Text("Permission unknown: branch protection may restrict dismissals. GitHub decides when you submit.").font(.caption).foregroundStyle(.orange) }
            TextEditor(text:$message).font(.body).frame(height:110).border(.separator).focused($messageFocused).accessibilityLabel("Dismissal message").accessibilityIdentifier("dismissReviewMessage")
            Text("A message is required.").font(.caption).foregroundStyle(.secondary)
            if let status { WorkspaceNotice(message:status,symbol:"info.circle",tint:sent ? .orange : .secondary) }
            HStack {
                Button(sent ? "Close" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Dismiss review",role:.destructive) { Task { await submit() } }.buttonStyle(.borderedProminent).keyboardShortcut(messageFocused ? nil : .defaultAction)
                    .disabled(busy || sent || trimmed.isEmpty).accessibilityIdentifier("confirmDismissReview")
            }
        }.padding(20).frame(width:500)
    }
    private func submit() async {
        busy=true;defer { busy=false }
        let outcome=await account.perform(.dismissReview(reviewID:review.id,message:trimmed))
        if outcome.state == .confirmed {
            account.status="Dismissed \(review.authorLogin ?? "the") review.";await account.loadAdministration();dismissed();dismiss()
        } else { status=outcome.message;sent=outcome.state != nil }
    }
}

// MARK: Header controls

/// Subscribed / Not subscribed / Ignoring through `.subscription`; unknown is shown, not guessed.
struct PRSubscriptionMenu:View {
    let account:PRDetailAccountModel
    @State private var busy=false
    var body:some View {
        let current=account.administration?.viewerSubscription
        Menu {
            ForEach(PRSubscriptionState.allCases,id:\.self) { state in
                Button { Task { await change(state) } } label: { Label(Self.title(state),systemImage:current == state ? "checkmark" : Self.symbol(state)) }
                    .disabled(busy || current == state || account.administration?.canSubscribe != true)
            }
            Divider()
            Button("Reread subscription") { Task { await account.loadAdministration() } }
        } label: {
            Label(title,systemImage:current.map(Self.symbol) ?? "bell.badge").labelStyle(.iconOnly)
        }
        .fixedSize().help(account.administration?.canSubscribe == false ? "This account cannot subscribe to this pull request." : "Notifications: "+title)
        .accessibilityLabel("Notifications: "+title).accessibilityIdentifier("prSubscription")
    }
    private var title:String { account.administration?.viewerSubscription.map(Self.title) ?? (account.administrationLoading ? "Reading subscription…" : "Subscription unknown") }
    static func title(_ state:PRSubscriptionState) -> String { switch state { case .subscribed:"Subscribed";case .unsubscribed:"Not subscribed";case .ignored:"Ignoring" } }
    static func symbol(_ state:PRSubscriptionState) -> String { switch state { case .subscribed:"bell.fill";case .unsubscribed:"bell";case .ignored:"bell.slash" } }
    private func change(_ state:PRSubscriptionState) async {
        busy=true;defer { busy=false }
        let outcome=await account.perform(.subscription(state:state))
        account.status=outcome.state == .confirmed ? "Notifications: \(Self.title(state))." : outcome.message
        if outcome.state == .confirmed { await account.loadAdministration() }
    }
}

/// Delete or restore the head branch of a merged/closed same-repository PR, decided by a fresh branch read.
struct PRHeadBranchControl:View {
    let pr:PullRequest
    let account:PRDetailAccountModel
    var didWrite:() -> Void = {}
    private enum Phase:Equatable { case loading,present(RepositoryBranch),absent,pending(RepositoryPendingWrite),failed(String) }
    private enum Op:Equatable { case delete,restore }
    /// Captured when the dialog opens: the confirmed operation runs as-is, under the same account epoch, or not at all.
    private struct Confirmation:Equatable { let op:Op;let epoch:UUID }
    @State private var phase:Phase = .loading
    @State private var confirming:Confirmation?
    @State private var busy=false
    private var branchName:String { pr.metadata?.headBranch ?? "" }
    var body:some View {
        Group {
            switch phase {
            case .loading:
                HStack(spacing:6) { ProgressView().controlSize(.mini);Text("Branch…").foregroundStyle(.secondary) }
            case .present(let branch):
                Button("Delete branch",systemImage:"trash",role:.destructive) { confirming=Confirmation(op:.delete,epoch:account.epoch) }.disabled(busy || branch.protected)
                    .help(branch.protected ? "\(branch.name) is protected." : "Delete \(branch.name)").accessibilityIdentifier("deleteHeadBranch")
            case .absent:
                Button("Restore branch",systemImage:"arrow.uturn.backward") { confirming=Confirmation(op:.restore,epoch:account.epoch) }.disabled(busy)
                    .help("Recreate \(branchName) at \(pr.headRevision.rawValue.prefix(8))").accessibilityIdentifier("restoreHeadBranch")
            case .pending(let write):
                Menu("Branch change unconfirmed",systemImage:"exclamationmark.triangle") {
                    if write.unsent { Button("Release unsent change") { Task { await release(write) } } }
                    else { Button("Read provider result") { Task { await reconcile(write) } } }
                }.fixedSize().disabled(busy)
            case .failed(let message):
                Button("Branch status unknown",systemImage:"questionmark.circle") { Task { await read() } }.help(message+" Click to read again.")
            }
        }
        .confirmationDialog(confirming?.op == .restore ? "Restore branch \(branchName)?" : "Delete branch \(branchName)?",isPresented:Binding(get:{ confirming != nil },set:{ if !$0 { confirming=nil } }),titleVisibility:.visible,presenting:confirming) { confirmed in
            Button(confirmed.op == .delete ? "Delete branch" : "Restore branch",role:confirmed.op == .delete ? .destructive : nil) { Task { await change(confirmed) } }
            Button("Cancel",role:.cancel) {}
        } message: { confirmed in
            Text(confirmed.op == .delete ? "GitHub deletes \(branchName) only while it still points at this pull request's head. You can restore it later." : "Recreates \(branchName) at \(pr.headRevision.rawValue.prefix(8)) in this repository.")
        }
        .task(id:account.epoch) { await read() }
    }
    /// Whether the last read still shows the state the confirmed operation was offered for.
    private func applies(_ op:Op) -> Bool {
        switch (op,phase) {
        case (.delete,.present(let branch)):!branch.protected
        case (.restore,.absent):true
        default:false
        }
    }
    private func read() async {
        phase = .loading
        guard let actionPR=await account.resolve() else { phase = .failed(account.actionError ?? "Action account unavailable.");return }
        do {
            if let write=try await account.storage.detailPendingWrites(actionPR).first(where:{ $0.kind.hasPrefix("branch-") }) { phase = .pending(write);return }
            let branch=try await account.storage.detailHeadBranch(actionPR)
            guard !Task.isCancelled else { return }
            phase=branch.map { .present($0) } ?? .absent
        } catch { if !Task.isCancelled { phase = .failed(prDetailErrorMessage(error)) } }
    }
    private func change(_ confirmed:Confirmation) async {
        let deleting=confirmed.op == .delete,refusal="The branch or action account changed before the confirmed \(deleting ? "delete" : "restore") ran. Nothing was sent; review the branch and try again."
        guard !busy else { return }
        busy=true;defer { busy=false }
        guard let actionPR=await account.resolve() else { account.status=account.actionError ?? "Action account unavailable.";return }
        // Never re-derived here: a changed account or branch state refuses rather than running the opposite.
        guard account.epoch == confirmed.epoch,applies(confirmed.op) else { account.status=refusal;await read();return }
        do {
            if deleting { try await account.storage.deleteDetailHeadBranch(actionPR) } else { try await account.storage.restoreDetailHeadBranch(actionPR) }
            account.status=deleting ? "Deleted branch \(branchName)." : "Restored branch \(branchName)."
            didWrite()
        } catch { account.status=prDetailErrorMessage(error) }
        await read()
    }
    private func mutation(_ write:RepositoryPendingWrite) -> RepositoryBranchMutation {
        let sha=pr.headRevision.rawValue.lowercased()
        if write.kind == "branch-delete",let last=write.identity.split(separator:"|").last { return .delete(name:branchName,sha:String(last)) }
        return write.kind == "branch-delete" ? .delete(name:branchName,sha:sha) : .create(name:branchName,sha:sha)
    }
    private func reconcile(_ write:RepositoryPendingWrite) async {
        guard let actionPR=await account.resolve() else { return }
        busy=true;defer { busy=false }
        do {
            let result=try await account.storage.reconcileDetailBranch(actionPR,mutation:mutation(write))
            account.status=result == .applied ? "GitHub shows the branch change was applied." : "GitHub shows the branch change was not applied. You can try again."
            if result == .applied { didWrite() }
        } catch { account.status=prDetailErrorMessage(error) }
        await read()
    }
    private func release(_ write:RepositoryPendingWrite) async {
        guard let actionPR=await account.resolve() else { return }
        busy=true;defer { busy=false }
        do { try await account.storage.releaseDetailPendingWrite(actionPR,identity:write.identity);account.status="Released the unsent branch change." }
        catch { account.status=prDetailErrorMessage(error) }
        await read()
    }
}

/// GraphQL revert of a merged PR. An already-open revert is reused; a lost receipt is reconciled, never resent.
struct PRRevertSheet:View {
    let pr:PullRequest
    let account:PRDetailAccountModel
    var created:(RepositoryRevertResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title=""
    @State private var text=""
    @State private var draft=false
    @State private var busy=false
    @State private var status:String?
    @State private var pending:RepositoryPendingWrite?
    @State private var unknownOutcome=false
    /// Return in the title moves to the description, and in the description inserts a newline; neither creates the revert.
    @FocusState private var focus:Field?
    private enum Field:Hashable { case title,body }
    private var number:Int { pr.metadata?.number ?? 0 }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Revert pull request").font(.system(.title2,design:.rounded).bold())
            Text("Opens a new pull request that reverts #\(String(number)) into \(pr.metadata?.baseBranch ?? "its base branch")\(account.login.isEmpty ? "" : ", as \(account.login)").").foregroundStyle(.secondary)
            TextField("Title",text:$title).textFieldStyle(.roundedBorder).focused($focus,equals:.title).onSubmit { focus = .body }.accessibilityIdentifier("revertTitle")
            TextEditor(text:$text).font(.body).frame(height:140).border(.separator).focused($focus,equals:.body).accessibilityLabel("Revert description").accessibilityIdentifier("revertBody")
            Toggle("Create as draft",isOn:$draft).toggleStyle(.checkbox).accessibilityIdentifier("revertDraft")
            if let pending {
                HStack {
                    Label(pending.unsent ? "A revert was prepared but never sent." : "A previous revert attempt has an unknown outcome.",systemImage:"exclamationmark.triangle").foregroundStyle(.orange)
                    Spacer()
                    if pending.unsent { Button("Release unsent revert") { Task { await release(pending) } }.disabled(busy) }
                    else { Button("Read provider result") { Task { await reconcile() } }.disabled(busy) }
                }.font(.callout).controlSize(.small)
            }
            if let status { WorkspaceNotice(message:status,symbol:unknownOutcome ? "exclamationmark.triangle" : "info.circle",tint:unknownOutcome ? .orange : .secondary) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Create revert pull request") { Task { await submit() } }.buttonStyle(.borderedProminent).keyboardShortcut(focus == nil ? .defaultAction : nil)
                    .disabled(busy || pending != nil || unknownOutcome || title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).accessibilityIdentifier("confirmRevert")
            }
        }.padding(20).frame(width:560)
        .task {
            title="Revert \"\(pr.title)\"";text="Reverts \(pr.metadata?.repositoryName ?? "")#\(String(number))"
            await readPending()
        }
    }
    private func readPending() async {
        guard let actionPR=await account.resolve() else { status=account.actionError;return }
        pending=try? await account.storage.detailPendingWrites(actionPR).first { $0.kind == "pr-revert" }
    }
    private func submit() async {
        guard let actionPR=await account.resolve() else { status=account.actionError;return }
        busy=true;defer { busy=false }
        do {
            let result=try await account.storage.revertDetailPullRequest(actionPR,title:title,body:text,draft:draft)
            account.status=result.existing ? "An open revert pull request #\(String(result.number)) already exists; opened it." : "Created revert pull request #\(String(result.number))."
            created(result);dismiss()
        } catch {
            unknownOutcome=error as? RepositoryBrowserFailure == .unknownWriteOutcome
            status=prDetailErrorMessage(error)
            await readPending()
        }
    }
    private func reconcile() async {
        guard let actionPR=await account.resolve() else { return }
        busy=true;defer { busy=false }
        do {
            let result=try await account.storage.reconcileDetailRevert(actionPR)
            unknownOutcome=false
            status=result == .applied ? "GitHub shows the revert pull request was created. Refresh the repository to open it, or open the pull requests list on GitHub." : "GitHub shows no revert was created. You can create it now."
        } catch { status=prDetailErrorMessage(error) }
        await readPending()
    }
    private func release(_ write:RepositoryPendingWrite) async {
        guard let actionPR=await account.resolve() else { return }
        busy=true;defer { busy=false }
        do { try await account.storage.releaseDetailPendingWrite(actionPR,identity:write.identity);status="Released the unsent revert." } catch { status=prDetailErrorMessage(error) }
        await readPending()
    }
}
