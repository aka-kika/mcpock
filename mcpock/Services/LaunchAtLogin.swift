import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// macOS registered the login item but waits for the user to allow it in
    /// System Settings (r3 b5bc): the switch snaps back to off meanwhile.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static let approvalText = "macOS needs your OK in System Settings > General > Login Items"

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status != .notRegistered else { return }
            try SMAppService.mainApp.unregister()
        }
    }
}
