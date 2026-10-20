import XCTest

@testable import MergeProCore

/// Shell decisions moved out of views: single-key routing, the shortcut catalogue, menu-bar actions and the
/// activity inbox grouping.
final class ShellCommandRulesTests: XCTestCase {
  // MARK: Single-key shortcuts

  func testSingleKeysReachOnlyTheBoardOrPRList() {
    typealias Scope = PRKeyboardScope
    for focus: Scope.Focus in [.prList, .workspace, .container] {
      XCTAssertEqual(Scope.key(characters: "j", modifiers: [], focus: focus, embedded: false), "j", "\(focus)")
      XCTAssertEqual(Scope.key(characters: "\r", modifiers: [], focus: focus, embedded: true), "\r", "\(focus)")
    }
    // The sidebar (and anything outside the workspace) keeps type-to-select in the main window.
    XCTAssertNil(Scope.key(characters: "j", modifiers: [], focus: .elsewhere, embedded: false))
    // Repository tabs keep their original rule: only other lists and editors are exempt.
    XCTAssertEqual(Scope.key(characters: "j", modifiers: [], focus: .elsewhere, embedded: true), "j")
    for focus: Scope.Focus in [.editableText, .exempt, .otherList] {
      XCTAssertNil(Scope.key(characters: "j", modifiers: [], focus: focus, embedded: false), "\(focus)")
      XCTAssertNil(Scope.key(characters: "j", modifiers: [], focus: focus, embedded: true), "\(focus)")
      XCTAssertNil(Scope.key(characters: "?", modifiers: [.shift], focus: focus, embedded: false), "\(focus)")
    }
  }

  func testShiftIsAModifierAndKeysAreNotLowercased() {
    typealias Scope = PRKeyboardScope
    XCTAssertNil(Scope.key(characters: "J", modifiers: [.shift], focus: .prList, embedded: false))
    XCTAssertNil(Scope.key(characters: "\r", modifiers: [.shift], focus: .prList, embedded: false))
    XCTAssertNil(Scope.key(characters: "j", modifiers: [.command], focus: .prList, embedded: false))
    XCTAssertNil(Scope.key(characters: "j", modifiers: [.option], focus: .prList, embedded: false))
    XCTAssertNil(Scope.key(characters: "j", modifiers: [.control], focus: .prList, embedded: false))
    XCTAssertEqual(Scope.key(characters: "A", modifiers: [], focus: .prList, embedded: false), "A", "never lowercased into an action")
    XCTAssertNil(Scope.key(characters: nil, modifiers: [], focus: .prList, embedded: false))
    // "?" needs Shift on most layouts; it opens the shortcut list.
    XCTAssertEqual(Scope.key(characters: "?", modifiers: [.shift], focus: .workspace, embedded: false), "?")
    XCTAssertEqual(Scope.key(characters: "?", modifiers: [], focus: .workspace, embedded: false), "?")
    XCTAssertNil(Scope.key(characters: "?", modifiers: [.shift, .command], focus: .workspace, embedded: false))
  }

  // MARK: Shortcut catalogue

  func testMenuShortcutsAreUniqueAndAvoidPRWindowAndStandardChords() {
    let entries = KeyboardShortcutCatalog.sections.flatMap(\.entries)
    let menu = entries.filter { $0.scope == .menu }.compactMap(\.chord)
    XCTAssertEqual(Set(menu).count, menu.count, "duplicate menu chords: \(menu.map(\.display))")
    let prWindow = Set(entries.filter { $0.scope == .prWindow }.compactMap(\.chord))
    XCTAssertTrue(Set(menu).isDisjoint(with: prWindow), "menu chords collide with the PR window's own")
    let standard: [KeyChord] = ["a", "c", "v", "x", "z", "q", "w", "h", "m", ",", "n", "s", "p", "t"].map { KeyChord($0, [.command]) }
      + [KeyChord("z", [.shift, .command])]
    XCTAssertTrue(Set(menu).isDisjoint(with: standard), "menu chords take a standard macOS chord")
    // UI tests and muscle memory rely on these.
    XCTAssertEqual(KeyboardShortcutCatalog.board, KeyChord("1", [.command]))
    XCTAssertEqual(KeyboardShortcutCatalog.list, KeyChord("2", [.command]))
    XCTAssertEqual(KeyboardShortcutCatalog.palette, KeyChord("k", [.command]))
    XCTAssertEqual(KeyboardShortcutCatalog.refresh, KeyChord("r", [.command]))
    XCTAssertEqual(KeyboardShortcutCatalog.find, KeyChord("f", [.command]))
    // Every single-key board/list command is listed.
    let board = Set(entries.filter { $0.scope == .board }.compactMap(\.chord))
    for key in ["j", "k", "x", "t", "a", "r", "c", "m", "return", "?"] {
      XCTAssertTrue(board.contains { $0.key == key }, "missing \(key)")
    }
    XCTAssertTrue(prWindow.contains(KeyChord("p", [.command])))
    XCTAssertTrue(prWindow.contains(KeyChord("n", [])))
    XCTAssertTrue(prWindow.contains(KeyChord("]", [.option, .shift])))
  }

  func testChordDisplayUsesMacModifierOrder() {
    XCTAssertEqual(KeyChord("]", [.shift, .option]).display, "⌥⇧]")
    XCTAssertEqual(KeyChord("down", [.command, .option]).display, "⌥⌘↓")
    XCTAssertEqual(KeyChord("return", []).display, "Return")
    XCTAssertEqual(KeyChord("k", [.command, .control]).display, "⌃⌘K")
    XCTAssertEqual(PRGlobalShortcut(key: "g", command: false, control: true, option: true).chord?.display, "⌃⌥G")
    XCTAssertNil(PRGlobalShortcut(key: "g", enabled: false).chord)
  }

  // MARK: Menu bar

  private func pr(_ account: String, author: Bool = false, object: String = "pr", state: PullRequest.State = .open) -> PullRequest {
    var metadata = PRMetadata(number: 1, webURL: URL(string: "https://github.com/o/r/pull/1")!, repositoryName: "o/r")
    metadata.viewerIsAuthor = author
    return PullRequest(key: ProviderKey(host: "github.com", accountID: account, repositoryID: "r", objectID: object),
      headRevision: RevisionID("s"), title: "T", state: state, isDraft: false, metadata: metadata)
  }

  func testMenuBarApprovalNeedsTheRowsOwnActionAccountAndNotOwnPR() {
    let row = pr("a")
    XCTAssertTrue(PRMenuBarRules.offersApproval(row: row, actionPR: row))
    XCTAssertFalse(PRMenuBarRules.offersApproval(row: row, actionPR: nil), "action-account copy is not cached")
    XCTAssertFalse(PRMenuBarRules.offersApproval(row: row, actionPR: pr("b")), "another account would act")
    XCTAssertFalse(PRMenuBarRules.offersApproval(row: pr("a", author: true), actionPR: pr("a", author: true)),
      "own PR listed because a team was requested")
    XCTAssertFalse(PRMenuBarRules.offersApproval(row: row, actionPR: pr("a", author: true)))
  }

  private func run(_ id: Int64, status: String, conclusion: String?, ageHours: Double, now: Date) -> WorkflowRun {
    let repository = Repository(key: RepositoryKey(account: AccountScope(host: "github.com", accountID: "a"), repositoryID: "r"), name: "o/r", isPrivate: false, capabilities: ProviderCapabilities())
    let date = now.addingTimeInterval(-ageHours * 3600)
    return WorkflowRun(repository: repository, runID: id, workflowID: 1, attempt: 1, name: "CI", branch: "main", headSHA: "s",
      event: "push", actor: "dev", status: status, conclusion: conclusion, createdAt: date, updatedAt: date)
  }

  func testMenuRunsListActiveThenRecentFailuresNewestFirst() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let runs = [
      run(1, status: "completed", conclusion: "success", ageHours: 1, now: now),
      run(2, status: "completed", conclusion: "failure", ageHours: 3, now: now),
      run(3, status: "in_progress", conclusion: nil, ageHours: 0.5, now: now),
      run(4, status: "completed", conclusion: "timed_out", ageHours: 1, now: now),
      run(5, status: "completed", conclusion: "failure", ageHours: 30, now: now),
      run(6, status: "queued", conclusion: nil, ageHours: 0.1, now: now),
      run(7, status: "completed", conclusion: "cancelled", ageHours: 1, now: now),
    ]
    XCTAssertEqual(PRMenuBarRules.menuRuns(runs, now: now).map(\.runID), [6, 3, 4, 2])
    XCTAssertEqual(PRMenuBarRules.menuRuns(runs, now: now, limit: 3).map(\.runID), [6, 3, 4])
    XCTAssertTrue(PRMenuBarRules.isRecentFailure(runs[1], now: now))
    XCTAssertFalse(PRMenuBarRules.isRecentFailure(runs[4], now: now))
  }

  func testStatusItemCount() {
    XCTAssertNil(PRMenuBarRules.statusCount(needsMe: 0, enabled: true))
    XCTAssertNil(PRMenuBarRules.statusCount(needsMe: 4, enabled: false))
    XCTAssertEqual(PRMenuBarRules.statusCount(needsMe: 4, enabled: true), "4")
    XCTAssertEqual(PRMenuBarRules.statusCount(needsMe: 140, enabled: true), "99+")
  }

  // MARK: Activity inbox

  private func event(_ key: String, account: String = "a", object: String, category: String, hoursAgo: Double,
                     number: String? = "7", type: String = "PullRequest", acknowledged: Bool = false) -> InboxEvent {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let change = ChangeEvent(key: key, object: ProviderKey(host: "github.com", accountID: account, repositoryID: "r", objectID: object),
      category: category, occurredAt: now.addingTimeInterval(-hoursAgo * 3600), title: "T",
      locator: EventLocator(subjectType: type, subjectNumber: number, webURL: number.map { URL(string: "https://github.com/o/r/pull/\($0)")! }))
    return InboxEvent(event: change, acknowledged: acknowledged, surfaced: false)
  }

  func testReasonsFromCategories() {
    XCTAssertEqual(ActivityReason(category: "review requested"), .reviewRequested)
    XCTAssertEqual(ActivityReason(category: "review request signals"), .reviewRequested)
    XCTAssertEqual(ActivityReason(category: "review decision"), .review)
    XCTAssertEqual(ActivityReason(category: "checks"), .checks)
    XCTAssertEqual(ActivityReason(category: "CI activity signals"), .checks)
    XCTAssertEqual(ActivityReason(category: "mention signals"), .mention)
    XCTAssertEqual(ActivityReason(category: "assignment signals"), .assignment)
    XCTAssertEqual(ActivityReason(category: "merged"), .merge)
    XCTAssertEqual(ActivityReason(category: "ready to merge"), .merge)
    XCTAssertEqual(ActivityReason(category: "something new"), .other)
  }

  func testInboxGroupsByPullRequestPerAccountNewestFirstAndFilters() {
    let events = [
      event("1", object: "pr-7", category: "checks", hoursAgo: 5),
      event("2", object: "notification-thread:99", category: "review request signals", hoursAgo: 1),
      event("3", object: "pr-8", category: "merged", hoursAgo: 2, number: "8", acknowledged: true),
      event("4", account: "b", object: "pr-7", category: "checks", hoursAgo: 0.5),
      event("5", object: "notification-thread:100", category: "repository activity signals", hoursAgo: 3, number: nil, type: "Release"),
    ]
    let groups = ActivityInbox.groups(events)
    XCTAssertEqual(groups.map { $0.events.map(\.id) }, [["4"], ["2", "1"], ["3"], ["5"]])
    XCTAssertEqual(groups[1].unread, 2)
    XCTAssertEqual(groups[1].reasons, [.reviewRequested, .checks])
    XCTAssertEqual(ActivityInbox.groups(events, reasons: [.merge]).map { $0.events.map(\.id) }, [["3"]])
    XCTAssertEqual(ActivityInbox.groups(events, unreadOnly: true).map { $0.events.map(\.id) }, [["4"], ["2", "1"], ["5"]])
    XCTAssertEqual(ActivityInbox.counts(events)[.checks], 2)
  }

  func testInboxOpensTheCachedPROfTheEventsOwnAccount() {
    var metadata = PRMetadata(number: 7, webURL: URL(string: "https://github.com/o/r/pull/7")!, repositoryName: "o/r")
    metadata.headBranch = "x"
    func cached(_ account: String) -> PullRequest {
      PullRequest(key: ProviderKey(host: "github.com", accountID: account, repositoryID: "r", objectID: "pr-7"),
        headRevision: RevisionID("s"), title: "T", state: .open, isDraft: false, metadata: metadata)
    }
    let lookup = ActivityInbox.PRLookup(rows: [cached("b"), cached("a")])
    XCTAssertEqual(lookup.key(for: event("1", object: "pr-7", category: "checks", hoursAgo: 1).event)?.accountID, "a")
    XCTAssertEqual(lookup.key(for: event("2", object: "notification-thread:9", category: "mention signals", hoursAgo: 1).event),
      cached("a").key, "a notification thread resolves by number within its own account")
    XCTAssertNil(lookup.key(for: event("3", account: "c", object: "notification-thread:9", category: "mention signals", hoursAgo: 1).event),
      "never another account's copy")
    XCTAssertNil(lookup.key(for: event("4", object: "notification-thread:9", category: "x", hoursAgo: 1, number: "7", type: "Issue").event))
  }
}
