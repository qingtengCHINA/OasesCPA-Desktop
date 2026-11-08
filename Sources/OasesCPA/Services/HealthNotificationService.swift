import Foundation
import UserNotifications

@MainActor
final class HealthNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = HealthNotificationService()

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    func notifyDegraded(target: String, detail: String) async {
        guard await isAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = OasesLocalization.localized("Oases CPA：目标服务不可用")
        content.body = OasesLocalization.localizedFormat("%@：%@ App 会继续尝试自动恢复。", target, detail)
        content.sound = .default
        await add(content: content, identifier: "oases-cpa-health-degraded")
    }

    func notifyRecovered(target: String, topology: DeploymentTopology) async {
        guard await isAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = OasesLocalization.localized("Oases CPA：目标服务已恢复")
        content.body = Self.recoveredBody(target: target, topology: topology)
        content.sound = .default
        await add(content: content, identifier: "oases-cpa-health-recovered")
    }

    /// The gateway topology names the gateway too; a legacy deployment keeps the old text.
    nonisolated static func recoveredBody(target: String, topology: DeploymentTopology, language: AppLanguage? = nil) -> String {
        switch topology {
        case .gateway:
            OasesLocalization.localizedFormat("%@：CLIProxyAPI、CPAMP、Oases 网关和连接通道已重新可用。", language: language, target)
        case .legacy:
            OasesLocalization.localizedFormat("%@：CLIProxyAPI、CPAMP 和连接通道已重新可用。", language: language, target)
        }
    }

    /// The degraded-state detail of a failed patrol, by topology.
    nonisolated static func healthCheckFailedDetail(topology: DeploymentTopology, language: AppLanguage? = nil) -> String {
        switch topology {
        case .gateway:
            OasesLocalization.localized("CLIProxyAPI、CPAMP 或 Oases 网关健康检查未通过。", language: language)
        case .legacy:
            OasesLocalization.localized("CLIProxyAPI 或 CPAMP 健康检查未通过。", language: language)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Reads only the authorization status. `UNNotificationSettings` is not Sendable, so the
    /// settings object stays inside the completion handler and only the status leaves it (the
    /// async `notificationSettings()` does not compile on Swift 6.1, the toolchain of Xcode 16).
    private func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    private func isAuthorized() async -> Bool {
        let status = await authorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func add(content: UNMutableNotificationContent, identifier: String) async {
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await center.add(request)
    }
}
