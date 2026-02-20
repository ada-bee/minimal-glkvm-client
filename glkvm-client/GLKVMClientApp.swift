import SwiftUI
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
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.automatic)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let webRTCManager = WebRTCManager()
    let inputManager = InputManager()
    let kvmDeviceManager = KVMDeviceManager()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return .terminateNow
    }
}
