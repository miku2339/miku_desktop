import Foundation
import ServiceManagement

enum LoginItemManager {
    enum State {
        case enabled
        case requiresApproval
        case disabled
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .disabled
        }
    }

    static var isEnabled: Bool {
        state != .disabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        let status = SMAppService.mainApp.status
        if enabled {
            if status != .enabled && status != .requiresApproval {
                try SMAppService.mainApp.register()
            }
        } else if status == .enabled || status == .requiresApproval {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
