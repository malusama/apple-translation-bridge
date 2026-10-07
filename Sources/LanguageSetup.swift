import AppKit
import Foundation
import SwiftUI
// TranslationSession's SwiftUI-owned download session lacks Sendable annotations.
// This one-shot installer only uses each session within its translationTask.
@preconcurrency import Translation

@main
enum LanguageSetupApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = LanguageSetupDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class LanguageSetupDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 490, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Apple 本地翻译语言包"
        window.contentView = NSHostingView(rootView: LanguageSetupView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct LanguageSetupView: View {
    @State private var configuration: TranslationSession.Configuration?
    @State private var progress = "准备下载本地翻译语言包。"
    @State private var completed: [String] = []
    @State private var pending = CommandLine.arguments.contains("--include-japanese") ? ["en", "ja"] : ["en"]

    private let statusURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".local/share/apple-translation-bridge/setup-status.json")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Apple 本地翻译").font(.title2.bold())
            Text("下载完成后，这台 Mac 的翻译接口可以离线使用。")
                .foregroundStyle(.secondary)
            Text(progress).textSelection(.enabled)
            if !completed.isEmpty {
                Text("已完成：" + completed.joined(separator: "、"))
            }
            Button("下载语言包") { startNext() }
                .disabled(configuration != nil || pending.isEmpty)
            if pending.isEmpty && configuration == nil {
                Button("完成") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(24)
        .frame(width: 440)
        .translationTask(configuration) { session in
            let source = session.sourceLanguage?.minimalIdentifier ?? "unknown"
            do {
                try await session.prepareTranslation()
                progress = "正在下载语言包，请保持窗口打开…"
                saveStatus(state: "downloading", source: source)
                // A real translation waits for all assets, beyond download consent.
                _ = try await session.translate(source == "ja" ? "こんにちは。" : "Hello.")
                while !(await session.isReady) {
                    try await Task.sleep(for: .seconds(1))
                }
                completed.append(source == "ja" ? "日文 → 中文" : "英文 → 中文")
                saveStatus(state: "installed", source: source)
                configuration = nil
                startNext()
            } catch {
                progress = error.localizedDescription
                pending.insert(source, at: 0)
                saveStatus(state: "error", source: source)
                configuration = nil
            }
        }
        .onAppear {
            NSApplication.shared.activate(ignoringOtherApps: true)
            startNext()
        }
    }

    private func startNext() {
        guard configuration == nil, !pending.isEmpty else {
            if pending.isEmpty { progress = "所选语言包已就绪。可以关闭此窗口。" }
            return
        }
        let source = pending.removeFirst()
        progress = source == "en" ? "正在准备英文 → 中文语言包…" : "正在准备日文 → 中文语言包…"
        configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: source),
            target: Locale.Language(identifier: "zh-Hans"),
            preferredStrategy: .lowLatency
        )
        saveStatus(state: "preparing", source: source)
    }

    private func saveStatus(state: String, source: String) {
        let value: [String: Any] = [
            "state": state, "source": source, "progress": progress,
            "completed": completed, "updated_at": ISO8601DateFormatter().string(from: Date())
        ]
        do {
            try FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            try data.write(to: statusURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        }
    }
}
