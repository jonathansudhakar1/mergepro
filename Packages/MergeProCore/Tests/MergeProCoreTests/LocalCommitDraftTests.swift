import Foundation
import XCTest
@testable import MergeProCore

@MainActor final class LocalCommitDraftTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "LocalCommitDraftTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    // A repository-wide key would overwrite the linked worktree's unsent message.
    func testLinkedWorktreesKeepIndependentDraftsAcrossStoreReopening() {
        let preferences = defaults()
        let store = LocalCommitDraftStore(defaults: preferences)
        let primary = URL(fileURLWithPath: "/tmp/project")
        let linked = URL(fileURLWithPath: "/tmp/project-feature")
        store.save(.init(subject: "Primary", body: "Keep my\n\nparagraphs."), directory: primary)
        store.save(.init(subject: "Feature", body: "  Exact whitespace\n", amend: true), directory: linked)
        let reopened = LocalCommitDraftStore(defaults: preferences)
        XCTAssertEqual(reopened.load(directory: primary), .init(subject: "Primary", body: "Keep my\n\nparagraphs."))
        XCTAssertEqual(reopened.load(directory: linked), .init(subject: "Feature", body: "  Exact whitespace\n", amend: true))
    }

    // Clearing a successful commit must leave another worktree's draft intact.
    func testSuccessfulCommitClearsOnlyTheCapturedWorktree() {
        let store = LocalCommitDraftStore(defaults: defaults())
        let first = URL(fileURLWithPath: "/tmp/first")
        let second = URL(fileURLWithPath: "/tmp/second")
        store.save(.init(subject: "First"), directory: first)
        store.save(.init(subject: "Second"), directory: second)
        store.clear(directory: first)
        XCTAssertEqual(store.load(directory: first), .init())
        XCTAssertEqual(store.load(directory: second).subject, "Second")
    }

    // Substring/path-prefix key matching could collide with an adjacent directory.
    func testDirectoryKeyKeepsLiteralUnicodeAndNewlinePathsDistinct() {
        let store = LocalCommitDraftStore(defaults: defaults())
        let literal = URL(fileURLWithPath: "/tmp/work\ntree/日本語")
        let neighbor = URL(fileURLWithPath: "/tmp/work-tree/日本語")
        store.save(.init(subject: "Literal"), directory: literal)
        XCTAssertEqual(store.load(directory: neighbor), .init())
        XCTAssertEqual(store.load(directory: literal).subject, "Literal")
    }
}
