import Foundation
import Cocoa
import CoreGraphics
import SwiftUI

@MainActor
final class InputManager: ObservableObject {
    private var glkvmClient: GLKVMClient?
    private var glkvmWebSocketClient: GLKVMClient.WebSocketClient?
    private var keyEventMonitor: Any?

    private struct PendingAbsoluteMouseMove {
        let toX: Int
        let toY: Int
    }

    private var pendingMouseMove: PendingAbsoluteMouseMove?
    private var mouseMoveSenderTask: Task<Void, Never>?
    private static let mouseMoveSendIntervalNs: UInt64 = 8_333_333

    private var pendingCommandKeyCode: UInt16?
    private var activeCommandKeyCode: UInt16?
    private var commandKeySentToRemote: Bool = false

    @Published var isKeyboardCaptureEnabled = false
    @Published var isMouseCaptureEnabled = false

    func setup(with webRTCManager: WebRTCManager) {
        _ = webRTCManager
    }

    func setGLKVMClient(_ client: GLKVMClient?) {
        glkvmClient = client
        if client == nil {
            disconnectGLKVMWebSocket()
            return
        }

        Task { [weak self] in
            await self?.reconnectGLKVMWebSocketIfNeeded()
        }
    }

    func handleVideoMouseMove(pointInView: CGPoint, viewSize: CGSize, videoSize: CGSize?) {
        guard isMouseCaptureEnabled else { return }
        let normalized = normalizePointInViewToVideo(pointInView: pointInView, viewSize: viewSize, videoSize: videoSize)
        let (toX, toY) = glkvmAbsolutePoint(fromNormalized: normalized)
        pendingMouseMove = PendingAbsoluteMouseMove(toX: toX, toY: toY)
        if mouseMoveSenderTask == nil {
            startMouseMoveSender()
        }
    }

    private func startMouseMoveSender() {
        guard mouseMoveSenderTask == nil else { return }

        let sendIntervalNs = Self.mouseMoveSendIntervalNs

        mouseMoveSenderTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                let snapshot: (move: PendingAbsoluteMouseMove?, ws: GLKVMClient.WebSocketClient?) = await MainActor.run {
                    let event = self.pendingMouseMove
                    self.pendingMouseMove = nil
                    return (event, self.glkvmWebSocketClient)
                }

                guard let move = snapshot.move else {
                    await MainActor.run {
                        self.mouseMoveSenderTask = nil
                    }
                    return
                }

                if let ws = snapshot.ws {
                    try? await ws.sendHidMouseMove(toX: move.toX, toY: move.toY)
                }

                try? await Task.sleep(nanoseconds: sendIntervalNs)
            }
        }
    }

    private func stopMouseMoveSender() {
        pendingMouseMove = nil
        mouseMoveSenderTask?.cancel()
        mouseMoveSenderTask = nil
    }

    func handleVideoMouseButton(button: MouseButton, isDown: Bool, pointInView: CGPoint, viewSize: CGSize, videoSize: CGSize?) {
        guard isMouseCaptureEnabled else { return }
        let normalized = normalizePointInViewToVideo(pointInView: pointInView, viewSize: viewSize, videoSize: videoSize)
        let (toX, toY) = glkvmAbsolutePoint(fromNormalized: normalized)
        guard let buttonName = glkvmMouseButtonName(button), let ws = glkvmWebSocketClient else { return }

        Task {
            try? await ws.sendHidMouseMove(toX: toX, toY: toY)
            try? await ws.sendHidMouseButton(button: buttonName, state: isDown)
        }
    }

    func handleVideoMouseScroll(deltaX: CGFloat, deltaY: CGFloat) {
        guard isMouseCaptureEnabled else { return }
        guard let ws = glkvmWebSocketClient else { return }

        let dx = clampInt(Int(deltaX.rounded()), min: -127, max: 127)
        let dy = clampInt(Int(deltaY.rounded()), min: -127, max: 127)

        Task {
            try? await ws.sendHidMouseWheel(deltaX: dx, deltaY: dy)
        }
    }

    func disconnectGLKVMWebSocket() {
        stopMouseMoveSender()
        let ws = glkvmWebSocketClient
        glkvmWebSocketClient = nil
        Task {
            await ws?.disconnect()
        }
    }

    func startKeyboardCapture() {
        guard keyEventMonitor == nil else {
            isKeyboardCaptureEnabled = true
            return
        }

        isKeyboardCaptureEnabled = true

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handleKeyEvent(event)
            guard let self, self.isKeyboardCaptureEnabled else { return event }
            return nil
        }
    }

    func stopKeyboardCapture() {
        isKeyboardCaptureEnabled = false
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }

    func startMouseCapture() {
        isMouseCaptureEnabled = true
    }

    func stopMouseCapture() {
        isMouseCaptureEnabled = false
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard isKeyboardCaptureEnabled else { return }

        switch event.type {
        case .keyDown, .keyUp:
            let keyCode = event.keyCode
            let isKeyDown = event.type == .keyDown
            let modifiers = event.modifierFlags

            if isKeyDown, modifiers.contains(.command) {
                if let pending = pendingCommandKeyCode,
                   commandKeySentToRemote == false,
                   let ws = glkvmWebSocketClient,
                   let metaKey = glkvmKeyForMacKeyCode(pending),
                   let keyName = glkvmKeyForMacKeyCode(keyCode) {
                    activeCommandKeyCode = pending
                    pendingCommandKeyCode = nil
                    commandKeySentToRemote = true

                    Task {
                        try? await ws.sendHidKey(key: metaKey, state: true)
                        try? await ws.sendHidKey(key: keyName, state: true)
                    }
                    return
                }

                flushPendingCommandKeyIfNeeded(timestamp: event.timestamp, modifiers: modifiers)
            }

            sendKeyEvent(keyCode: keyCode, isKeyDown: isKeyDown)

        case .flagsChanged:
            let keyCode = event.keyCode
            guard let keyName = glkvmKeyForMacKeyCode(keyCode) else { return }

            let flags = event.modifierFlags
            let isDown: Bool

            switch keyName {
            case "ShiftLeft", "ShiftRight":
                isDown = flags.contains(.shift)
            case "ControlLeft", "ControlRight":
                isDown = flags.contains(.control)
            case "AltLeft", "AltRight":
                isDown = flags.contains(.option)
            case "MetaLeft", "MetaRight":
                isDown = flags.contains(.command)
                if isDown {
                    pendingCommandKeyCode = keyCode
                    activeCommandKeyCode = nil
                    commandKeySentToRemote = false
                    return
                }

                if commandKeySentToRemote {
                    sendKeyEvent(keyCode: activeCommandKeyCode ?? keyCode, isKeyDown: false)
                }

                clearPendingCommandKey()
                return
            case "CapsLock":
                isDown = flags.contains(.capsLock)
            default:
                return
            }

            sendKeyEvent(keyCode: keyCode, isKeyDown: isDown)

        default:
            break
        }
    }

    private func sendKeyEvent(keyCode: UInt16, isKeyDown: Bool) {
        guard let key = glkvmKeyForMacKeyCode(keyCode), let ws = glkvmWebSocketClient else { return }

        Task {
            try? await ws.sendHidKey(key: key, state: isKeyDown)
        }
    }

    private func clearPendingCommandKey() {
        pendingCommandKeyCode = nil
        activeCommandKeyCode = nil
        commandKeySentToRemote = false
    }

    private func flushPendingCommandKeyIfNeeded(timestamp: TimeInterval, modifiers: NSEvent.ModifierFlags) {
        _ = timestamp
        _ = modifiers
        guard let pendingCommandKeyCode, commandKeySentToRemote == false else { return }
        activeCommandKeyCode = pendingCommandKeyCode
        self.pendingCommandKeyCode = nil
        commandKeySentToRemote = true

        sendKeyEvent(keyCode: activeCommandKeyCode ?? pendingCommandKeyCode, isKeyDown: true)
    }

    deinit {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }

    private func reconnectGLKVMWebSocketIfNeeded() async {
        guard let client = glkvmClient else { return }

        if glkvmWebSocketClient == nil {
            let ws = try? client.makeWebSocketClient()
            glkvmWebSocketClient = ws
            await ws?.connect()
        }
    }

    private func glkvmAbsolutePoint(fromNormalized point: CGPoint) -> (Int, Int) {
        let clampedX = max(0, min(1, point.x))
        let clampedY = max(0, min(1, point.y))
        let maxAxis = 32767.0

        let signedX = (clampedX * 2.0 - 1.0) * maxAxis
        let signedY = (clampedY * 2.0 - 1.0) * maxAxis

        return (Int(signedX.rounded()), Int(signedY.rounded()))
    }

    func normalizePointInViewToVideo(pointInView: CGPoint, viewSize: CGSize, videoSize: CGSize?) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0 else {
            return .zero
        }

        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else {
            let clampedX = max(0, min(1, pointInView.x / viewSize.width))
            let clampedY = max(0, min(1, pointInView.y / viewSize.height))
            return CGPoint(x: clampedX, y: clampedY)
        }

        let viewAspect = viewSize.width / viewSize.height
        let videoAspect = videoSize.width / videoSize.height

        var contentRect = CGRect(origin: .zero, size: viewSize)

        if viewAspect > videoAspect {
            let contentWidth = viewSize.height * videoAspect
            let xOffset = (viewSize.width - contentWidth) / 2.0
            contentRect = CGRect(x: xOffset, y: 0, width: contentWidth, height: viewSize.height)
        } else {
            let contentHeight = viewSize.width / videoAspect
            let yOffset = (viewSize.height - contentHeight) / 2.0
            contentRect = CGRect(x: 0, y: yOffset, width: viewSize.width, height: contentHeight)
        }

        let clampedX = max(contentRect.minX, min(contentRect.maxX, pointInView.x))
        let clampedY = max(contentRect.minY, min(contentRect.maxY, pointInView.y))

        let normalizedX = (clampedX - contentRect.minX) / contentRect.width
        let normalizedY = (clampedY - contentRect.minY) / contentRect.height

        return CGPoint(x: max(0, min(1, normalizedX)), y: max(0, min(1, normalizedY)))
    }

    private func glkvmMouseButtonName(_ button: MouseButton) -> String? {
        switch button {
        case .left:
            return "left"
        case .right:
            return "right"
        case .middle:
            return "middle"
        }
    }

    private func glkvmKeyForMacKeyCode(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 0: return "KeyA"
        case 11: return "KeyB"
        case 8: return "KeyC"
        case 2: return "KeyD"
        case 14: return "KeyE"
        case 3: return "KeyF"
        case 5: return "KeyG"
        case 4: return "KeyH"
        case 34: return "KeyI"
        case 38: return "KeyJ"
        case 40: return "KeyK"
        case 37: return "KeyL"
        case 46: return "KeyM"
        case 45: return "KeyN"
        case 31: return "KeyO"
        case 35: return "KeyP"
        case 12: return "KeyQ"
        case 15: return "KeyR"
        case 1: return "KeyS"
        case 17: return "KeyT"
        case 32: return "KeyU"
        case 9: return "KeyV"
        case 13: return "KeyW"
        case 7: return "KeyX"
        case 16: return "KeyY"
        case 6: return "KeyZ"
        case 18: return "Digit1"
        case 19: return "Digit2"
        case 20: return "Digit3"
        case 21: return "Digit4"
        case 23: return "Digit5"
        case 22: return "Digit6"
        case 26: return "Digit7"
        case 28: return "Digit8"
        case 25: return "Digit9"
        case 29: return "Digit0"
        case 50: return "Backquote"
        case 27: return "Minus"
        case 24: return "Equal"
        case 33: return "BracketLeft"
        case 30: return "BracketRight"
        case 41: return "Semicolon"
        case 39: return "Quote"
        case 42: return "Backslash"
        case 43: return "Comma"
        case 47: return "Period"
        case 44: return "Slash"
        case 49: return "Space"
        case 48: return "Tab"
        case 36: return "Enter"
        case 51: return "Backspace"
        case 53: return "Escape"
        case 82: return "Numpad0"
        case 83: return "Numpad1"
        case 84: return "Numpad2"
        case 85: return "Numpad3"
        case 86: return "Numpad4"
        case 87: return "Numpad5"
        case 88: return "Numpad6"
        case 89: return "Numpad7"
        case 91: return "Numpad8"
        case 92: return "Numpad9"
        case 65: return "NumpadDecimal"
        case 67: return "NumpadMultiply"
        case 69: return "NumpadAdd"
        case 78: return "NumpadSubtract"
        case 75: return "NumpadDivide"
        case 76: return "NumpadEnter"
        case 81: return "NumpadEqual"
        case 114: return "Help"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "PageUp"
        case 121: return "PageDown"
        case 117: return "Delete"
        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"
        case 55: return "MetaLeft"
        case 54: return "MetaRight"
        case 56: return "ShiftLeft"
        case 60: return "ShiftRight"
        case 58: return "AltLeft"
        case 61: return "AltRight"
        case 59: return "ControlLeft"
        case 62: return "ControlRight"
        case 57: return "CapsLock"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 64: return "F17"
        default:
            return nil
        }
    }

    private func clampInt(_ value: Int, min: Int, max: Int) -> Int {
        if value < min { return min }
        if value > max { return max }
        return value
    }
}

enum MouseButton: Int, Codable {
    case left = 0
    case right = 1
    case middle = 2
}

extension InputManager {
    func startFullInputCapture() {
        startKeyboardCapture()
        startMouseCapture()
    }

    func stopFullInputCapture() {
        stopKeyboardCapture()
        stopMouseCapture()
    }
}
