import Foundation
import NaturalLanguage
import Translation

struct Request: Decodable {
    let op: String?
    let source_lang: String?
    let target_lang: String?
    let text_list: [String]?
}

struct BridgeError: Error {
    let code: String
    let message: String
}

@main
enum TranslationWorker {
    private static let markerPattern = #"\{\d+\}|</?[A-Za-z][^<>]*>|https?://[^\s<>]+"#

    static func main() async {
        await run()
    }

    // All sessions stay in this single sequential worker; HTTP concurrency is queued.
    nonisolated static func run() async {
        var sessions: [String: TranslationSession] = [:]
        let availability = LanguageAvailability(preferredStrategy: .lowLatency)
        emit(["ready": true, "engine": "Apple Translation", "strategy": "lowLatency"])
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                do {
                    let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
                    if request.op == "health" || request.op == "languages" {
                        let languages = await availability.supportedLanguages
                        var pairs: [String: String] = [:]
                        for source in ["en", "ja"] {
                            let status = await availability.status(
                                from: Locale.Language(identifier: source),
                                to: Locale.Language(identifier: "zh-Hans")
                            )
                            pairs[source + "->zh-CN"] = String(describing: status)
                        }
                        emit([
                            "engine": "Apple Translation", "strategy": "lowLatency",
                            "offline": true, "language_pairs": pairs,
                            "ready": pairs["en->zh-CN"] == "installed",
                            "required_language_pairs": ["en->zh-CN"],
                            "supported_languages": languages.map(\.minimalIdentifier).sorted()
                        ])
                        continue
                    }
                    guard let texts = request.text_list, let targetCode = request.target_lang else {
                        throw BridgeError(code: "invalid_request", message: "需要 target_lang 和 text_list。")
                    }
                    let target = normalized(targetCode)
                    let start = Date()
                    var rows = Array(repeating: ["detected_source_lang": "auto", "text": ""], count: texts.count)
                    var groups: [String: [(Int, String)]] = [:]
                    for (index, text) in texts.enumerated() {
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            rows[index] = ["detected_source_lang": request.source_lang ?? "auto", "text": text]
                            continue
                        }
                        let source: String
                        if let explicit = request.source_lang, explicit != "auto" {
                            source = normalized(explicit)
                        } else {
                            let recognizer = NLLanguageRecognizer()
                            let detectorText = text.replacingOccurrences(of: markerPattern, with: " ", options: .regularExpression)
                            recognizer.processString(detectorText)
                            guard let language = recognizer.dominantLanguage else {
                                // Pure markup, numbers and punctuation contain no translatable language.
                                rows[index] = ["detected_source_lang": "auto", "text": text]
                                continue
                            }
                            source = normalized(language.rawValue)
                        }
                        if source == target {
                            rows[index] = ["detected_source_lang": source, "text": text]
                        } else {
                            groups[source, default: []].append((index, text))
                        }
                    }
                    for source in groups.keys.sorted() {
                        guard let items = groups[source] else { continue }
                        let key = source + "->" + target
                        let session: TranslationSession
                        if let existing = sessions[key] {
                            session = existing
                        } else {
                            let sourceLanguage = Locale.Language(identifier: source)
                            let targetLanguage = Locale.Language(identifier: target)
                            let status = await availability.status(from: sourceLanguage, to: targetLanguage)
                            switch status {
                            case .supported:
                                throw BridgeError(code: "model_not_installed", message: "尚未下载语言包：" + key + "。请在运行服务的 Mac 上下载对应语言包。")
                            case .unsupported:
                                throw BridgeError(code: "unsupported_language_pair", message: "Apple 本地翻译不支持：" + key)
                            case .installed:
                                break
                            @unknown default:
                                throw BridgeError(code: "translation_unavailable", message: "未知语言包状态：" + key)
                            }
                            session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage, preferredStrategy: .lowLatency)
                            if sessions.count >= 8 { sessions.removeAll() }
                            sessions[key] = session
                        }
                        let batch = items.map { index, text in
                            TranslationSession.Request(sourceText: protected(text), clientIdentifier: String(index))
                        }
                        let translated = try await session.translations(from: batch)
                        guard translated.count == items.count else {
                            throw BridgeError(code: "incomplete_translation", message: "翻译引擎返回的段落数量不完整。")
                        }
                        for (item, response) in zip(items, translated) {
                            let text: String
                            if markers(item.1) == markers(response.targetText) {
                                text = response.targetText
                            } else {
                                text = try await translatePieces(item.1, session: session)
                            }
                            guard markers(item.1) == markers(text) else {
                                throw BridgeError(code: "placeholder_mismatch", message: "翻译引擎未完整保留网页占位符。")
                            }
                            rows[item.0] = ["detected_source_lang": source, "text": text]
                        }
                    }
                    emit(["translations": rows, "engine": "Apple Translation", "elapsed_ms": Int(Date().timeIntervalSince(start) * 1000)])
                } catch let error as BridgeError {
                    emit(["error": ["code": error.code, "message": error.message]])
                } catch {
                    let underlying = error as NSError
                    emit(["error": ["code": "translation_error", "message": error.localizedDescription,
                                     "domain": underlying.domain, "native_code": underlying.code]])
                }
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        }
    }

    private static func normalized(_ language: String) -> String {
        switch language.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "zh", "zh-cn", "zh-hans", "zh-hans-cn": "zh-Hans"
        case "zh-tw", "zh-hk", "zh-hant", "zh-hant-tw": "zh-Hant"
        case "en-us", "en": "en"
        default: language.replacingOccurrences(of: "_", with: "-")
        }
    }

    private static func protected(_ text: String) -> AttributedString {
        var value = AttributedString(text)
        guard let regex = try? NSRegularExpression(pattern: markerPattern) else { return value }
        let searchRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: searchRange) {
            guard let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: value),
                  let upper = AttributedString.Index(range.upperBound, within: value) else { continue }
            value[lower..<upper].skipsTranslation = true
        }
        return value
    }

    private static func markers(_ text: String) -> [String: Int] {
        guard let regex = try? NSRegularExpression(pattern: markerPattern) else { return [:] }
        var counts: [String: Int] = [:]
        for match in regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
            if let range = Range(match.range, in: text) { counts[String(text[range]), default: 0] += 1 }
        }
        return counts
    }

    // Traditional models can ignore skip attributes. Translate text spans while
    // keeping markup and surrounding whitespace outside the model in that case.
    nonisolated private static func translatePieces(_ text: String, session: TranslationSession) async throws -> String {
        let regex = try NSRegularExpression(pattern: markerPattern)
        var pieces: [(String, Bool)] = []
        var cursor = text.startIndex

        func appendText(_ raw: String) {
            let core = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if core.isEmpty || !core.contains(where: \.isLetter) {
                pieces.append((raw, false))
            } else {
                pieces.append((String(raw.prefix(while: \.isWhitespace)), false))
                pieces.append((core, true))
                pieces.append((String(raw.reversed().prefix(while: \.isWhitespace).reversed()), false))
            }
        }

        for match in regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            appendText(String(text[cursor..<range.lowerBound]))
            pieces.append((String(text[range]), false))
            cursor = range.upperBound
        }
        appendText(String(text[cursor...]))
        var output = pieces.map(\.0)
        let indices = pieces.indices.filter { pieces[$0].1 }
        for offset in stride(from: 0, to: indices.count, by: 64) {
            let selected = Array(indices[offset..<min(offset + 64, indices.count)])
            let requests = selected.map { TranslationSession.Request(sourceText: pieces[$0].0, clientIdentifier: String($0)) }
            let responses = try await session.translations(from: requests)
            guard responses.count == selected.count else {
                throw BridgeError(code: "incomplete_translation", message: "占位符处理返回的文本数量不完整。")
            }
            for (index, response) in zip(selected, responses) { output[index] = response.targetText }
        }
        return output.joined()
    }

    private static func emit(_ value: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        }
    }
}
