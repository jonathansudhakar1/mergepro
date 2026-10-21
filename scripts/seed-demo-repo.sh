#!/bin/bash
# Creates a small public repository with open pull requests, labels and a review comment, for the App Review demo account.
# Log the GitHub CLI into the DEMO account in its own profile first, so your own login is untouched:
#   GH_CONFIG_DIR=~/.config/gh-demo gh auth login
# Then run:
#   GH_CONFIG_DIR=~/.config/gh-demo scripts/seed-demo-repo.sh [repo-name]
set -euo pipefail
: "${GH_CONFIG_DIR:?Run with GH_CONFIG_DIR set to the demo account gh profile}"
repo_name="${1:-sample-app}"
owner=$(gh api user --jq .login)
echo "Seeding $owner/$repo_name as $owner"
read -r -p "Continue? [y/N] " answer; [[ "$answer" == y* ]] || exit 1

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cd "$work"
git init -q -b main sample && cd sample
git config user.name "$owner"; git config user.email "$owner@users.noreply.github.com"
mkdir -p Sources/Sync Tests
cat > README.md <<'MD'
# Sample App

A small Swift package used to demonstrate MergePro.
MD
cat > Sources/Sync/RetryPolicy.swift <<'SWIFT'
import Foundation

/// How long to wait before retrying a request.
struct RetryPolicy {
    var base: Duration = .seconds(1)

    func delay(after response: HTTPURLResponse) -> Duration {
        return .seconds(1)
    }
}
SWIFT
cat > Sources/Sync/Cache.swift <<'SWIFT'
import Foundation

final class Cache {
    private var storage: [String: Data] = [:]
    func value(for key: String) -> Data? { storage[key] }
    func set(_ data: Data, for key: String) { storage[key] = data }
}
SWIFT
git add -A && git commit -q -m "Initial commit"
gh repo create "$repo_name" --public --source . --push --description "Sample repository for MergePro" >/dev/null

for label in "performance:fbca04" "enhancement:a2eeef" "bug:d73a4a" "tests:0e8a16"; do
  gh label create "${label%%:*}" --color "${label##*:}" --repo "$owner/$repo_name" --force >/dev/null
done

branch() { git checkout -q main && git checkout -q -b "$1"; }
pr() { git push -q -u origin HEAD; gh pr create --repo "$owner/$repo_name" --base main --title "$1" --body "$2" ${3:+--label "$3"} ${4:+$4}; }

branch back-off-on-rate-limits
cat > Sources/Sync/RetryPolicy.swift <<'SWIFT'
import Foundation

/// How long to wait before retrying a request.
struct RetryPolicy {
    var base: Duration = .seconds(2)

    func delay(after response: HTTPURLResponse, attempt: Int) -> Duration {
        // Honor Retry-After on secondary rate limits.
        if let value = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Int(value) {
            return .seconds(seconds)
        }
        return min(.seconds(60), base * attempt)
    }
}
SWIFT
git commit -qam "Back off on secondary rate limits"
body=$(printf '## What\nHonor Retry-After and cap the backoff at 60 seconds.\n\n## Testing\n- Ran a full refresh with no 403s\n')
url=$(pr "Back off on secondary rate limits" "$body" performance)
gh pr comment "$url" --body "Should we add jitter to the backoff as well?" >/dev/null

branch cache-eviction
cat >> Sources/Sync/Cache.swift <<'SWIFT'

extension Cache {
    /// Drops every cached value.
    func removeAll() { storage.removeAll() }
}
SWIFT
git commit -qam "Add cache eviction"
pr "Add cache eviction" "Adds removeAll() so callers can clear the cache on sign-out." enhancement >/dev/null

branch retry-tests
cat > Tests/RetryPolicyTests.swift <<'SWIFT'
import XCTest

final class RetryPolicyTests: XCTestCase {
    func testDefaultDelay() {
        XCTAssertEqual(RetryPolicy().base, .seconds(1))
    }
}
SWIFT
git add -A && git commit -qm "Add retry policy tests"
pr "Add retry policy tests" "First tests for RetryPolicy." tests --draft >/dev/null

echo "Done: https://github.com/$owner/$repo_name/pulls"
