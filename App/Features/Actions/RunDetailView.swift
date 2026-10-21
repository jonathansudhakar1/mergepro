import AppKit
import SwiftUI
import MergeProCore
struct RunDetailView:View {
    let storage:SetupStorage
    let run:WorkflowRun
    var onOpenAnnotation:((Repository,String,String,Int)->Void)?=nil
    var refreshID:UUID = UUID(uuidString:"00000000-0000-0000-0000-000000000000")!
    @Environment(\.dismiss) private var dismiss
    @State private var detail:ActionsRunDetail?
    @State private var selectedJob:ActionsJob?
    @State private var selectedStep:ActionsStep?
    @State private var log:ActionsLogAvailability?
    @State private var loading=false
    @State private var writing=false
    @State private var loadingSupplementary=false
    @State private var error:String?
    @State private var status:String?
    /// Poll, manual and post-write refreshes overlap; only the newest may publish detail or clear loading.
    @State private var refreshRequest=UUID()
    @State private var receipt:ActionsWriteOperation?
    @State private var showDeploymentReview=false
    /// Environments as read when the review sheet opened, so a background refresh cannot empty an open review.
    @State private var reviewEnvironments:[ActionsEnvironment]=[]
    /// Run commands act on the provider's current state, so they stay disabled until this view has read it once.
    @State private var freshRun=false
    @State private var confirming:RunCommandConfirmation?
    @State private var logSearch=""
    @State private var logRequest=ActionsLogRequestState()
    private var loadingLog:Bool { logRequest.isLoading }
    private var currentRun:WorkflowRun { detail?.run ?? run }
    var body:some View {
        VStack(spacing:0) {
            WorkspaceSectionHeader(title:run.name,subtitle:run.repository.name+" · "+run.branch+" · attempt \(run.attempt)",symbol:"play.rectangle.fill") {
                if let url=run.webURL { Link("Open on GitHub",destination:url) }
                Button("Refresh",systemImage:"arrow.clockwise") { Task { await refresh() } }.disabled(loading)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ViewThatFits(in:.horizontal) {
                HStack(spacing:12) { runSummary;Spacer(minLength:8);runControls }
                VStack(alignment:.leading,spacing:12) { runSummary;runControls }
            }.padding(12).workspaceGlass().padding(.horizontal,24).padding(.bottom,16)
            if let error { WorkspaceNotice(message:error,symbol:"exclamationmark.triangle",tint:.orange).padding(.horizontal,24).padding(.bottom,12) }
            if let status { WorkspaceNotice(message:status,symbol:"checkmark.circle",tint:.green).padding(.horizontal,24).padding(.bottom,12) }
            if let receipt {
                VStack(alignment:.leading,spacing:8) {
                    WorkspaceNotice(message:receipt.message ?? ProviderStateText.actionsWrite(receipt.state),tint:receipt.state == .uncertain ? .orange:.secondary)
                    if receipt.state == .uncertain || receipt.state == .sending || receipt.state == .accepted {
                        Button("Reconcile") { Task { do { self.receipt=try await storage.actionsService().reconcile(receipt.id);await refresh() } catch { self.error=providerErrorMessage(error) } } }
                    }
                }.padding(.horizontal,24).padding(.bottom,12)
            }
            if let detail {
                if loadingSupplementary {
                    HStack(spacing:8) {
                        ProgressView().controlSize(.small)
                        Text("Loading artifacts, annotations and deployment reviews…").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }.padding(.horizontal,24).padding(.bottom,8)
                }
                if !detail.unavailableSections.isEmpty {
                    VStack(alignment:.leading,spacing:8) {
                        ForEach(detail.unavailableSections.keys.sorted(),id:\.self) { section in WorkspaceNotice(message:section+": "+(detail.unavailableSections[section] ?? ""),symbol:"exclamationmark.triangle",tint:.orange) }
                    }.padding(.horizontal,24).padding(.bottom,12)
                }
                HSplitView {
                    runSidebar(detail).frame(minWidth:220,idealWidth:310,maxWidth:420)
                    logPanel.padding(16).frame(minWidth:320,maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                }.padding(.horizontal,12).padding(.bottom,12)
            } else if loading { ProgressView("Loading run details").frame(maxWidth:.infinity,maxHeight:.infinity) }
            else { ContentUnavailableView("Run detail could not load",systemImage:"exclamationmark.triangle",description:Text("Refresh after checking account authorization and access.")) }
        }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        .background { WorkspaceCanvas() }.task(id:refreshID) { await refresh() }
        .onExitCommand { dismiss() }
        .sheet(isPresented:$showDeploymentReview,onDismiss:{ Task { await refresh() } }) { DeploymentApprovalSheet(storage:storage,run:run,environments:reviewEnvironments).frame(minWidth:440,idealWidth:560,maxWidth:640) }
        .confirmationDialog(confirming?.title ?? "",isPresented:Binding(get:{ confirming != nil },set:{ if !$0 { confirming=nil } }),titleVisibility:.visible,presenting:confirming) { command in
            switch command {
            case .cancel:
                Button("Cancel run",role:.destructive) { confirming=nil;Task { await perform(.cancel(runID:run.runID,attempt:run.attempt)) } }
                Button("Keep running",role:.cancel) { confirming=nil }
            case .approveFork:
                Button("Approve and run") { confirming=nil;Task { await perform(.approveFork(runID:run.runID,attempt:run.attempt)) } }
                Button("Don’t approve",role:.cancel) { confirming=nil }
            case .rerunAll,.rerunFailed:
                Button(command == .rerunAll ? "Re-run all jobs" : "Re-run failed jobs") {
                    confirming=nil
                    Task { await perform(command == .rerunAll ? .rerunAll(runID:run.runID,attempt:run.attempt) : .rerunFailed(runID:run.runID,attempt:run.attempt)) }
                }
                Button("Don’t re-run",role:.cancel) { confirming=nil }
            }
        } message: { command in
            switch command {
            case .cancel:Text(ActionsRunConfirmation.cancelMessage(currentRun))
            case .approveFork:Text(ActionsRunConfirmation.approveForkMessage(currentRun))
            case .rerunAll,.rerunFailed:Text(ActionsRunConfirmation.rerunMessage(currentRun,failedOnly:command == .rerunFailed))
            }
        }
    }
    private var runSummary:some View {
        HStack(spacing:12) {
            WorkspaceStatusBadge(text:ProviderStateText.actionsStatus(currentRun.conclusion ?? currentRun.status),tint:actionsStatusTint(currentRun.conclusion ?? currentRun.status))
            Text(String(run.headSHA.prefix(12))).font(.caption.monospaced()).foregroundStyle(.secondary)
            if loading { ProgressView().controlSize(.small) }
        }
    }
    private var runControls:some View {
        ViewThatFits(in:.horizontal) {
            HStack(spacing:10) { lifecycleControls; approvalControls }
            VStack(alignment:.leading,spacing:10) { lifecycleControls; approvalControls }
        }.disabled(writing || !freshRun)
    }
    @ViewBuilder private var lifecycleControls:some View {
        if currentRun.isActive { Button("Cancel run…") { confirming = .cancel } }
        else { HStack(spacing:10) { Button("Re-run all…") { confirming = .rerunAll };Button("Re-run failed…") { confirming = .rerunFailed } } }
    }
    @ViewBuilder private var approvalControls:some View {
        if currentRun.conclusion=="action_required" || currentRun.status=="waiting" { Button("Approve fork run…") { confirming = .approveFork } }
        // Pending environments are only shown once this refresh has read them for the current attempt.
        if !loadingSupplementary,let pending=detail?.pendingDeployments,!pending.isEmpty { Button("Review environments…") { reviewEnvironments=pending;showDeploymentReview=true } }
    }
    private func runSidebar(_ detail:ActionsRunDetail) -> some View {
        List {
            Section("Jobs") {
                ForEach(detail.jobs) { job in
                    Button { selectedJob=job;selectedStep=nil;Task { await loadLog(job) } } label: {
                        VStack(alignment:.leading,spacing:8) {
                            Label(job.name,systemImage:job.conclusion=="success" ? "checkmark.circle.fill":job.conclusion=="failure" ? "xmark.circle.fill":"circle")
                                .font(.headline).foregroundStyle(selectedJob?.id==job.id ? DesignTokens.cobalt:Color.primary)
                            HStack { WorkspaceStatusBadge(text:ProviderStateText.actionsStatus(job.conclusion ?? job.status),tint:actionsStatusTint(job.conclusion ?? job.status));Spacer(minLength:4);ActionsElapsedView(started:job.startedAt,completed:job.completedAt,active:job.status=="in_progress",notStarted:job.status=="queued" || job.status=="pending") }
                        }.padding(.vertical,6).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if selectedJob?.id==job.id {
                        ForEach(job.steps) { step in
                            // Steps share their job's log; reload only when it is not already loaded or loading.
                            Button { selectedStep=step;if log==nil,!loadingLog { Task { await loadLog(job) } } } label: {
                                VStack(alignment:.leading,spacing:5) {
                                    Text("\(step.number). "+step.name).font(.callout).foregroundStyle(selectedStep?.number==step.number ? DesignTokens.cobalt:Color.primary)
                                    HStack { Text(ProviderStateText.actionsStatus(step.conclusion ?? step.status)).font(.caption).foregroundStyle(actionsStatusTint(step.conclusion ?? step.status));Spacer(minLength:4);ActionsElapsedView(started:step.startedAt,completed:step.completedAt,active:step.status=="in_progress",notStarted:step.status=="queued" || step.status=="pending") }
                                }.padding(.leading,16).padding(.vertical,4).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if detail.jobs.isEmpty { Text("No jobs are available yet.").font(.callout).foregroundStyle(.secondary) }
            }
            Section("Artifacts") {
                ForEach(detail.artifacts) { artifact in
                    VStack(alignment:.leading,spacing:6) {
                        Text(artifact.name).font(.headline)
                        HStack { Text(ByteCountFormatter.string(fromByteCount:artifact.size,countStyle:.file)).font(.caption).foregroundStyle(.secondary);Spacer();if artifact.expired { WorkspaceStatusBadge(text:"Expired") } }
                        Button("Download…") { Task { await download(artifact) } }.disabled(artifact.expired)
                    }.padding(.vertical,5)
                }
                if detail.artifacts.isEmpty { Text(loadingSupplementary ? "Loading artifacts…":"No artifacts for this run.").font(.callout).foregroundStyle(.secondary) }
            }
            if !detail.annotations.isEmpty {
                Section("Annotations") {
                    ForEach(detail.annotations) { annotation in
                        Button { openAnnotation(annotation) } label: {
                            VStack(alignment:.leading,spacing:5) { Text(annotation.title ?? annotation.level).font(.headline);Text(annotation.path+":\(annotation.startLine)").font(.caption.monospaced()).foregroundStyle(.secondary);Text(annotation.message).font(.caption) }.padding(.vertical,5)
                        }.buttonStyle(.plain)
                    }
                }
            }
            if !run.pullRequestNumbers.isEmpty { Section("Pull requests") { ForEach(run.pullRequestNumbers,id:\.self) { number in if let url=URL(string:"https://github.com/"+run.repository.name+"/pull/\(number)") { Link("Pull request #\(number)",destination:url) } } } }
        }.listStyle(.inset).scrollContentBackground(.hidden)
    }
    private var logPanel:some View {
        VStack(alignment:.leading,spacing:12) {
            if let selectedJob {
                VStack(alignment:.leading,spacing:5) {
                    Text(selectedJob.name).font(.title3.bold())
                    if let current=selectedJob.steps.first(where:{ $0.status=="in_progress" }) { Text("Running step: "+current.name).font(.caption).foregroundStyle(.secondary) }
                    if let selectedStep { Text("Step \(selectedStep.number): "+selectedStep.name+" · "+(selectedStep.conclusion ?? selectedStep.status).replacingOccurrences(of:"_",with:" ")).font(.caption) }
                    Text("Available job logs appear here. Open GitHub to follow output while the job is running.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if loadingLog { ProgressView("Loading job log").frame(maxWidth:.infinity,maxHeight:.infinity) }
            else {
                switch log {
                case .available(let text):
                    HStack(spacing:10) { Image(systemName:"magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true);TextField("Search log",text:$logSearch).textFieldStyle(.plain);if let url=selectedJob?.webURL { Link("Open job",destination:url) } }.padding(10).workspaceGlass(radius:12)
                    ActionsLogTextView(text:text,search:logSearch,webURL:selectedJob?.webURL,stepNumber:selectedStep?.number ?? 1)
                case .unavailable:ContentUnavailableView("Logs are unavailable",systemImage:"doc.text",description:Text("The job may still be running, or its log download may have expired. Refresh or open the job on GitHub."))
                case nil:ContentUnavailableView("Select a job or step",systemImage:"list.bullet.rectangle",description:Text("Explore available job logs with ANSI colors, text search, and line navigation."))
                }
            }
        }
    }
    private func refresh() async {
        let request=UUID();refreshRequest=request;loading=true;loadingSupplementary=true
        defer { if refreshRequest==request { loading=false;loadingSupplementary=false } }
        do {
            let service=try await storage.actionsService()
            let value=try await service.detail(run:run,onPrimary:{ primary in
                guard !Task.isCancelled,refreshRequest==request else { return }
                // Keep previously read artifacts and annotations visible while refreshing the same attempt. Pending
                // environments can change with a new attempt, so they wait for this refresh's read.
                if let previous=detail {
                    detail = .init(run:primary.run,jobs:primary.jobs,artifacts:previous.artifacts,annotations:previous.annotations,pendingDeployments:[],unavailableSections:primary.unavailableSections)
                } else { detail=primary }
                freshRun=true
                if selectedJob == nil,let first=primary.jobs.first {
                    selectedJob=first
                    Task { await loadLog(first) }
                }
                error=nil
            });guard !Task.isCancelled,refreshRequest==request else { return };detail=value;freshRun=true;error=nil
            if let id=selectedJob?.id {
                selectedJob=value.jobs.first { $0.id==id }
                // Keep the selected step's status current with its refreshed job.
                if let job=selectedJob { selectedStep=selectedStep.flatMap { step in job.steps.first { $0.number==step.number } } }
                else { logRequest.invalidate();log=nil;selectedStep=nil }
            }
            if receipt==nil { let pending=try await service.operations(repository:run.repository.key).filter { $0.intent.runIdentity?.0==run.runID && [.sending,.uncertain,.accepted].contains($0.state) };guard refreshRequest==request else { return };receipt=pending.first }
        } catch { if !Task.isCancelled,refreshRequest==request { self.error=providerErrorMessage(error) } }
    }
    private func loadLog(_ job:ActionsJob) async {
        let request=logRequest.begin();log=nil
        defer { logRequest.finish(request) }
        do { let value=try await storage.actionsService().log(repository:run.repository,jobID:job.id);guard logRequest.accepts(request),selectedJob?.id==job.id,!Task.isCancelled else { return };log=value } catch { if logRequest.accepts(request),selectedJob?.id==job.id,!Task.isCancelled { self.error=providerErrorMessage(error) } }
    }
    private func perform(_ intent:ActionsIntent) async {
        guard !writing else { return };writing=true
        defer { writing=false }
        do { receipt=try await storage.actionsService().perform(repository:run.repository,intent:intent);status=nil;await refresh() } catch { self.error=providerErrorMessage(error) };loading=false
    }
    private func download(_ artifact:ActionsArtifact) async {
        let panel=NSSavePanel();panel.nameFieldStringValue=artifact.name.replacingOccurrences(of:"/",with:"_")+".zip";panel.canCreateDirectories=true
        guard await panel.begin() == .OK,let url=panel.url else { return }
        do { let data=try await storage.actionsService().artifact(repository:run.repository,artifact:artifact);try data.write(to:url,options:.withoutOverwriting);error=nil;status="Artifact saved to "+url.lastPathComponent } catch { status=nil;self.error=providerErrorMessage(error) }
    }
    private func openAnnotation(_ annotation:ActionsAnnotation) {
        if let onOpenAnnotation { onOpenAnnotation(run.repository,run.headSHA,annotation.path,annotation.startLine);dismiss();return }
        var url=URL(string:"https://github.com")!;for component in [run.repository.name,"blob",run.headSHA,annotation.path] { url.appendPathComponent(component) };var components=URLComponents(url:url,resolvingAgainstBaseURL:false)!;components.fragment="L\(annotation.startLine)";if let target=components.url { NSWorkspace.shared.open(target) }
    }
}

private enum RunCommandConfirmation:Identifiable {
    case cancel,approveFork,rerunAll,rerunFailed
    var id:Self { self }
    var title:String {
        switch self {
        case .cancel:"Cancel this workflow run?"
        case .approveFork:"Approve this fork’s workflow run?"
        case .rerunAll:"Re-run all jobs?"
        case .rerunFailed:"Re-run failed jobs?"
        }
    }
}

/// Loading belongs to a request, including repeated selections of the same job.
struct ActionsLogRequestState {
    private var current:UUID?
    var isLoading:Bool { current != nil }
    mutating func begin() -> UUID { let request=UUID();current=request;return request }
    func accepts(_ request:UUID) -> Bool { current == request }
    mutating func finish(_ request:UUID) { if accepts(request) { current=nil } }
    mutating func invalidate() { current=nil }
}

private struct ActionsElapsedView:View {
    let started:Date?
    let completed:Date?
    let active:Bool
    var notStarted=false
    @ViewBuilder var body:some View {
        if let started {
            if let completed { Text(Duration.seconds(max(0,completed.timeIntervalSince(started))).formatted(.time(pattern:.hourMinuteSecond))).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            else if active { TimelineView(.periodic(from:.now,by:1)) { context in Text(Duration.seconds(max(0,context.date.timeIntervalSince(started))).formatted(.time(pattern:.hourMinuteSecond))).font(.caption.monospacedDigit()).foregroundStyle(.secondary) } }
            else { Text("Duration unavailable").font(.caption).foregroundStyle(.secondary) }
        } else { Text(notStarted ? "Not started":"Timing unavailable").font(.caption).foregroundStyle(.secondary) }
    }
}
