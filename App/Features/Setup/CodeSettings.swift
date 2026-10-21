import MergeProCore
import SwiftUI

/// Settings › Code: code appearance, review requirements and author classification. Sections for a grouped form.
struct CodeSettings:View {
    let model:SetupModel
    @State private var appearance=CodeAppearance()
    @State private var status:String?
    @State private var ruleAccount:AccountScope?
    @State private var rules:[String:AgentClassifier.Classification]=[:]
    @State private var ruleLogin=""
    @State private var ruleType:AgentClassifier.Classification = .human
    @State private var agentBranches=""
    @State private var agentLabels=""
    /// nil until read, so the toggle never shows a guessed value.
    @State private var requireViewed:Bool?
    var body:some View {
        Section("Code appearance") {
            Picker("Code theme",selection:$appearance.theme) { Text("System").tag("system");Text("GitHub inspired").tag("github");Text("Dracula inspired").tag("dracula") }
            Picker("Code font",selection:$appearance.fontName) { Text("System Mono").tag("");Text("Menlo").tag("Menlo");Text("Monaco").tag("Monaco");Text("Courier").tag("Courier") }
            Stepper("Monospaced font: \(Int(appearance.fontSize)) pt",value:$appearance.fontSize,in:9...28)
            Toggle("Ligatures",isOn:$appearance.ligatures)
            Button("Save code preferences") { Task {
                do {
                    try await model.prs.storage.setting(appearance.fontName,for:.codeFontName)
                    try await model.prs.storage.setting(String(appearance.fontSize),for:.codeFontSize)
                    try await model.prs.storage.setting(appearance.ligatures ? "true" : "false",for:.codeLigatures)
                    try await model.prs.storage.setting(appearance.theme,for:.codeTheme)
                    status="Saved. Refresh open detail windows to apply."
                } catch { status="Preferences could not be saved." }
            } }
        }
        Section("Reviews") {
            Toggle("Require all files marked Viewed before approving risky pull requests",isOn:Binding(get:{ requireViewed ?? false },set:{ value in Task {
                do { try await model.prs.storage.setRequireAllFilesViewed(value);requireViewed=value;status=nil } catch { status="The review requirement could not be saved." }
            } })).disabled(requireViewed == nil)
            Text(requireViewed == nil ? "Reading the saved requirement…" : "Risky pull requests touch sensitive paths, dependencies or possible credentials, change source without tests, or are unusually large. Files must be marked Viewed on GitHub. Applies when you approve from the review composer.").font(.caption).foregroundStyle(.secondary)
        }
        Section {
            LabeledContent("Branch prefixes") {
                TextField("Branch prefixes",text:$agentBranches,prompt:Text("ai/, bot/")).labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).frame(maxWidth:260)
            }
            LabeledContent("Labels") {
                TextField("Labels",text:$agentLabels,prompt:Text("written-by-ai")).labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).frame(maxWidth:260)
            }
            Button("Save AI detection") {
                func list(_ text:String) -> [String] { text.split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty } }
                let value=AgentPatterns(branchPrefixes:list(agentBranches),labels:list(agentLabels))
                Task { do { try await model.prs.storage.saveAgentPatterns(value);await model.prs.reload();status="AI detection saved and applied to every pull request." } catch { status="Could not save AI detection. Use up to 50 short, comma-separated values." } }
            }
        } header: { Text("AI-authored detection") } footer: {
            Text("Pull requests count as AI-authored when they come from a coding agent's account (Copilot, Codex, Claude, Devin, Cursor, Jules), use an agent branch prefix (copilot/, codex/, claude/, devin/, cursor/), carry an ai-generated or agent: label, have a head commit co-authored by an agent, or are signed by one in the description. Add your team's own branch prefixes and labels here, comma-separated.").font(.callout).foregroundStyle(.secondary)
        }
        Section("Author classification overrides") {
            Picker("Account",selection:$ruleAccount) {
                Text("Choose account").tag(Optional<AccountScope>.none)
                ForEach(model.snapshots.compactMap(\.account),id:\.scope) { account in Text("\(account.login) · \(account.scope.host)").tag(Optional(account.scope)) }
            }
            if let account=ruleAccount {
                HStack(spacing:8) {
                    TextField("Exact GitHub login",text:$ruleLogin,prompt:Text("Exact GitHub login")).labelsHidden().textFieldStyle(.roundedBorder)
                    Picker("Classify as",selection:$ruleType) { ForEach([AgentClassifier.Classification.human,.automation,.agent,.unknown],id:\.self) { Text($0.rawValue.capitalized).tag($0) } }
                        .labelsHidden().fixedSize()
                    Button("Add rule") { rules[ruleLogin.lowercased()]=ruleType;ruleLogin="" }.disabled(ruleLogin.isEmpty)
                }
                ForEach(rules.keys.sorted(),id:\.self) { login in
                    LabeledContent(login) {
                        HStack(spacing:8) { Text(rules[login]?.rawValue.capitalized ?? "").foregroundStyle(.secondary);Button("Remove") { rules.removeValue(forKey:login) } }
                    }
                }
                Button("Save classification rules") {
                    let value=rules
                    Task { do { try await model.prs.storage.saveClassificationRules(value,account:account);await model.prs.reload();status="Rules saved. Removed overrides recompute automatic classification." } catch { status="Could not save rules. Use valid exact logins; up to 200 rules per account." } }
                }
            }
        }
        .task(id:ruleAccount) { if let account=ruleAccount { rules=(try? await model.prs.storage.classificationRules(account:account)) ?? [:] } else { rules=[:] } }
        .task {
            appearance=(try? await model.prs.storage.codeAppearance()) ?? CodeAppearance()
            if let patterns=try? await model.prs.storage.agentPatterns() { agentBranches=patterns.branchPrefixes.joined(separator:", ");agentLabels=patterns.labels.joined(separator:", ") }
            do { requireViewed=try await model.prs.storage.requireAllFilesViewed() } catch { status="The review requirement could not be read." }
        }
        if let status { Section { Text(status).font(.caption).foregroundStyle(.secondary) } }
    }
}

/// Settings › Local: the editor that opens files, and local clone mappings per repository.
struct LocalSettings:View {
    let model:SetupModel
    @State private var editor="vscode"
    @State private var status:String?
    @State private var search=""
    private var repositories:[Repository] {
        model.snapshots.flatMap(\.repositories).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    var body:some View {
        Section("Editor") {
            Picker("Editor",selection:$editor) { ForEach(EditorLocation.Editor.allCases,id:\.rawValue) { Text($0.displayName).tag($0.rawValue) } }
            Button("Save editor preference") { Task {
                do { try await model.prs.storage.setting(editor,for:.editor);status="Saved." } catch { status="Preferences could not be saved." }
            } }
        }
        .task { editor=(try? await model.prs.storage.editorPreference()) ?? "vscode" }
        Section("Local clones") {
            TextField("Search repositories",text:$search).textFieldStyle(.roundedBorder)
            ForEach(repositories,id:\.key) { repository in
                LabeledContent {
                    Button("Map local clone…") { Task { status=await EditorNavigation.map(storage:model.prs.storage,repository:repository.key) } }
                } label: {
                    Text(repository.name)
                    // The same repository can appear once per account.
                    if model.snapshots.count > 1, let login=model.snapshots.first(where:{ $0.account?.scope == repository.key.account })?.account?.login { Text(login) }
                }
            }
            if repositories.isEmpty { Text(search.isEmpty ? "No repositories discovered yet" : "No matching repositories").foregroundStyle(.secondary) }
        }
        if let status { Section { Text(status).font(.caption).foregroundStyle(.secondary) } }
    }
}
