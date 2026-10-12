import AgentDropCore
import Foundation
import ServiceManagement

/// Spec §6 "Launch at login". A protocol so tests never register the test runner.
public protocol LoginItemControlling: Sendable {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

public struct SystemLoginItem: LoginItemControlling {
    public init() {}

    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    public func setEnabled(_ enabled: Bool) throws {
        guard AppIdentity.isBundled else {
            throw AgentDropError.invalid("Launch at login needs AgentDrop.app; it isn't available under `swift run`.")
        }
        let service = SMAppService.mainApp
        if enabled, service.status != .enabled {
            try service.register()
        } else if !enabled, service.status == .enabled {
            try service.unregister()
        }
    }
}
