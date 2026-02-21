import Foundation

struct GLKVMResponse<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result
}

struct GLKVMEmptyResult: Decodable {}

struct GLKVMAuthLoginResult: Decodable {
    let token: String
}

struct GLKVMStatusResult: Decodable {
    let status: String?
    let message: String?
}

final class GLKVMClient {
    enum ClientError: Error {
        case invalidBaseURL
        case invalidURL
        case httpError(statusCode: Int)
        case decodingFailed
    }

    private final class SessionDelegate: NSObject, URLSessionDelegate {
        let allowInsecureTLS: Bool

        init(allowInsecureTLS: Bool) {
            self.allowInsecureTLS = allowInsecureTLS
        }

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard allowInsecureTLS,
                  challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    let baseURL: URL
    var authToken: String?

    private let session: URLSession

    init(host: String, port: Int = 443, authToken: String? = nil, allowInsecureTLS: Bool = true) throws {
        guard let url = URL(string: "https://\(host):\(port)") else {
            throw ClientError.invalidBaseURL
        }

        self.baseURL = url
        self.authToken = authToken

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20

        self.session = URLSession(configuration: config, delegate: SessionDelegate(allowInsecureTLS: allowInsecureTLS), delegateQueue: nil)
    }

    convenience init(device: KVMDevice, allowInsecureTLS: Bool = true) throws {
        try self.init(host: device.host, port: device.port, authToken: device.authToken.isEmpty ? nil : device.authToken, allowInsecureTLS: allowInsecureTLS)
    }

    private func makeURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ClientError.invalidURL
        }

        components.path = "/" + trimmed
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw ClientError.invalidURL
        }

        return url
    }

    private func request<Response: Decodable>(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil,
        responseType: Response.Type
    ) async throws -> Response {
        let url = try makeURL(path: path, queryItems: query)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body

        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        if let authToken, !authToken.isEmpty {
            request.setValue("auth_token=\(authToken)", forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.decodingFailed
        }

        guard (200...299).contains(http.statusCode) else {
            throw ClientError.httpError(statusCode: http.statusCode)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ClientError.decodingFailed
        }
    }

    func authCheck() async throws {
        _ = try await request(
            method: "GET",
            path: "api/auth/check",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func authLogin(user: String = "admin", password: String) async throws -> String {
        let boundary = "----GLKVMClientBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
        body.append("Content-Disposition: form-data; name=\"user\"\r\n\r\n".data(using: .utf8) ?? Data())
        body.append("\(user)\r\n".data(using: .utf8) ?? Data())
        body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
        body.append("Content-Disposition: form-data; name=\"passwd\"\r\n\r\n".data(using: .utf8) ?? Data())
        body.append("\(password)\r\n".data(using: .utf8) ?? Data())
        body.append("--\(boundary)--\r\n".data(using: .utf8) ?? Data())

        let response = try await request(
            method: "POST",
            path: "api/auth/login",
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            responseType: GLKVMResponse<GLKVMAuthLoginResult>.self
        )

        return response.result.token
    }

    func setHidConnected(_ connected: Bool) async throws {
        _ = try await request(
            method: "POST",
            path: "api/hid/set_connected",
            query: [URLQueryItem(name: "connected", value: connected ? "true" : "false")],
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func setEDIDHex(_ edidHex: String) async throws {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "edid", value: edidHex)]
        let body = components.percentEncodedQuery?.data(using: .utf8) ?? Data()

        _ = try await request(
            method: "POST",
            path: "api/upgrade/edid",
            body: body,
            contentType: "application/x-www-form-urlencoded; charset=utf-8",
            responseType: GLKVMResponse<GLKVMStatusResult>.self
        )
    }

    func websocketURL() throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ClientError.invalidURL
        }
        components.scheme = "wss"
        components.path = "/api/ws"
        guard let url = components.url else {
            throw ClientError.invalidURL
        }
        return url
    }

    func makeWebSocketClient() throws -> WebSocketClient {
        let url = try websocketURL()

        var request = URLRequest(url: url)
        if let authToken, !authToken.isEmpty {
            request.setValue("auth_token=\(authToken)", forHTTPHeaderField: "Cookie")
        }

        return WebSocketClient(session: session, request: request)
    }

    actor WebSocketClient {
        enum WebSocketError: Error {
            case notConnected
        }

        private let session: URLSession
        private let request: URLRequest

        private var task: URLSessionWebSocketTask?

        init(session: URLSession, request: URLRequest) {
            self.session = session
            self.request = request
        }

        func connect() {
            guard task == nil else { return }
            let ws = session.webSocketTask(with: request)
            task = ws
            ws.resume()
        }

        func disconnect() {
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
        }

        private func sendBinary(_ data: Data) async throws {
            guard let task else {
                throw WebSocketError.notConnected
            }
            try await task.send(.data(data))
        }

        func sendHidKey(key: String, state: Bool) async throws {
            var payload = Data()
            payload.reserveCapacity(2 + key.utf8.count)
            payload.append(0x01)
            payload.append(state ? 0x01 : 0x00)
            payload.append(contentsOf: key.utf8)
            try await sendBinary(payload)
        }

        func sendHidMouseButton(button: String, state: Bool) async throws {
            var payload = Data()
            payload.reserveCapacity(2 + button.utf8.count)
            payload.append(0x02)
            payload.append(state ? 0x01 : 0x00)
            payload.append(contentsOf: button.utf8)
            try await sendBinary(payload)
        }

        func sendHidMouseMove(toX: Int, toY: Int) async throws {
            let sx = Int16(clamping: toX)
            let sy = Int16(clamping: toY)
            let ux = UInt16(bitPattern: sx)
            let uy = UInt16(bitPattern: sy)
            let payload = Data([
                0x03,
                UInt8((ux >> 8) & 0xFF),
                UInt8(ux & 0xFF),
                UInt8((uy >> 8) & 0xFF),
                UInt8(uy & 0xFF),
            ])
            try await sendBinary(payload)
        }

        func sendHidMouseWheel(deltaX: Int, deltaY: Int) async throws {
            let dx = UInt8(bitPattern: Int8(clamping: deltaX))
            let dy = UInt8(bitPattern: Int8(clamping: deltaY))
            let payload = Data([
                0x05,
                0x00,
                dx,
                dy,
            ])
            try await sendBinary(payload)
        }
    }
}
