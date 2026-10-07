import AppKit
import Observation
import ServiceManagement
@preconcurrency import Translation

@MainActor @Observable
final class BridgeModel {
    var sourceText = "The translation runs entirely on your Mac, even when you are offline."
    var translatedText = ""
    var translating = false
    var checking = false
    var downloading = false
    var languageReady = false
    var languageStatus = "正在检查语言包…"
    var errorMessage: String?
    var serviceRunning = false
    var serviceStarting = false
    var portText: String
    var requestCount = 0
    var translatedRows = 0
    var lastElapsed: Int?
    var launchAtLogin = false
    var downloadConfiguration: TranslationSession.Configuration?

    @ObservationIgnored private let queue = TranslationQueue()
    @ObservationIgnored private var server: LocalHTTPServer?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var activePort: UInt16?
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var failedRequests = 0
    @ObservationIgnored var onServiceChange: (@MainActor () -> Void)?

    init() {
        let saved = UserDefaults.standard.integer(forKey: "servicePort")
        portText = String((1024...65535).contains(saved) ? saved : 3210)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var endpoint: String { "http://127.0.0.1:\(activePort.map(String.init) ?? portText)/imme" }

    func initialize() async {
        await refreshLanguages()
        if languageReady && defaults.bool(forKey: "serviceEnabled") { startService() }
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--test-port"),
           CommandLine.arguments.indices.contains(index + 1) {
            portText = CommandLine.arguments[index + 1]
            startService()
        }
        #endif
    }

    func refreshLanguages() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let data = await queue.submit(Data(#"{"op":"health"}"#.utf8))
        guard let health = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        languageReady = health["ready"] as? Bool == true
        languageStatus = languageReady ? "英文 → 简体中文 · 已就绪" : "英文 → 简体中文 · 需要下载语言包"
        if let error = health["error"] as? [String: Any] { errorMessage = error["message"] as? String }
    }

    func requestDownload() {
        errorMessage = nil
        downloading = true
        if downloadConfiguration == nil {
            downloadConfiguration = TranslationSession.Configuration(
                source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"),
                preferredStrategy: .lowLatency
            )
        } else { downloadConfiguration?.invalidate() }
    }

    func installLanguages(using session: TranslationSession) async {
        guard downloading else { return }
        defer { downloading = false }
        do {
            try await session.prepareTranslation()
            _ = try await session.translate("Hello. This translation is processed on your Mac.")
            guard await session.isReady else {
                errorMessage = "语言包正在安装。请稍后点击“重新检查”。"
                return
            }
            await refreshLanguages()
        } catch {
            errorMessage = "语言包下载未完成：\(error.localizedDescription)"
            await refreshLanguages()
        }
    }

    func translate() async {
        guard !translating, !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        translating = true
        errorMessage = nil
        defer { translating = false }
        let payload: [String: Any] = ["op": "translate", "source_lang": "en", "target_lang": "zh-CN", "text_list": sourceText.components(separatedBy: "\n")]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let result = await queue.submit(data)
        if let value = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any] {
            if let error = value["error"] as? [String: Any] {
                errorMessage = error["message"] as? String ?? "翻译失败，请重试。"
                if error["code"] as? String == "model_not_installed" { await refreshLanguages() }
            } else if let rows = value["translations"] as? [[String: Any]] {
                translatedText = rows.compactMap { $0["text"] as? String }.joined(separator: "\n")
                lastElapsed = value["elapsed_ms"] as? Int
            }
        }
    }

    func startService() {
        guard !serviceRunning, !serviceStarting else { return }
        guard let port = UInt16(portText), port >= 1024 else {
            errorMessage = "请输入 1024 到 65535 之间的端口。"; return
        }
        errorMessage = nil
        serviceStarting = true
        activePort = port
        let server = LocalHTTPServer { [weak self] method, path, headers, data in
            guard let self else { return .error(503, code: "unavailable", message: "服务已停止。") }
            return await self.handle(method: method, path: path, headers: headers, body: data)
        }
        server.onState = { [weak self] running, error in
            guard let self else { return }
            self.serviceRunning = running
            self.serviceStarting = false
            if running {
                self.defaults.set(Int(port), forKey: "servicePort")
                self.defaults.set(true, forKey: "serviceEnabled")
                self.startedAt = Date()
            }
            if let error { self.errorMessage = error }
            self.onServiceChange?()
        }
        self.server = server
        do { try server.start(port: port) } catch {
            serviceStarting = false
            errorMessage = "服务启动失败：\(error.localizedDescription)"
        }
    }

    func stopService() {
        defaults.set(false, forKey: "serviceEnabled")
        shutdown()
    }

    func shutdown() {
        server?.stop()
        server = nil
        activePort = nil
        serviceStarting = false
        serviceRunning = false
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if enabled && !launchAtLogin { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            errorMessage = "无法更新登录启动设置：\(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func handle(method: String, path: String, headers: [String: String], body: Data) async -> LocalHTTPServer.Response {
        if method == "OPTIONS" { return .init(status: 204, body: Data()) }
        if method == "GET", path == "/" {
            guard let url = Bundle.main.url(forResource: "index", withExtension: "html"),
                  let data = try? Data(contentsOf: url) else {
                return .error(404, code: "not_found", message: "测试页面不可用。")
            }
            return .init(status: 200, body: data, contentType: "text/html; charset=utf-8")
        }
        if method == "GET", path == "/health" || path == "/languages" {
            let data = await queue.submit(Data(#"{"op":"health"}"#.utf8))
            guard var value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .error(503, code: "unavailable", message: "翻译引擎不可用。")
            }
            value["metrics"] = ["requests": requestCount, "translated_rows": translatedRows, "failed_requests": failedRequests, "last_elapsed_ms": lastElapsed ?? 0]
            value["uptime_seconds"] = Int(Date().timeIntervalSince(startedAt ?? Date()))
            return .init(status: value["error"] == nil ? 200 : 503, body: (try? JSONSerialization.data(withJSONObject: value)) ?? data)
        }
        guard path == "/imme" || path == "/translate" else {
            return .error(404, code: "not_found", message: "请使用 POST /imme。")
        }
        guard method == "POST" else { return .error(405, code: "invalid_request", message: "请使用 POST。") }
        guard headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
            return .error(415, code: "invalid_request", message: "请使用 application/json。")
        }
        guard !body.isEmpty, let request = try? JSONDecoder().decode(Request.self, from: body),
              let rows = request.text_list, !rows.isEmpty, rows.count <= 128,
              rows.reduce(0, { $0 + $1.count }) <= 100_000,
              let target = request.target_lang, !target.isEmpty, target != "auto", target.count <= 32,
              request.source_lang.map({ !$0.isEmpty && $0.count <= 32 }) ?? true else {
            return .error(400, code: "invalid_request", message: "需要有效的 target_lang 和 1 到 128 段文本，总长度不能超过 100000 字符。")
        }
        let payload: [String: Any] = ["op": "translate", "source_lang": request.source_lang ?? "auto", "target_lang": target, "text_list": rows]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let result = await queue.submit(data)
        requestCount += 1
        guard let value = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any] else {
            failedRequests += 1
            return .error(503, code: "unavailable", message: "翻译引擎不可用。")
        }
        if let error = value["error"] as? [String: Any] {
            failedRequests += 1
            let status = switch error["code"] as? String {
            case "busy": 429
            case "model_not_installed", "translation_error": 503
            default: 422
            }
            return .init(status: status, body: result)
        }
        translatedRows += rows.count
        lastElapsed = value["elapsed_ms"] as? Int
        return .init(status: 200, body: result)
    }
}
