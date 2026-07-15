import AppKit
import SwiftUI

@objc(StockerApplication)
final class StockerApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown,
           modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w",
           let window = MainWindowRegistry.window,
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
                Button("收起窗口") { MainWindowRegistry.collapse() }
                    .keyboardShortcut("w", modifiers: .command)
                Button("刷新行情") { Task { await store.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
            }

            CommandMenu("股票") {
                Button("添加股票…") { store.isSearchPresented = true }
                    .keyboardShortcut("d", modifiers: .command)
                Button("完成添加") { store.isSearchPresented = false }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!store.isSearchPresented)
            }
        }

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
