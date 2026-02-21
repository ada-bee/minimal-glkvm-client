import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var webRTCManager: WebRTCManager
    @EnvironmentObject var inputManager: InputManager
    @EnvironmentObject var kvmDeviceManager: KVMDeviceManager

    private let config = AppBuildConfig.current

    @State private var isConnected = false
    @State private var showingPasswordPrompt = false
    @State private var password = ""

    private var windowTitle: String {
        let state = isConnected ? "Connected" : "Disconnected"
        if let size = webRTCManager.videoSize {
            return "\(config.appName) - \(state) - \(Int(size.width))x\(Int(size.height))"
        }
        return "\(config.appName) - \(state)"
    }

    private let fallbackWindowSize = CGSize(width: 1920, height: 1080)

    var body: some View {
        VideoSurfaceView(
            onReconnect: {
                Task { await reconnect() }
            }
        )
        .background(WindowSizingSetter(videoSize: webRTCManager.videoSize, fallbackSize: fallbackWindowSize))
        .background(WindowChromeSetter())
        .background(WindowTitleSetter(title: windowTitle))
        .onAppear {
            Task {
                await connect(password: nil)
            }
        }
        .onReceive(kvmDeviceManager.$glkvmClient) { client in
            inputManager.setGLKVMClient(client)
        }
        .onReceive(kvmDeviceManager.$connectedDevice) { device in
            isConnected = (device != nil)
        }
        .sheet(isPresented: $showingPasswordPrompt) {
            PasswordPromptSheet(
                isPresented: $showingPasswordPrompt,
                password: $password,
                onCancel: {
                    password = ""
                },
                onConnect: {
                    let pwd = password.trimmingCharacters(in: .whitespacesAndNewlines)
                    password = ""
                    Task {
                        await connect(password: pwd.isEmpty ? nil : pwd)
                    }
                }
            )
        }
    }

    private func connect(password: String?) async {
        do {
            let device = try await kvmDeviceManager.connect(password: password)
            inputManager.setGLKVMClient(kvmDeviceManager.glkvmClient)
            inputManager.startFullInputCapture()

            if let client = kvmDeviceManager.glkvmClient {
                try? await client.setHidConnected(true)
            }

            try await webRTCManager.connect(to: device)
            isConnected = true
        } catch {
            if let kvmError = error as? KVMError, kvmError == .authenticationFailed {
                showingPasswordPrompt = true
            } else {
                isConnected = false
            }
        }
    }

    private func reconnect() async {
        await disconnectCurrent()
        await connect(password: nil)
    }

    private func disconnectCurrent() async {
        webRTCManager.disconnect()

        if let client = kvmDeviceManager.glkvmClient {
            try? await client.setHidConnected(false)
        }

        kvmDeviceManager.disconnect()
        inputManager.setGLKVMClient(nil)
        inputManager.stopFullInputCapture()
        isConnected = false
    }

}

private struct WindowChromeSetter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.toolbar = nil
    }
}

private struct WindowSizingSetter: NSViewRepresentable {
    let videoSize: CGSize?
    let fallbackSize: CGSize

    final class Coordinator {
        var lastAppliedContentSize: NSSize?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        let resolvedSize = resolvedWindowSize(for: videoSize)
        guard resolvedSize.width > 0,
              resolvedSize.height > 0 else {
            return
        }

        let contentSize = NSSize(width: resolvedSize.width, height: resolvedSize.height)
        if context.coordinator.lastAppliedContentSize != contentSize {
            window.setContentSize(contentSize)
            context.coordinator.lastAppliedContentSize = contentSize
        }

        if window.contentMinSize != contentSize {
            window.contentMinSize = contentSize
        }

        if window.contentMaxSize != contentSize {
            window.contentMaxSize = contentSize
        }

        if window.aspectRatio != contentSize {
            window.aspectRatio = contentSize
        }
    }

    private func resolvedWindowSize(for streamSize: CGSize?) -> CGSize {
        if let streamSize,
           streamSize.width > 0,
           streamSize.height > 0 {
            return streamSize
        }

        return fallbackSize
    }
}

private struct WindowTitleSetter: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        if window.title != title {
            window.title = title
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(WebRTCManager())
        .environmentObject(InputManager())
        .environmentObject(KVMDeviceManager())
}
