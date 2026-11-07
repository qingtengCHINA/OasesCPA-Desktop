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

    func notifyRecovered(target: String) async {
        guard await isAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = OasesLocalization.localized("Oases CPA：目标服务已恢复")
        content.body = OasesLocalization.localizedFormat("%@：CLIProxyAPI、CPAMP 和连接通道已重新可用。", target)
        content.sound = .default
        await add(content: content, identifier: "oases-cpa-health-recovered")
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
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
