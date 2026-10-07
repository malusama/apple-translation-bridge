import Foundation
@preconcurrency import Network

@MainActor
final class LocalHTTPServer {
    struct Response: Sendable {
        let status: Int
        let body: Data
        var contentType = "application/json; charset=utf-8"

        static func error(_ status: Int, code: String, message: String) -> Response {
            let body = (try? JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": message]])) ?? Data()
            return Response(status: status, body: body)
        }
    }

    typealias Handler = @MainActor (String, String, [String: String], Data) async -> Response

    private var listener: NWListener?
    private var connections: [UUID: HTTPConnection] = [:]
    private let handler: Handler
    var onState: (@MainActor (Bool, String?) -> Void)?

    init(handler: @escaping Handler) { self.handler = handler }

    func start(port: UInt16) throws {
        if listener != nil { stop() }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready: self.onState?(true, nil)
                case .failed(let error):
                    self.stop()
                    self.onState?(false, "无法监听这个端口：\(error.localizedDescription)。请换一个端口再试。")
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self, self.connections.count < 64 else { connection.cancel(); return }
                let id = UUID()
                let client = HTTPConnection(connection: connection, handler: self.handler) { [weak self] in
                    self?.connections.removeValue(forKey: id)
                }
                self.connections[id] = client
                client.start()
            }
        }
        // Network delivers all callbacks on the queue passed to start().
        listener.start(queue: .main)
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        let clients = Array(connections.values)
        connections.removeAll()
        clients.forEach { $0.close() }
        onState?(false, nil)
    }
}

@MainActor
private final class HTTPConnection {
    private let connection: NWConnection
    private let handler: LocalHTTPServer.Handler
    private let onClose: @MainActor () -> Void
    private var buffer = Data()
    private var request: (method: String, path: String, headers: [String: String], bodyStart: Int, length: Int)?
    private var processing = false
    private var closed = false
    private var timeout: Task<Void, Never>?
    private var task: Task<Void, Never>?

    init(connection: NWConnection, handler: @escaping LocalHTTPServer.Handler, onClose: @escaping @MainActor () -> Void) {
        self.connection = connection
        self.handler = handler
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .failed = state { self?.close() }
            }
        }
        connection.start(queue: .main)
        armTimeout(seconds: 30)
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true
        timeout?.cancel()
        task?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose()
    }

    private func armTimeout(seconds: Int) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.send(.error(503, code: "timeout", message: "本地翻译处理超时，请稍后重试。"))
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed, !self.processing else { return }
                if let data { self.buffer.append(data) }
                guard self.buffer.count <= 1_048_576 + 16_384 else {
                    self.send(.error(413, code: "request_too_large", message: "请求体不能超过 1 MB。")); return
                }
                self.parse()
                if !self.processing && !self.closed {
                    if complete || error != nil { self.close() } else { self.receive() }
                }
            }
        }
    }

    private func parse() {
        if request == nil {
            guard let separator = buffer.range(of: Data([13, 10, 13, 10])) else {
                if buffer.count > 16_384 { send(.error(431, code: "invalid_request", message: "HTTP 请求头过长。")) }
                return
            }
            guard separator.lowerBound <= 16_384,
                  let header = String(data: buffer[..<separator.lowerBound], encoding: .utf8) else {
                send(.error(400, code: "invalid_request", message: "HTTP 请求头无效。")); return
            }
            let lines = header.components(separatedBy: "\r\n")
            let parts = (lines.first ?? "").split(separator: " ")
            guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0", parts[1].hasPrefix("/") else {
                send(.error(400, code: "invalid_request", message: "HTTP 请求格式无效。")); return
            }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else {
                    send(.error(400, code: "invalid_request", message: "HTTP 请求头无效。")); return
                }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                guard !key.isEmpty, headers[key] == nil else {
                    send(.error(400, code: "invalid_request", message: "HTTP 请求头不能重复。")); return
                }
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard headers["transfer-encoding"] == nil,
                  let length = Int(headers["content-length"] ?? "0"), length >= 0 else {
                send(.error(400, code: "invalid_request", message: "请使用 Content-Length。")); return
            }
            guard length <= 1_048_576 else {
                send(.error(413, code: "request_too_large", message: "请求体不能超过 1 MB。")); return
            }
            let path = String(parts[1].split(separator: "?", maxSplits: 1).first ?? "")
            request = (String(parts[0]), path, headers, separator.upperBound, length)
        }
        guard let request, buffer.count >= request.bodyStart + request.length else { return }
        processing = true
        armTimeout(seconds: 120)
        let body = Data(buffer[request.bodyStart..<request.bodyStart + request.length])
        buffer.removeAll(keepingCapacity: false)
        task = Task { [weak self, handler] in
            let response = await handler(request.method, request.path, request.headers, body)
            guard !Task.isCancelled else { return }
            self?.send(response)
        }
    }

    private func send(_ response: LocalHTTPServer.Response) {
        guard !closed else { return }
        processing = true
        timeout?.cancel()
        let reason = switch response.status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 422: "Unprocessable Content"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        default: "Service Unavailable"
        }
        let header = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization\r\nAccess-Control-Allow-Private-Network: true\r\n\r\n"
        var data = Data(header.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }
}
