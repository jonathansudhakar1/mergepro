import ServiceManagement

@MainActor
struct LoginItemService {
    var enabled: Bool { SMAppService.mainApp.status == .enabled }
    var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
    func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
