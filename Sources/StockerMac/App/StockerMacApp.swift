import AppKit
import SwiftUI
import UserNotifications

@objc(StockerApplication)
final class StockerApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .task {
                    store.start()
                    StatusBarInstaller.install(store: store)
                }
        }
        .defaultSize(width: 1280, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("收起主窗口") { MainWindowRegistry.collapse() }
                Button("刷新行情") { Task { await store.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
            }

            CommandMenu("股票") {
                Button("打开行情图") {
                    if let selectedID = store.selectedID {
                        openWindow(id: "kline", value: selectedID)
                    }
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(store.selectedID == nil)

                Button("添加股票…") { store.isSearchPresented = true }
                    .keyboardShortcut("d", modifiers: .command)
            }
        }

        WindowGroup("K 线", id: "kline", for: String.self) { $itemID in
            if let itemID {
                KLineWindowView(itemID: itemID)
                    .environmentObject(store)
            } else {
                ContentUnavailableView(
                    "选择一只股票",
                    systemImage: "chart.xyaxis.line",
                    description: Text("从主窗口的股票详情中打开 K 线")
                )
            }
        }
        .defaultSize(width: 1120, height: 720)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

@MainActor
final class StockerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let window = MainWindowRegistry.window else {
            return true
        }
        window.makeKeyAndOrderFront(nil)
        MainWindowRegistry.restoreFrame()
        sender.activate(ignoringOtherApps: true)
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
}

@MainActor
enum MainWindowRegistry {
    static var window: NSWindow?
    private static var frameBeforeCollapse: NSRect?

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
        return true
    }

    static func collapse() {
        guard let window else { return }
        frameBeforeCollapse = window.frame
        window.orderOut(nil)
    }

    static func restoreFrame() {
        guard let window, let frameBeforeCollapse else { return }
        window.setFrame(frameBeforeCollapse, display: true)
        DispatchQueue.main.async {
            window.setFrame(frameBeforeCollapse, display: true)
        }
    }
}
