import ServiceManagement

/// Launch at login through ServiceManagement (spec §3): registers Lift.app itself as a login item.
public enum LoginItem {
    @MainActor public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @MainActor public static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
