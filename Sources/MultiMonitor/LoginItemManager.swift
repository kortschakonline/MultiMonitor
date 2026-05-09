import Foundation
import ServiceManagement

/// Toggles MultiMonitor's "launch at login" status via SMAppService (macOS 13+).
/// Backed by the system service registry; survives app restarts and updates.
enum LoginItemManager {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Enable or disable launch-at-login. Returns the resulting effective
    /// status; on failure logs and returns false / true matching the request
    /// best effort.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("LoginItemManager: %@", String(describing: error))
        }
        return SMAppService.mainApp.status == .enabled
    }
}
