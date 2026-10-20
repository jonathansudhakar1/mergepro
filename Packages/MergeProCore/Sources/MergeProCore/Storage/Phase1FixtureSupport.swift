#if DEBUG
import Foundation

extension DatabaseStore {
    /// Only the fixture app's namespaced synthetic second account can install this fault.
    public func installPhase1AuthorizationPersistenceFailure(account:AccountScope) throws {
        guard account.host == "github.com",account.accountID == "42",
              ProcessInfo.processInfo.environment["MERGEPRO_PHASE1_FIXTURES"] == "1",
              ProcessInfo.processInfo.environment["MERGEPRO_UI_TEST_NAMESPACE"].flatMap(UUID.init(uuidString:)) != nil else { throw CocoaError(.fileWriteNoPermission) }
        let host=account.host.replacingOccurrences(of:"'",with:"''")
        let id=account.accountID.replacingOccurrences(of:"'",with:"''")
        try database.write { db in
            try db.execute(sql:"CREATE TRIGGER IF NOT EXISTS phase1_failed_authorization BEFORE INSERT ON settings WHEN NEW.host = '\(host)' AND NEW.accountID = '\(id)' AND NEW.name = 'authorizationProblem' BEGIN SELECT RAISE(ABORT,'isolated Phase 1 persistence fault'); END")
        }
    }
}
#endif
