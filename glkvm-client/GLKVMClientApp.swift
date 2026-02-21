import SwiftUI
import AppKit
#if canImport(WebRTC)
import WebRTC
#endif

@main
struct GLKVMClientApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.webRTCManager)
                .environmentObject(appDelegate.inputManager)
                .environmentObject(appDelegate.kvmDeviceManager)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let webRTCManager = WebRTCManager()
    let inputManager = InputManager()
    let kvmDeviceManager = KVMDeviceManager()
    private var notificationObservers: [NSObjectProtocol] = []
    private var chromeEnforcerTask: Task<Void, Never>?
    
    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        installWindowChromeObservers()
        startChromeEnforcerBurst()
    }

    private func installWindowChromeObservers() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeMainNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResizeNotification,
            NSWindow.didUpdateNotification,
        ]

        notificationObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                Task { @MainActor in
                    self?.applyMinimalChrome(to: window)
                }
            }
        }
    }

    private func startChromeEnforcerBurst() {
        chromeEnforcerTask?.cancel()
        chromeEnforcerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<180 {
                for window in NSApp.windows {
                    applyMinimalChrome(to: window)
                }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    @MainActor
    private func applyMinimalChrome(to window: NSWindow) {
        let cornerRadius: CGFloat = 12

        var mask = window.styleMask
        mask.remove([.titled, .closable, .miniaturizable])
        mask.remove(.resizable)
        mask.insert(.fullSizeContentView)
        window.styleMask = mask

        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = nil
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true

        if let frameView = window.contentView?.superview {
            frameView.wantsLayer = true
            frameView.layer?.cornerRadius = cornerRadius
            frameView.layer?.masksToBounds = true
        }

        if let contentView = window.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = cornerRadius
            contentView.layer?.masksToBounds = true
        }

        window.invalidateShadow()

        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        var controlsContainer: NSView?

        for type in buttonTypes {
            guard let button = window.standardWindowButton(type) else { continue }
            button.isHidden = true
            button.alphaValue = 0
            button.isEnabled = false
            controlsContainer = controlsContainer ?? button.superview
        }

        controlsContainer?.isHidden = true
        controlsContainer?.alphaValue = 0
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return .terminateNow
    }

    deinit {
        chromeEnforcerTask?.cancel()
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
