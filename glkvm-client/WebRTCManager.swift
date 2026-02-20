import Foundation
#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif
import Combine

#if canImport(WebRTC)
@MainActor
final class WebRTCManager: NSObject, ObservableObject {
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

    @Published var videoView: RTCMTLNSVideoView?
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var hasEverConnectedToStream = false
    @Published var isStreamStalled = false
    @Published var lastDisconnectReason: String?
    @Published var videoSize: CGSize?

    private var peerConnection: RTCPeerConnection?
    private var videoTrack: RTCVideoTrack?
    private var factory: RTCPeerConnectionFactory?

    private var signalingSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?

    private var janusSessionId: Int?
    private var janusHandleId: Int?
    private var janusWaiters: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var janusKeepAliveTimer: Timer?

    private let allowInsecureTLS = true

    override init() {
        super.init()
        setupWebRTC()
    }

    private func setupWebRTC() {
        factory = WebRTCFactoryBuilder.makeFactory()
        if videoView == nil {
            videoView = RTCMTLNSVideoView(frame: .zero)
        }
    }

    func connect(to device: KVMDevice) async throws {
        setupWebRTC()

        guard let factory else {
            throw WebRTCError.factoryNotInitialized
        }

        isConnecting = true
        isConnected = false
        isStreamStalled = false
        lastDisconnectReason = nil

        do {
            if videoView == nil {
                videoView = RTCMTLNSVideoView(frame: .zero)
            }

            let configuration = RTCConfiguration()
            configuration.iceServers = []
            configuration.sdpSemantics = .unifiedPlan

            let constraints = RTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: ["OfferToReceiveVideo": "true"]
            )

            peerConnection = factory.peerConnection(
                with: configuration,
                constraints: constraints,
                delegate: self
            )

            try await connectToSignalingServer(device: device)
        } catch {
            disconnect()
            lastDisconnectReason = "Connect failed"
            throw error
        }
    }

    func reconnect(to device: KVMDevice) async {
        disconnect()
        do {
            try await connect(to: device)
        } catch {
            isConnecting = false
            lastDisconnectReason = "Reconnect failed"
        }
    }

    private func connectToSignalingServer(device: KVMDevice) async throws {
        guard let rawURL = URL(string: device.webRTCURL) else {
            throw WebRTCError.invalidSignalingURL
        }

        let url = normalizedWebSocketURL(rawURL)
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: SessionDelegate(allowInsecureTLS: allowInsecureTLS), delegateQueue: nil)
        signalingSession = session

        var request = URLRequest(url: url)
        if !device.authToken.isEmpty {
            request.setValue("auth_token=\(device.authToken)", forHTTPHeaderField: "Cookie")
        }
        request.setValue("https://\(device.host):\(device.port)", forHTTPHeaderField: "Origin")
        request.setValue("janus-protocol", forHTTPHeaderField: "Sec-WebSocket-Protocol")

        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()

        Task {
            await listenForSignalingMessages()
        }

        let createTransaction = makeJanusTransaction()
        try await sendJanusMessage([
            "janus": "create",
            "transaction": createTransaction,
        ])

        let createResponse = try await waitForJanusTransaction(createTransaction)
        guard let data = createResponse["data"] as? [String: Any],
              let sessionId = data["id"] as? Int else {
            throw WebRTCError.signalingConnectionLost
        }
        janusSessionId = sessionId

        let attachTransaction = makeJanusTransaction()
        try await sendJanusMessage([
            "janus": "attach",
            "plugin": "janus.plugin.ustreamer",
            "opaque_id": "oid-\(UUID().uuidString)",
            "transaction": attachTransaction,
            "session_id": sessionId,
        ])

        let attachResponse = try await waitForJanusTransaction(attachTransaction)
        guard let attachData = attachResponse["data"] as? [String: Any],
              let handleId = attachData["id"] as? Int else {
            throw WebRTCError.signalingConnectionLost
        }
        janusHandleId = handleId

        let watchTransaction = makeJanusTransaction()
        try await sendJanusMessage([
            "janus": "message",
            "body": [
                "request": "watch",
                "params": [
                    "orientation": 0,
                    "audio": false,
                    "video": true,
                    "mic": false,
                    "camera": false,
                ],
            ],
            "transaction": watchTransaction,
            "session_id": sessionId,
            "handle_id": handleId,
        ])

        startJanusKeepAlive()
    }

    private func startJanusKeepAlive() {
        janusKeepAliveTimer?.invalidate()
        janusKeepAliveTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                try? await self.sendJanusKeepAlive()
            }
        }
    }

    private func sendJanusKeepAlive() async throws {
        guard let sessionId = janusSessionId else { return }
        try await sendJanusMessage([
            "janus": "keepalive",
            "session_id": sessionId,
            "transaction": makeJanusTransaction(),
        ])
    }

    private func sendJanusTrickleCandidate(_ candidate: RTCIceCandidate, handleId: Int) async throws {
        guard let sessionId = janusSessionId else { return }
        try await sendJanusMessage([
            "janus": "trickle",
            "candidate": [
                "candidate": candidate.sdp,
                "sdpMid": candidate.sdpMid ?? "0",
                "sdpMLineIndex": Int(candidate.sdpMLineIndex),
            ],
            "transaction": makeJanusTransaction(),
            "session_id": sessionId,
            "handle_id": handleId,
        ])
    }

    private func sendJanusTrickleCompleted(handleId: Int) async throws {
        guard let sessionId = janusSessionId else { return }
        try await sendJanusMessage([
            "janus": "trickle",
            "candidate": ["completed": true],
            "transaction": makeJanusTransaction(),
            "session_id": sessionId,
            "handle_id": handleId,
        ])
    }

    private func makeJanusTransaction() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private func waitForJanusTransaction(_ transaction: String) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            janusWaiters[transaction] = continuation
        }
    }

    private func sendJanusMessage(_ message: [String: Any]) async throws {
        guard let webSocketTask,
              let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else {
            throw WebRTCError.signalingConnectionLost
        }
        try await webSocketTask.send(.string(text))
    }

    private func normalizedWebSocketURL(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        if comps.scheme == "https" {
            comps.scheme = "wss"
        } else if comps.scheme == "http" {
            comps.scheme = "ws"
        } else if comps.scheme == nil {
            comps.scheme = "wss"
        }

        return comps.url ?? url
    }

    private func listenForSignalingMessages() async {
        while let webSocketTask {
            do {
                let message = try await webSocketTask.receive()
                await handleSignalingMessage(message)
            } catch {
                isConnecting = false
                if isConnected || hasEverConnectedToStream || lastDisconnectReason == nil {
                    lastDisconnectReason = "Signaling connection lost"
                }
                break
            }
        }
    }

    private func handleSignalingMessage(_ message: URLSessionWebSocketTask.Message) async {
        switch message {
        case .string(let string):
            guard let data = string.data(using: .utf8),
                  let signalingMessage = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            await handleJanusMessage(signalingMessage)
        case .data(let data):
            guard let signalingMessage = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            await handleJanusMessage(signalingMessage)
        @unknown default:
            break
        }
    }

    private func handleJanusMessage(_ message: [String: Any]) async {
        if let transaction = message["transaction"] as? String,
           let waiter = janusWaiters.removeValue(forKey: transaction) {
            waiter.resume(returning: message)
            return
        }

        guard let janusType = message["janus"] as? String else { return }
        if janusType == "trickle" {
            guard let candidateObj = message["candidate"] as? [String: Any],
                  let candidateString = candidateObj["candidate"] as? String,
                  let peerConnection else {
                return
            }

            if (candidateObj["completed"] as? Bool) == true {
                return
            }

            let sdpMid = candidateObj["sdpMid"] as? String
            let sdpMLineIndex: Int32
            if let idx32 = candidateObj["sdpMLineIndex"] as? Int32 {
                sdpMLineIndex = idx32
            } else if let idx = candidateObj["sdpMLineIndex"] as? Int {
                sdpMLineIndex = Int32(idx)
            } else {
                sdpMLineIndex = 0
            }

            let iceCandidate = RTCIceCandidate(sdp: candidateString, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
            try? await peerConnection.add(iceCandidate)
            return
        }

        if janusType != "event" { return }

        guard let jsep = message["jsep"] as? [String: Any],
              let jsepType = jsep["type"] as? String,
              jsepType == "offer",
              let sdpString = jsep["sdp"] as? String else {
            return
        }

        await handleOfferSDP(sdpString)
    }

    private func handleOfferSDP(_ sdpString: String) async {
        guard let peerConnection else { return }

        let sessionDescription = RTCSessionDescription(type: .offer, sdp: sdpString)
        do {
            try await peerConnection.setRemoteDescription(sessionDescription)
        } catch {
            return
        }

        await createAndSendAnswer(peerConnection: peerConnection)
    }

    private func createAndSendAnswer(peerConnection: RTCPeerConnection) async {
        do {
            let sessionDescription = try await peerConnection.answer(
                for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            )
            try await peerConnection.setLocalDescription(sessionDescription)
        } catch {
            return
        }

        guard let localDescription = peerConnection.localDescription,
              let sessionId = janusSessionId,
              let handleId = janusHandleId else {
            return
        }

        let startTransaction = makeJanusTransaction()
        try? await sendJanusMessage([
            "janus": "message",
            "body": ["request": "start"],
            "transaction": startTransaction,
            "session_id": sessionId,
            "handle_id": handleId,
            "jsep": [
                "type": "answer",
                "sdp": localDescription.sdp,
            ],
        ])
    }

    func disconnect() {
        janusKeepAliveTimer?.invalidate()
        janusKeepAliveTimer = nil
        janusSessionId = nil
        janusHandleId = nil

        let waiters = janusWaiters
        janusWaiters.removeAll()
        for (_, waiter) in waiters {
            waiter.resume(throwing: WebRTCError.signalingConnectionLost)
        }

        webSocketTask?.cancel()
        webSocketTask = nil

        peerConnection?.close()
        peerConnection = nil

        videoView = nil
        isConnected = false
        isConnecting = false
        hasEverConnectedToStream = false
        isStreamStalled = false
        lastDisconnectReason = nil
        videoSize = nil
    }
}

extension WebRTCManager: @preconcurrency RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCIceConnectionState) {
        Task { @MainActor in
            isConnected = (stateChanged == .connected || stateChanged == .completed)
            if isConnected {
                isConnecting = false
                hasEverConnectedToStream = true
                lastDisconnectReason = nil
            } else {
                if stateChanged == .disconnected {
                    lastDisconnectReason = "Video connection lost"
                } else if stateChanged == .failed {
                    lastDisconnectReason = "Video connection failed"
                } else if stateChanged == .closed {
                    lastDisconnectReason = "Video connection closed"
                }
                isConnecting = false
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCIceGatheringState) {
        Task { @MainActor in
            if stateChanged == .complete, let handleId = self.janusHandleId {
                try? await sendJanusTrickleCompleted(handleId: handleId)
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            if let handleId = self.janusHandleId {
                try? await sendJanusTrickleCandidate(candidate, handleId: handleId)
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        videoTrack = track
        if let videoView {
            track.add(videoView)
        }
        track.add(self)
    }
}

extension WebRTCManager: @preconcurrency RTCVideoRenderer {
    func renderFrame(_ frame: RTCVideoFrame?) {
        _ = frame
    }

    func setSize(_ size: CGSize) {
        Task { @MainActor in
            if size.width > 0, size.height > 0 {
                videoSize = size
            }
        }
    }
}

enum WebRTCError: Error {
    case factoryNotInitialized
    case invalidSignalingURL
    case signalingConnectionLost
}

#else

@MainActor
final class WebRTCManager: NSObject, ObservableObject {
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var hasEverConnectedToStream = false
    @Published var isStreamStalled = false
    @Published var lastDisconnectReason: String?
    @Published var videoSize: CGSize?

    func connect(to device: KVMDevice) async throws {
        _ = device
        isConnected = false
    }

    func reconnect(to device: KVMDevice) async {
        _ = device
        disconnect()
    }

    func disconnect() {
        isConnected = false
        isConnecting = false
        hasEverConnectedToStream = false
        isStreamStalled = false
        lastDisconnectReason = nil
        videoSize = nil
    }
}

#endif
