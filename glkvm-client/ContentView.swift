import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var webRTCManager: WebRTCManager
    @EnvironmentObject var inputManager: InputManager
    @EnvironmentObject var kvmDeviceManager: KVMDeviceManager

    @State private var isConnected = false
    @State private var showingPasswordPrompt = false
    @State private var password = ""

    private var windowTitle: String {
        let state = isConnected ? "Connected" : "Disconnected"
        if let size = webRTCManager.videoSize {
            return "GLKVM Client - \(state) - \(Int(size.width))x\(Int(size.height))"
        }
        return "GLKVM Client - \(state)"
    }

    var body: some View {
        VideoSurfaceView(
            onReconnect: {
                Task { await reconnect() }
            }
        )
        .background(WindowAspectRatioSetter(videoSize: webRTCManager.videoSize))
        .background(WindowChromeSetter())
        .background(WindowTitleSetter(title: windowTitle))
        .onAppear {
            inputManager.setup(with: webRTCManager)
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

private struct WindowAspectRatioSetter: NSViewRepresentable {
    let videoSize: CGSize?

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else { return }
        window.aspectRatio = NSSize(width: videoSize.width, height: videoSize.height)
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
