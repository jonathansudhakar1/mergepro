import AppIntents
import Foundation
import Observation

/// Requests from App Intents (Shortcuts, Spotlight), handled by the app shell once its window exists. Intents
/// only navigate: they never write to a provider.
@MainActor @Observable final class AppIntentRouter {
  static let shared = AppIntentRouter()
  enum Request: Equatable { case needsMe, open(URL) }
  var pending: Request?
  /// Installed by the app shell; reopens the main window when it was closed.
  @ObservationIgnored var showMain: (() -> Void)?
  func request(_ request: Request) {
    pending = request
    showMain?()
  }
}

struct ShowPullRequestsNeedingMeIntent: AppIntent {
  static let title: LocalizedStringResource = "Show Pull Requests That Need Me"
  static let description = IntentDescription("Opens MergePro to the pull requests waiting on your review.")
  static let openAppWhenRun = true
  @MainActor func perform() async throws -> some IntentResult {
    AppIntentRouter.shared.request(.needsMe)
    return .result()
  }
}

struct OpenPullRequestURLIntent: AppIntent {
  static let title: LocalizedStringResource = "Open Pull Request URL"
  static let description = IntentDescription(
    "Opens a GitHub pull request link in MergePro when it is cached for one of your accounts, otherwise on GitHub.")
  static let openAppWhenRun = true
  @Parameter(title: "URL") var url: URL

  enum Failure: Error, CustomLocalizedStringResourceConvertible {
    case unsupported
    var localizedStringResource: LocalizedStringResource { "MergePro opens https://github.com pull request links." }
  }
  @MainActor func perform() async throws -> some IntentResult {
    guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "github.com", url.user == nil, url.password == nil
    else { throw Failure.unsupported }
    AppIntentRouter.shared.request(.open(url))
    return .result()
  }
}

struct MergeProShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: ShowPullRequestsNeedingMeIntent(),
      phrases: ["Show pull requests that need me in \(.applicationName)", "What needs my review in \(.applicationName)"],
      shortTitle: "Needs Me", systemImageName: "person.crop.circle.badge.exclamationmark")
  }
}
