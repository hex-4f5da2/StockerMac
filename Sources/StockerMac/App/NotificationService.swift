import Foundation
import StockerCore
import UserNotifications

struct NotificationService: Sendable {
    /// UserNotifications 仅在 app bundle 上下文可用（swift run 直接运行二进制时无 bundle）
    private static var isBundleContext: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    func requestAuthorization() async {
        guard Self.isBundleContext else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// 发送通知；userInfo 携带电报导航元数据（source + messageID）
    func send(
        identifier: String,
        title: String,
        subtitle: String = "",
        body: String,
        threadIdentifier: String = "",
        userInfo: [String: String] = [:]
    ) async throws {
        guard Self.isBundleContext else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.threadIdentifier = threadIdentifier
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        try await UNUserNotificationCenter.current().add(request)
    }

    /// 实时查询授权状态（非缓存）
    func authorizationStatus() async -> Bool {
        guard Self.isBundleContext else { return false }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }
}

extension NotificationService: TelegraphNotificationSending {
    func send(message: TelegraphMessage) async throws {
        let importance = message.isRed ? "重要 · " : ""
        let related = message.stockList.isEmpty ? "" : " · 关联 \(message.stockList.count) 只股票"
        try await send(
            identifier: "telegraph-\(message.id)",
            title: message.displayTitle,
            subtitle: "\(importance)\(message.source.title)\(related)",
            body: message.summary(limit: 100),
            threadIdentifier: "telegraph-\(message.source.rawValue)",
            userInfo: [
                "route": "telegraph",
                "source": message.source.rawValue,
                "messageID": message.id,
            ]
        )
    }
}
