<p align="center">
  <img src="website/assets/img/icon-256.png" width="128" height="128" alt="MergePro app icon">
</p>

<h1 align="center">MergePro</h1>

<p align="center">
  <strong>Agents write the PRs. You ship them.</strong><br>
  A native Mac inbox for pull requests in an AI-first workflow: every PR, every account, reviewed and merged from the keyboard.
</p>

<p align="center">
  <a href="https://mergepro.app">Website</a> ·
  <a href="https://github.com/jonathansudhakar1/mergepro/releases">Download</a> ·
  <a href="https://mergepro.app/privacy.html">Privacy</a> ·
  <a href="https://github.com/jonathansudhakar1/mergepro/issues">Issues</a>
</p>

<p align="center">
  <a href="https://github.com/jonathansudhakar1/mergepro/actions/workflows/test.yml"><img src="https://github.com/jonathansudhakar1/mergepro/actions/workflows/test.yml/badge.svg" alt="Tests"></a>
  <a href="https://github.com/jonathansudhakar1/mergepro/releases/latest"><img src="https://img.shields.io/github/v/release/jonathansudhakar1/mergepro?sort=semver" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-111?logo=apple" alt="macOS 26 or later">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-3d5afe" alt="Apache 2.0 license"></a>
</p>

---

Coding agents now open a large share of pull requests, and people review and merge them. The result is more PRs than
ever, arriving all day from every repository you touch. MergePro is a free, open-source SwiftUI app that centralizes
them: one queue across all your GitHub accounts, clear signals about which PRs AI wrote and where to look closely, and
fast review and merge from the keyboard or the menu bar.

There is no MergePro server. The app talks to GitHub directly, keeps your tokens in the macOS Keychain and everything
else in a local database on your Mac.

## Built for an AI-first workflow

- **Spot what agents wrote.** Pull requests from coding agents (Copilot, Codex, Claude, Devin, Cursor, Jules) are
  recognized by bot account, branch prefix (`copilot/`, `claude/`, …), labels (`ai-generated`, `agent:*`), an agent
  in the head commit's `Co-authored-by:` trailers, or a signature in the description ("🤖 Generated with …"). That
  catches pull requests you open yourself after working with a local agent, too. They're marked with an AI badge and
  gathered in an *AI-authored* view; add your own branch prefixes and labels, or override any login, in Settings.
- **Know where to look.** Each pull request is scanned for changes that deserve a human: sensitive paths (workflows,
  infra, migrations, auth, CODEOWNERS), dependency changes, source without tests, possible credentials and diffs
  larger than the repository's usual size. Optionally require every file to be viewed before approving a risky PR.
- **Clear the queue.** One *Needs my review* queue across every account, in the app and the menu bar. Approve with a
  key, approve a whole stack at once, and merge pinned to the commit you reviewed, so a late push can't slip in.

## Everything else

- **Pull request board and list** across every connected account, with saved views such as *Needs my review*,
  *My PRs*, *Ready to merge*, *Failing checks*, *Stale* and *AI-authored*, plus filters and swimlanes.
- **Reviews** with syntax-highlighted split and unified diffs, inline threads, draft comments and pending reviews.
- **Safe merging** from one options popup: merge, squash or rebase, merge queue and auto-merge, stacked pull requests
  in order. Every merge is pinned to the commit you reviewed.
- **GitHub Actions**: running and recent workflow runs, logs, re-runs, cancellation, workflow dispatch and deployment
  approvals, with extra confirmation for production environments.
- **Repository browser**: code, branches, history, releases and labels.
- **Local Git workspace** for the folders you choose: changes, hunk staging, commits, branches, stash, worktrees,
  history and a conflict resolver.
- **Menu bar review queue**, activity inbox and optional system notifications.
- **Keyboard first**: a command palette, single-key board navigation and global shortcuts.

## Install

- **Mac App Store**: coming soon.
- **GitHub Releases**: download the signed and notarized build from
  [Releases](https://github.com/jonathansudhakar1/mergepro/releases/latest), unzip it and move MergePro to
  Applications.

MergePro needs macOS 26 or later on a Mac with Apple silicon. Sign in with GitHub's device flow; MergePro never sees
your password and never uses a client secret.

## Privacy

MergePro collects no data. It has no analytics, telemetry, ads or tracking, and there is no MergePro account. The app
only contacts GitHub (and the storage hosts GitHub redirects downloads to) and, for local clones, the Git remotes you
have configured. Local Git commands only run in folders you select. Read the full
[privacy policy](https://mergepro.app/privacy.html).

## Build from source

Requirements:

- Xcode 27 with the macOS 26 SDK (Swift 6 language mode)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), to regenerate `MergePro.xcodeproj` after changing `project.yml`
  or adding or removing files
- A [GitHub OAuth App](https://github.com/settings/applications/new) with **device flow enabled**, for signing in

```sh
git clone https://github.com/jonathansudhakar1/mergepro.git
cd mergepro
xcodegen generate
xcodebuild -project MergePro.xcodeproj -scheme MergePro -configuration Debug \
    -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
```

Two optional, git-ignored files in `Config/` hold machine-specific values:

| File | Settings |
| --- | --- |
| `Config/GitHub.xcconfig.local` | `MERGEPRO_GITHUB_CLIENT_ID`: the public client ID of your OAuth App. You can also enter it in Settings › General. |
| `Config/Signing.xcconfig.local` | `CODE_SIGN_STYLE`, `CODE_SIGN_IDENTITY` (certificate SHA-1) and `DEVELOPMENT_TEAM`. Without it, builds are signed to run locally. |

Debug builds use the bundle identifier `app.mergepro.mac.debug`, so they keep their own data and Keychain items and
never touch an installed copy of MergePro. `scripts/build-local.sh` makes a signed build with the identity in
`Signing.xcconfig.local` and verifies its signature, hardened runtime and entitlements.

## Test

```sh
scripts/verify.sh
```

This runs the `MergeProCore` and `MergeProRendering` package tests, builds the app and the fixture app, runs the app
unit tests and makes an unsigned Release build. The same script runs in CI on every push and pull request.

UI tests (`MergeProUITests`, `MergeProFixtureUITests`) drive the app in an isolated data namespace, so they never touch
your accounts or data. The `MergeProFixtures` scheme builds a separate app with offline fixture data for them.

## Architecture

| Path | Contents |
| --- | --- |
| `App/` | The SwiftUI app: `Shell/` (windows, menus, menu bar, command palette), `Features/` (PRs, Actions, Repos, Local, Setup), `Platform/` (Keychain, notifications, hotkeys, security-scoped folders), `Rendering/` (code, diff and Markdown views). |
| `App/Fixtures/` | Compiled only into the `MergeProFixtures` test app: offline seeds and scripted transports. |
| `Packages/MergeProCore` | Everything without UI: the GitHub adapter, SQLite storage and migrations, polling, notifications, merge policy, Actions and the local Git runner. |
| `Packages/MergeProRendering` | Native syntax highlighting (Tree-sitter and TextMate grammars) and Markdown. See its [README](Packages/MergeProRendering/README.md) for vendored components and their licenses. |
| `website/` | The [mergepro.app](https://mergepro.app) site, deployed to GitHub Pages. |

Data flows from a GitHub response to normalized provider objects, one SQLite transaction, a change-event ledger and at
most one notification per poll cycle. Writes are explicit user commands that are checked against fresh provider state
before they are sent and refresh the affected object afterwards.

## Contributing

Issues and pull requests are welcome. Please open an issue to discuss larger changes first, run `scripts/verify.sh`
before sending a pull request, and match the style of the surrounding code. Report security issues privately through
[GitHub security advisories](https://github.com/jonathansudhakar1/mergepro/security/advisories/new) rather than public
issues.

Maintainers: see [RELEASING.md](RELEASING.md) for the App Store and GitHub release process.

## License

MergePro is licensed under the [Apache License 2.0](LICENSE). Copyright © 2026 Jonathan Sudhakar.

The license covers the source code. It does not grant rights to the MergePro name or logo; please don't use them for
your own builds or forks. Third-party components keep their own licenses (see
[Packages/MergeProRendering/README.md](Packages/MergeProRendering/README.md)).

MergePro is not affiliated with, endorsed by or sponsored by GitHub, Inc. GitHub is a trademark of GitHub, Inc.
