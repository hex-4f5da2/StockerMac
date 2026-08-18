import AppKit
import Combine
import ObjectiveC
import StockerCore
import SwiftUI
import UserNotifications

@objc(StockerApplication)
final class StockerApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        // ⌘W 的关闭由 MainWindowDelegate.windowShouldClose 拦截（更可靠，覆盖关闭按钮+快捷键）。
        // 这里保留兜底：若 keyWindow 是主窗口，也走 collapse。
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown,
           modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w",
           let window = MainWindowRegistry.window,
           NSApp.keyWindow === window,
           NSApp.isActive,
           window.isVisible,
           window.attachedSheet == nil {
            MainWindowRegistry.collapse()
            return
        }
        super.sendEvent(event)
    }
}

@main
struct StockerMacApp: App {
    @NSApplicationDelegateAdaptor(StockerAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var store = AppStore()
    @StateObject private var telegraphVM = TelegraphViewModel(
        service: TelegraphService(),
        store: TelegraphStore(baseURL: TelegraphStore.defaultBaseURL()),
        notificationSender: NotificationService(),
        watchlist: nil
    )
    @State private var pendingSubscription: AnyCancellable?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(telegraphVM)
                .task {
                    store.start()
                    StatusBarInstaller.install(store: store)
                    if AppStore.telegraphEnabled {
                        telegraphVM.setWatchlist(store)
                        telegraphVM.start()
                    }
                    subscribePendingNotifications()
                    consumePendingNotificationIfNeeded()
                }
        }
        .defaultSize(width: 1000, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("收起主窗口") { MainWindowRegistry.collapse() }
                Button("刷新行情") { Task { await store.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
            }

            CommandMenu("股票") {
                Button("打开行情图") {
                    if let selectedItem = store.selectedRow?.item {
                        openWindow(id: "kline", value: KLineRoute(item: selectedItem))
                    }
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(store.selectedID == nil)

                Button("添加股票…") { store.isSearchPresented = true }
                    .keyboardShortcut("d", modifiers: .command)
            }
        }

        WindowGroup("K 线", id: "kline", for: KLineRoute.self) { $route in
            if let route {
                KLineWindowView(route: route)
                    .environmentObject(store)
            } else {
                ContentUnavailableView(
                    "选择一只股票",
                    systemImage: "chart.xyaxis.line",
                    description: Text("从主窗口的股票详情中打开 K 线")
                )
            }
        }
        .defaultSize(width: 640, height: 700)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(telegraphVM)
        }
    }

    @MainActor
    private func consumePendingNotificationIfNeeded() {
        guard let pending = PendingNotificationRouter.consume() else { return }
        store.selectTelegraph()
        telegraphVM.selectMessage(source: pending.source, messageID: pending.messageID)
    }

    @MainActor
    private func subscribePendingNotifications() {
        guard pendingSubscription == nil else { return }
        pendingSubscription = NotificationCenter.default
            .publisher(for: PendingNotificationRouter.pendingNotification)
            .receive(on: RunLoop.main)
            .sink { _ in
                MainActor.assumeIsolated {
                    self.consumePendingNotificationIfNeeded()
                }
            }
    }
}

@MainActor
final class StockerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        // UserNotifications 仅在 app bundle 上下文可用（swift run 直接运行二进制时无 bundle）
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard MainWindowRegistry.window != nil else {
            return true
        }
        MainWindowRegistry.uncollapse()
        sender.activate(ignoringOtherApps: true)
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // collapse 后窗口保持 visible（仅 alpha=0），hasVisibleWindows 仍为 true，
        // 因此点击 Dock 图标未必触发 applicationShouldHandleReopen。
        // 这里在应用重新激活时兜底恢复收起的窗口。
        if MainWindowRegistry.isCollapsed {
            MainWindowRegistry.uncollapse()
        }
    }
}

/// 拦截主窗口的关闭（⌘W / 红色关闭按钮）：返回 false 取消真实关闭，改为 collapse 收起。
/// 这样窗口对象始终存活、layer 不丢失，避免恢复后中间列表空白。
@MainActor
final class MainWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === MainWindowRegistry.window else { return true }
        // 已收起（如退出应用时）则放行真实关闭。
        if MainWindowRegistry.isCollapsed { return true }
        MainWindowRegistry.collapse()
        return false
    }
}

extension StockerAppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // 先回调 completionHandler，再派发 MainActor 写 pending（nonisolated 不能直接改 @MainActor 状态）
        completionHandler()
        let userInfo = response.notification.request.content.userInfo
        guard userInfo["route"] as? String == "telegraph",
              let sourceRaw = userInfo["source"] as? String,
              let source = TelegraphSource(rawValue: sourceRaw),
              let messageID = userInfo["messageID"] as? String else { return }
        Task { @MainActor in
            PendingNotificationRouter.store(
                PendingNotificationRouter.Pending(source: source, messageID: messageID)
            )
            if MainWindowRegistry.window != nil {
                MainWindowRegistry.uncollapse()
            }
        }
    }
}

@MainActor
enum MainWindowRegistry {
    static var window: NSWindow?
    private static var frameBeforeCollapse: NSRect?
    /// 窗口是否被 collapse 收起（透明隐藏）。用于判断 Dock 点击/重新激活时是否需要 uncollapse。
    static private(set) var isCollapsed = false

    static func register(_ candidate: NSWindow) -> Bool {
        if let window, window !== candidate {
            DispatchQueue.main.async {
                candidate.close()
                window.makeKeyAndOrderFront(nil)
                restoreFrame()
            }
            return false
        }
        window = candidate
        // 拦截 ⌘W/关闭按钮：改为 collapse 而非真实关闭，避免 SwiftUI 合成层丢失。
        let delegate = MainWindowDelegate()
        objc_setAssociatedObject(candidate, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        candidate.delegate = delegate
        return true
    }

    private static var delegateKey: UInt8 = 0

    static func collapse() {
        guard let window, !isCollapsed else { return }
        frameBeforeCollapse = window.frame
        // orderOut 收起：hasVisibleWindows 变 false，点 Dock 会可靠触发 applicationShouldHandleReopen。
        // 合成层丢失问题在 uncollapse 时通过重建 hosting view 解决。
        isCollapsed = true
        window.orderOut(nil)
    }

    static func restoreFrame() {
        guard let window, let frameBeforeCollapse else { return }
        window.setFrame(frameBeforeCollapse, display: true)
    }

    /// 取消 collapse：恢复窗口并强制重建 SwiftUI 渲染层，修复 orderOut 后列表空白。
    static func uncollapse() {
        guard let window else { return }
        restoreFrame()
        window.makeKeyAndOrderFront(nil)
        // orderOut 后 SwiftUI hosting view 的合成层未重新提交，中间列表会空白。
        // 通过临时摘除 contentView 再挂回，强制 NSHostingController 的 view 走一遍
        // viewDidMoveToWindow → 重建 layer 层级与布局，从而恢复渲染。
        if let content = window.contentView {
            window.contentView = nil
            window.contentView = content
            content.needsDisplay = true
            content.needsLayout = true
        }
        isCollapsed = false
    }
}
