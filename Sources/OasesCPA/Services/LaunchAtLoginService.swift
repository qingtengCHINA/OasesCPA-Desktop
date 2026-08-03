import Foundation
import Combine
import ServiceManagement

@MainActor
final class LaunchAtLoginService: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var errorMessage: String?

    var isEnabled: Bool {
        status == .enabled
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
        } catch {
            refresh()
            errorMessage = error.localizedDescription
        }
    }

    var statusTitle: String {
        switch status {
        case .enabled:
            return OasesLocalization.localized("已启用")
        case .requiresApproval:
            return OasesLocalization.localized("需要系统确认")
        case .notRegistered:
            return OasesLocalization.localized("未启用")
        case .notFound:
            return OasesLocalization.localized("当前 Bundle 不可注册")
        @unknown default:
            return OasesLocalization.localized("状态未知")
        }
    }
}
