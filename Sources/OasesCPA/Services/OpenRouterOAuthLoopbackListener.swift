import Combine
import Foundation
import Network

@MainActor
final class OpenRouterOAuthLoopbackListener: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case waiting
        case readyToExchange
        case exchanging
        case saving
        case completed
        case failed

        var title: String {
            switch self {
            case .idle: OasesLocalization.localized("未开始")
            case .preparing: OasesLocalization.localized("正在准备回调")
            case .waiting: OasesLocalization.localized("等待浏览器授权")
            case .readyToExchange: OasesLocalization.localized("正在处理回调")
            case .exchanging: OasesLocalization.localized("正在换取凭证")
            case .saving: OasesLocalization.localized("正在写入目标")
            case .completed: OasesLocalization.localized("OpenRouter 已连接")
            case .failed: OasesLocalization.localized("连接未完成")
            }
        }

        var systemImage: String {
            switch self {
            case .idle: "circle.dotted"
            case .preparing, .waiting: "hourglass"
            case .readyToExchange, .exchanging, .saving: "arrow.triangle.2.circlepath"
            case .completed: "checkmark.circle.fill"
            case .failed: "xmark.octagon.fill"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var authorizationURL: URL?
    @Published private(set) var callbackURL: URL?
    @Published private(set) var notice: String?
    @Published private(set) var failureMessage: String?
    @Published private(set) var callbackToken: UUID?

    nonisolated private static let listenerQueue = DispatchQueue(
        label: "com.oasescpa.openrouter-oauth.loopback"
    )
    nonisolated private static let maximumRequestBytes = 16_384
    private static let callbackTimeoutNanoseconds: UInt64 = 600_000_000_000

    private var listener: NWListener?
    private var listenerGeneration: UUID?
    private var timeoutTask: Task<Void, Never>?
    private var session: RuntimeOpenRouterOAuthSession?
    private var pendingGrant: RuntimeOpenRouterAuthorizationGrant?

    func begin() {
        cancel()
        phase = .preparing
        notice = nil
        failureMessage = nil

        let generation = UUID()
        listenerGeneration = generation
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)

        do {
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleListenerState(state, generation: generation)
                }
            }
            listener.newConnectionHandler = { [owner = self] connection in
                Self.receiveHTTPRequest(from: connection) { request in
                    Task { @MainActor in
                        let response = owner.handleHTTPRequest(
                            request,
                            generation: generation
                        )
                        Self.sendHTTPResponse(response, on: connection)
                    }
                }
            }
            listener.start(queue: Self.listenerQueue)
        } catch {
            fail(
                message: "无法仅在本机启动 OpenRouter 回调监听：\(error.localizedDescription)"
            )
        }
    }

    func consumeAuthorizationGrant() -> RuntimeOpenRouterAuthorizationGrant? {
        guard phase == .readyToExchange, let pendingGrant else { return nil }
        self.pendingGrant = nil
        session = nil
        phase = .exchanging
        return pendingGrant
    }

    func markSaving() {
        guard phase == .exchanging else { return }
        phase = .saving
    }

    func complete(message: String) {
        clearListenerResources()
        session = nil
        pendingGrant = nil
        callbackToken = nil
        authorizationURL = nil
        callbackURL = nil
        notice = message
        failureMessage = nil
        phase = .completed
    }

    func fail(message: String) {
        clearListenerResources()
        session = nil
        pendingGrant = nil
        callbackToken = nil
        authorizationURL = nil
        callbackURL = nil
        failureMessage = message
        phase = .failed
    }

    func cancel() {
        clearListenerResources()
        session = nil
        pendingGrant = nil
        callbackToken = nil
        authorizationURL = nil
        callbackURL = nil
        notice = nil
        failureMessage = nil
        phase = .idle
    }

    private func handleListenerState(
        _ state: NWListener.State,
        generation: UUID
    ) {
        guard listenerGeneration == generation else { return }
        switch state {
        case .ready:
            guard phase == .preparing,
                  let port = listener?.port,
                  let callbackURL = URL(
                    string: "http://127.0.0.1:\(port.rawValue)/callback"
                  ) else {
                fail(message: OasesLocalization.localized("无法确定 OpenRouter 本机回调地址。"))
                return
            }
            do {
                let session = try RuntimeOpenRouterOAuth.makeSession(callbackURL: callbackURL)
                self.session = session
                self.callbackURL = callbackURL
                authorizationURL = session.authorizationURL
                phase = .waiting
                startTimeout(for: generation)
            } catch {
                fail(message: error.localizedDescription)
            }
        case .failed(let error):
            fail(message: "OpenRouter 本机回调监听失败：\(error.localizedDescription)")
        case .cancelled:
            if phase == .preparing || phase == .waiting {
                fail(message: OasesLocalization.localized("OpenRouter 本机回调监听已取消。"))
            }
        default:
            break
        }
    }

    private func handleHTTPRequest(
        _ request: OpenRouterLoopbackHTTPRequest?,
        generation: UUID
    ) -> OpenRouterLoopbackHTTPResponse {
        guard listenerGeneration == generation,
              phase == .waiting,
              let session else {
            return .serviceUnavailable
        }
        guard let request else {
            notice = OasesLocalization.localized("OpenRouter 回调请求不完整，仍在等待正确的浏览器回调。")
            return .badRequest(OasesLocalization.localized("回调请求不完整。请返回浏览器继续完成授权。"))
        }
        guard request.method == "GET" else {
            return .methodNotAllowed
        }

        let callback = RuntimeOpenRouterOAuth.parseLoopbackCallbackTarget(request.target)
        switch RuntimeOpenRouterOAuth.authorizationGrant(from: callback, session: session) {
        case .success(let grant):
            pendingGrant = grant
            clearListenerResources()
            phase = .readyToExchange
            callbackToken = UUID()
            return .success
        case .failure(.stateMismatch):
            notice = OasesLocalization.localized("已拒绝一个 state 不匹配的本机回调；仍在等待本次浏览器授权。")
            return .badRequest(OasesLocalization.localized("此回调不属于当前授权请求。请返回浏览器继续完成授权。"))
        case .failure(.invalidCallback(let message)):
            notice = "收到无效回调：\(message) 仍在等待正确的浏览器回调。"
            return .badRequest(OasesLocalization.localized("此回调无效。请返回浏览器继续完成授权。"))
        case .failure(let error):
            fail(message: error.localizedDescription)
            return .authorizationFailed
        }
    }

    private func startTimeout(for generation: UUID) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.callbackTimeoutNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.listenerGeneration == generation else {
                return
            }
            self.fail(message: OasesLocalization.localized("等待 OpenRouter 浏览器回调超时，请重新开始授权。"))
        }
    }

    private func clearListenerResources() {
        timeoutTask?.cancel()
        timeoutTask = nil
        listenerGeneration = nil
        listener?.cancel()
        listener = nil
    }

    nonisolated private static func receiveHTTPRequest(
        from connection: NWConnection,
        buffer: Data = Data(),
        completion: @escaping @Sendable (OpenRouterLoopbackHTTPRequest?) -> Void
    ) {
        connection.start(queue: listenerQueue)
        receiveHTTPRequestChunk(
            from: connection,
            buffer: buffer,
            completion: completion
        )
    }

    nonisolated private static func receiveHTTPRequestChunk(
        from connection: NWConnection,
        buffer: Data,
        completion: @escaping @Sendable (OpenRouterLoopbackHTTPRequest?) -> Void
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: maximumRequestBytes
        ) { content, _, isComplete, error in
            var nextBuffer = buffer
            if let content {
                nextBuffer.append(content)
            }
            if nextBuffer.count > maximumRequestBytes {
                completion(nil)
                return
            }
            if hasCompleteHTTPHeaders(in: nextBuffer) {
                completion(parseHTTPRequest(nextBuffer))
                return
            }
            guard error == nil, !isComplete else {
                completion(nil)
                return
            }
            receiveHTTPRequestChunk(
                from: connection,
                buffer: nextBuffer,
                completion: completion
            )
        }
    }

    nonisolated private static func hasCompleteHTTPHeaders(in data: Data) -> Bool {
        data.range(of: Data([13, 10, 13, 10])) != nil
    }

    nonisolated private static func parseHTTPRequest(_ data: Data) -> OpenRouterLoopbackHTTPRequest? {
        guard let headerEnd = data.range(of: Data([13, 10, 13, 10])),
              let text = String(
                data: data.subdata(in: data.startIndex..<headerEnd.lowerBound),
                encoding: .utf8
              ),
              let requestLine = text.split(whereSeparator: \.isNewline).first else {
            return nil
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return nil }
        return OpenRouterLoopbackHTTPRequest(
            method: String(parts[0]).uppercased(),
            target: String(parts[1])
        )
    }

    nonisolated private static func sendHTTPResponse(
        _ response: OpenRouterLoopbackHTTPResponse,
        on connection: NWConnection
    ) {
        let data = response.data
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private struct OpenRouterLoopbackHTTPRequest: Sendable {
    let method: String
    let target: String
}

private enum OpenRouterLoopbackHTTPResponse {
    case success
    case badRequest(String)
    case methodNotAllowed
    case authorizationFailed
    case serviceUnavailable

    var data: Data {
        let response: (Int, String, String, String)
        switch self {
        case .success:
            response = (
                200,
                "OK",
                OasesLocalization.localized("OpenRouter 已授权"),
                OasesLocalization.localized("授权已安全返回 Oases CPA。你现在可以关闭此页并回到 App。")
            )
        case .badRequest(let message):
            response = (400, "Bad Request", OasesLocalization.localized("OpenRouter 回调无效"), message)
        case .methodNotAllowed:
            response = (
                405,
                "Method Not Allowed",
                OasesLocalization.localized("不支持的请求"),
                OasesLocalization.localized("此本机回调只接受浏览器的 GET 请求。")
            )
        case .authorizationFailed:
            response = (
                400,
                "Bad Request",
                OasesLocalization.localized("OpenRouter 授权未完成"),
                OasesLocalization.localized("App 已记录授权失败原因。请回到 Oases CPA 查看并重新开始。")
            )
        case .serviceUnavailable:
            response = (
                410,
                "Gone",
                OasesLocalization.localized("授权会话已结束"),
                OasesLocalization.localized("此本机回调会话已结束。请回到 Oases CPA 重新开始授权。")
            )
        }
        let html = """
        <!doctype html>
        <html lang="zh-CN">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(htmlEscaped(response.2))</title>
            <style>
              body { margin: 0; font: -apple-system-body, BlinkMacSystemFont, sans-serif; background: #f5f5f7; color: #1d1d1f; }
              main { max-width: 560px; margin: 12vh auto; padding: 28px; background: white; border-radius: 16px; box-shadow: 0 12px 35px rgba(0,0,0,.08); }
              h1 { font-size: 22px; margin: 0 0 12px; } p { line-height: 1.6; color: #515154; }
            </style>
          </head>
          <body><main><h1>\(htmlEscaped(response.2))</h1><p>\(htmlEscaped(response.3))</p></main></body>
        </html>
        """
        let body = Data(html.utf8)
        let headers = """
        HTTP/1.1 \(response.0) \(response.1)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r
        """
        return Data(headers.utf8) + body
    }

    private func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
