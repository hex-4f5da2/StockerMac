import Foundation
import StockerCore

/// 通知点击路由：@MainActor 静态注册表（沿用 MainWindowRegistry 模式）
/// didReceive（nonisolated）写入 pending 并 post 通知，电报 VM/窗口就绪后消费（含冷启动）
@MainActor
enum PendingNotificationRouter {
    struct Pending: Sendable {
        let source: TelegraphSource
        let messageID: String
    }

    static let pendingNotification = Notification.Name("StockerMac.telegraphNotificationPending")

    private static var pending: Pending?

    static func store(_ value: Pending) {
        pending = value
        NotificationCenter.default.post(name: pendingNotification, object: nil)
    }

    static func consume() -> Pending? {
        defer { pending = nil }
        return pending
    }

    static var hasPending: Bool { pending != nil }
}
