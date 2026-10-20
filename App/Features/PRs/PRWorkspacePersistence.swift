import Foundation
import MergeProCore

/// PR navigation history (palette ranking) lives in its own local record, apart from the workspace record, so
/// opening a PR saves only the history and saving view settings or the selection never re-encodes up to 1,000
/// visits. Local only; it holds provider keys, never tokens.
extension SetupStorage {
    /// Nil when the history has never been stored on its own (it may still be in the workspace record).
    func prNavigationHistory() throws -> [PRNavigationVisit]? {
        guard let text=try stores().0.applicationSetting(.prNavigationHistory) else { return nil }
        return try JSONDecoder().decode([PRNavigationVisit].self,from:Data(text.utf8))
    }
    func savePRNavigationHistory(_ history:[PRNavigationVisit]) throws {
        let data=try JSONEncoder().encode(history)
        try stores().0.setApplicationSetting(String(decoding:data,as:UTF8.self),for:.prNavigationHistory)
    }
}
