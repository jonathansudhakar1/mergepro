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
            Toggle("Require every file provider-viewed before approving risk-flagged pull requests",isOn:Binding(get:{ requireViewed ?? false },set:{ value in Task {
                do { try await model.prs.storage.setRequireAllFilesViewed(value);requireViewed=value;status=nil } catch { status="The review requirement could not be saved." }
            } })).disabled(requireViewed == nil)
            Text(requireViewed == nil ? "Reading the saved requirement…" : "Applies when you approve from the review composer.").font(.caption).foregroundStyle(.secondary)
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
            Picker("Editor",selection:$editor) { ForEach(EditorLocation.Editor.allCases,id:\.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) } }
            Button("Save editor preference") { Task {
                do { try await model.prs.storage.setting(editor,for:.editor);status="Saved." } catch { status="Preferences could not be saved." }
            } }
        }
        .task { editor=(try? await model.prs.storage.editorPreference()) ?? "vscode" }
        Section("Local clones") {
            TextField("Search repositories",text:$search).textFieldStyle(.roundedBorder)
            ForEach(repositories,id:\.key) { repository in
                LabeledContent(repository.name) { Button("Map local clone…") { Task { status=await EditorNavigation.map(storage:model.prs.storage,repository:repository.key) } } }
            }
            if repositories.isEmpty { Text(search.isEmpty ? "No repositories discovered yet" : "No matching repositories").foregroundStyle(.secondary) }
        }
        if let status { Section { Text(status).font(.caption).foregroundStyle(.secondary) } }
    }
}
