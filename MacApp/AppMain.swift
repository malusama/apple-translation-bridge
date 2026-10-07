import AppKit
import SwiftUI

@main
enum AppMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = BridgeModel()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var toggleItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于本地翻译桥", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出本地翻译桥", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let root = NSMenuItem(); root.submenu = appMenu; menu.addItem(root)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); editItem.submenu = edit; menu.addItem(editItem)
        NSApplication.shared.mainMenu = menu

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 825), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "本地翻译桥"
        window.contentView = NSHostingView(rootView: BridgeView(model: model))
        window.minSize = NSSize(width: 800, height: 790)
        window.isReleasedWhenClosed = false
        window.center()
        #if DEBUG
        if CommandLine.arguments.contains("--screenshot") {
            window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY, width: 1280, height: 800), display: false)
            window.center()
        }
        #endif
        self.window = window

        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "本地翻译桥")
        status.button?.image?.isTemplate = true
        let statusMenu = NSMenu()
        let show = NSMenuItem(title: "打开翻译窗口", action: #selector(showWindow), keyEquivalent: ""); show.target = self; statusMenu.addItem(show)
        let toggle = NSMenuItem(title: "启动本地接口", action: #selector(toggleService), keyEquivalent: ""); toggle.target = self; statusMenu.addItem(toggle)
        toggleItem = toggle
        let copy = NSMenuItem(title: "复制接口地址", action: #selector(copyEndpoint), keyEquivalent: ""); copy.target = self; statusMenu.addItem(copy)
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "退出本地翻译桥", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = statusMenu
        statusItem = status
        model.onServiceChange = { [weak self] in
            guard let self else { return }
            self.toggleItem?.title = self.model.serviceRunning ? "停止本地接口" : "启动本地接口"
            self.statusItem?.button?.toolTip = self.model.serviceRunning ? "本地翻译桥 · 接口运行中" : "本地翻译桥 · 接口已停止"
        }
        showWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }

    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }

    @objc private func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    @objc private func toggleService() {
        if model.serviceRunning { model.stopService() } else { model.startService() }
    }

    @objc private func copyEndpoint() { model.copy(model.endpoint) }
}
