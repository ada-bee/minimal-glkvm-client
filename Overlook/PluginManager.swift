import Foundation
import Combine
import SwiftUI

@MainActor
class PluginManager: ObservableObject {
    @Published var loadedPlugins: [OverlookPlugin] = []
    @Published var availablePlugins: [PluginInfo] = []
    @Published var isEnabled = true
    
    private var pluginRegistry: [String: OverlookPlugin] = [:]
    private var eventHandlers: [String: [String: PluginEventHandler]] = [:]
    
    init() {
        loadBuiltinPlugins()
        scanForExternalPlugins()
    }
    
    // MARK: - Plugin Loading
    
    private func loadBuiltinPlugins() {
        // Load built-in plugins
        let spatialPlugin = SpatialComputingPlugin()
        registerPlugin(spatialPlugin)
        
        let multiDevicePlugin = MultiDevicePlugin()
        registerPlugin(multiDevicePlugin)
        
        let analyticsPlugin = AnalyticsPlugin()
        registerPlugin(analyticsPlugin)
        
        let recordingPlugin = RecordingPlugin()
        registerPlugin(recordingPlugin)
    }
    
    private func scanForExternalPlugins() {
        // Scan for external plugins in Application Support directory
        let pluginDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Overlook")
            .appendingPathComponent("Plugins")
        
        guard let pluginDir = pluginDir,
              FileManager.default.fileExists(atPath: pluginDir.path) else { return }
        
        do {
            let pluginURLs = try FileManager.default.contentsOfDirectory(
                at: pluginDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            
            for pluginURL in pluginURLs {
                if pluginURL.pathExtension == "overlookplugin" {
                    loadExternalPlugin(at: pluginURL)
                }
            }
        } catch {
            print("Failed to scan plugins directory: \(error)")
        }
    }
    
    private func loadExternalPlugin(at url: URL) {
        // Load external plugin bundle
        guard let bundle = Bundle(url: url) else { return }
        
        bundle.load()
        
        // Look for plugin class
        if let pluginClass = bundle.principalClass as? OverlookPlugin.Type {
            let plugin = pluginClass.init()
            registerPlugin(plugin)
        }
    }
    
    func registerPlugin(_ plugin: OverlookPlugin) {
        pluginRegistry[plugin.id] = plugin
        loadedPlugins.append(plugin)
        
        // Register event handlers
        for eventType in plugin.supportedEvents {
            if eventHandlers[eventType] == nil {
                eventHandlers[eventType] = [:]
            }
            eventHandlers[eventType]?[plugin.id] = plugin.handleEvent
        }
        
        // Initialize plugin
        plugin.initialize()
        
        print("Plugin registered: \(plugin.name) v\(plugin.version)")
    }
    
    func unregisterPlugin(_ plugin: OverlookPlugin) {
        plugin.cleanup()
        pluginRegistry.removeValue(forKey: plugin.id)
        loadedPlugins.removeAll { $0.id == plugin.id }
        
        // Remove event handlers
        for eventType in plugin.supportedEvents {
            eventHandlers[eventType]?.removeValue(forKey: plugin.id)
        }
        
        print("Plugin unregistered: \(plugin.name)")
    }
    
    // MARK: - Event System
    
    func emitEvent(_ event: OverlookEvent) {
        guard isEnabled else { return }
        
        let handlers = (eventHandlers[event.type]?.values).map(Array.init) ?? []
        
        for handler in handlers {
            Task {
                await handler(event)
            }
        }
    }
    
    func emitEvent(type: String, data: [String: JSONValue]) {
        let event = OverlookEvent(type: type, data: data, timestamp: Date())
        emitEvent(event)
    }
    
    // MARK: - Plugin Management
    
    func getPlugin(id: String) -> OverlookPlugin? {
        return pluginRegistry[id]
    }
    
    func getPluginUI(for pluginId: String) -> AnyView? {
        guard let plugin = pluginRegistry[pluginId],
              let uiView = plugin.getConfigurationUI() else { return nil }
        
        return AnyView(uiView)
    }
    
    func enablePlugin(_ plugin: OverlookPlugin) {
        plugin.isEnabled = true
        plugin.enable()
    }
    
    func disablePlugin(_ plugin: OverlookPlugin) {
        plugin.isEnabled = false
        plugin.disable()
    }
    
    func configurePlugin(_ plugin: OverlookPlugin, with config: [String: JSONValue]) {
        plugin.configure(with: config)
    }
    
    deinit {
        // No-op. Cleanup should be driven explicitly from a MainActor context.
    }
}

// MARK: - Plugin Protocol

protocol OverlookPlugin: AnyObject {
    init()
    var id: String { get }
    var name: String { get }
    var version: String { get }
    var description: String { get }
    var author: String { get }
    var isEnabled: Bool { get set }
    var supportedEvents: [String] { get }
    
    func initialize()
    func enable()
    func disable()
    func cleanup()
    func configure(with config: [String: JSONValue])
    func handleEvent(_ event: OverlookEvent) async
    func getConfigurationUI() -> AnyView?
}

// MARK: - Event System

struct OverlookEvent {
    let type: String
    let data: [String: JSONValue]
    let timestamp: Date
}

typealias PluginEventHandler = (OverlookEvent) async -> Void

// MARK: - Built-in Plugins

final class SpatialComputingPlugin: OverlookPlugin {
    let id = "com.overlook.plugins.spatial"
    let name = "Spatial Computing"
    let version = "1.0.0"
    let description = "Adds spatial computing features for visionOS and AR/VR support"
    let author = "Overlook Team"
    var isEnabled = true
    let supportedEvents = ["device.connected", "device.disconnected", "video.frame.received"]
    
    func initialize() {
        print("Spatial Computing Plugin initialized")
    }
    
    func enable() {
        print("Spatial Computing Plugin enabled")
    }
    
    func disable() {
        print("Spatial Computing Plugin disabled")
    }
    
    func cleanup() {
        print("Spatial Computing Plugin cleaned up")
    }
    
    func configure(with config: [String: JSONValue]) {
        // Handle spatial computing configuration
    }
    
    func handleEvent(_ event: OverlookEvent) async {
        switch event.type {
        case "video.frame.received":
            // Process video frame for spatial computing
            await processFrameForSpatial(event.data)
        default:
            break
        }
    }
    
    private func processFrameForSpatial(_ data: [String: JSONValue]) async {
        // Implement spatial computing features
        // - 3D reconstruction
        // - Hand tracking
        // - Eye tracking
        // - Spatial audio
    }
    
    func getConfigurationUI() -> AnyView? {
        return AnyView(SpatialComputingConfigView())
    }
}

struct SpatialComputingConfigView: View {
    @State private var enable3DReconstruction = true
    @State private var enableHandTracking = true
    @State private var enableEyeTracking = false
    @State private var enableSpatialAudio = true
    
    var body: some View {
        Form {
            Text("Spatial Computing Configuration")
                .font(.headline)
            
            Toggle("3D Reconstruction", isOn: $enable3DReconstruction)
            Toggle("Hand Tracking", isOn: $enableHandTracking)
            Toggle("Eye Tracking", isOn: $enableEyeTracking)
            Toggle("Spatial Audio", isOn: $enableSpatialAudio)
        }
        .padding()
    }
}

final class MultiDevicePlugin: OverlookPlugin {
    let id = "com.overlook.plugins.multidevice"
    let name = "Multi-Device Support"
    let version = "1.0.0"
    let description = "Enables simultaneous connection to multiple KVM devices"
    let author = "Overlook Team"
    var isEnabled = true
    let supportedEvents = ["device.discovered", "device.connected", "device.disconnected"]
    
    private var connectedDevices: [KVMDevice] = []
    
    func initialize() {
        print("Multi-Device Plugin initialized")
    }
    
    func enable() {
        print("Multi-Device Plugin enabled")
    }
    
    func disable() {
        print("Multi-Device Plugin disabled")
    }
    
    func cleanup() {
        connectedDevices.removeAll()
        print("Multi-Device Plugin cleaned up")
    }
    
    func configure(with config: [String: JSONValue]) {
        // Handle multi-device configuration
    }
    
    func handleEvent(_ event: OverlookEvent) async {
        switch event.type {
        case "device.connected":
            await updateDeviceLayout()
        case "device.disconnected":
            await updateDeviceLayout()
        default:
            break
        }
    }
    
    private func updateDeviceLayout() async {
        // Update UI layout for multiple devices
        // Could be grid view, tabs, or picture-in-picture
    }
    
    func getConfigurationUI() -> AnyView? {
        return AnyView(MultiDeviceConfigView())
    }
}

struct MultiDeviceConfigView: View {
    @State private var layoutMode = "grid"
    @State private var maxDevices = 4
    @State private var enablePip = true
    
    var body: some View {
        Form {
            Text("Multi-Device Configuration")
                .font(.headline)
            
            Picker("Layout Mode", selection: $layoutMode) {
                Text("Grid").tag("grid")
                Text("Tabs").tag("tabs")
                Text("Picture-in-Picture").tag("pip")
            }
            
            Stepper("Max Devices: \(maxDevices)", value: $maxDevices, in: 2...9)
            
            Toggle("Enable Picture-in-Picture", isOn: $enablePip)
        }
        .padding()
    }
}

final class AnalyticsPlugin: OverlookPlugin {
    let id = "com.overlook.plugins.analytics"
    let name = "Analytics & Telemetry"
    let version = "1.0.0"
    let description = "Collects usage analytics and performance metrics"
    let author = "Overlook Team"
    var isEnabled = true
    let supportedEvents = ["app.launched", "device.connected", "device.disconnected", "performance.metric"]
    
    func initialize() {
        print("Analytics Plugin initialized")
    }
    
    func enable() {
        print("Analytics Plugin enabled")
    }
    
    func disable() {
        print("Analytics Plugin disabled")
    }
    
    func cleanup() {
        print("Analytics Plugin cleaned up")
    }
    
    func configure(with config: [String: JSONValue]) {
        // Handle analytics configuration
    }
    
    func handleEvent(_ event: OverlookEvent) async {
        // Collect analytics data
        await collectAnalytics(event)
    }
    
    private func collectAnalytics(_ event: OverlookEvent) async {
        // Implement analytics collection
        // - Usage patterns
        // - Performance metrics
        // - Error tracking
        // - Feature usage
    }
    
    func getConfigurationUI() -> AnyView? {
        return AnyView(AnalyticsConfigView())
    }
}

struct AnalyticsConfigView: View {
    @State private var enableUsageTracking = true
    @State private var enablePerformanceTracking = true
    @State private var enableErrorTracking = true
    @State private var dataRetentionDays = 30
    
    var body: some View {
        Form {
            Text("Analytics Configuration")
                .font(.headline)
            
            Toggle("Usage Tracking", isOn: $enableUsageTracking)
            Toggle("Performance Tracking", isOn: $enablePerformanceTracking)
            Toggle("Error Tracking", isOn: $enableErrorTracking)
            
            Stepper("Data Retention: \(dataRetentionDays) days", value: $dataRetentionDays, in: 7...365)
        }
        .padding()
    }
}

final class RecordingPlugin: OverlookPlugin {
    let id = "com.overlook.plugins.recording"
    let name = "Session Recording"
    let version = "1.0.0"
    let description = "Records remote sessions for playback and analysis"
    let author = "Overlook Team"
    var isEnabled = true
    let supportedEvents = ["device.connected", "video.frame.received", "input.event", "device.disconnected"]
    
    private var isRecording = false
    private var recordingData: [OverlookEvent] = []
    
    func initialize() {
        print("Recording Plugin initialized")
    }
    
    func enable() {
        print("Recording Plugin enabled")
    }
    
    func disable() {
        print("Recording Plugin disabled")
    }
    
    func cleanup() {
        stopRecording()
        recordingData.removeAll()
        print("Recording Plugin cleaned up")
    }
    
    func configure(with config: [String: JSONValue]) {
        // Handle recording configuration
    }
    
    func handleEvent(_ event: OverlookEvent) async {
        if isRecording {
            recordingData.append(event)
        }
    }
    
    func startRecording() {
        isRecording = true
        recordingData.removeAll()
    }
    
    func stopRecording() {
        isRecording = false
        // Save recording data
    }
    
    func getConfigurationUI() -> AnyView? {
        return AnyView(RecordingConfigView())
    }
}

struct RecordingConfigView: View {
    @State private var autoRecord = false
    @State private var recordVideo = true
    @State private var recordInput = true
    @State private var maxRecordingDuration = 3600 // 1 hour
    
    var body: some View {
        Form {
            Text("Recording Configuration")
                .font(.headline)
            
            Toggle("Auto-record sessions", isOn: $autoRecord)
            Toggle("Record video", isOn: $recordVideo)
            Toggle("Record input events", isOn: $recordInput)
            
            Stepper("Max Duration: \(maxRecordingDuration / 60) min", value: $maxRecordingDuration, in: 300...7200, step: 300)
        }
        .padding()
    }
}

// MARK: - Plugin Info

struct PluginInfo: Identifiable, Codable {
    let id: String
    let name: String
    let version: String
    let description: String
    let author: String
    let url: URL?
    let isBuiltIn: Bool
    let dependencies: [String]
    
    var displayVersion: String {
        return "v\(version)"
    }
}

// MARK: - Plugin Architecture Extensions

extension PluginManager {
    // Plugin discovery and installation
    func installPlugin(from url: URL) async throws {
        // Download and install plugin
        let pluginData = try Data(contentsOf: url)
        
        // Verify plugin signature
        try await verifyPluginSignature(pluginData)
        
        // Extract plugin to Application Support
        let pluginDir = getPluginDirectory()
        let pluginURL = pluginDir.appendingPathComponent(url.lastPathComponent)
        
        try pluginData.write(to: pluginURL)
        
        // Load the plugin
        loadExternalPlugin(at: pluginURL)
    }
    
    private func verifyPluginSignature(_ data: Data) async throws {
        // Implement plugin signature verification
        // This would involve cryptographic verification
    }
    
    private func getPluginDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let pluginDir = appSupport.appendingPathComponent("Overlook").appendingPathComponent("Plugins")
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        
        return pluginDir
    }
    
    // Plugin marketplace integration
    func fetchAvailablePlugins() async throws -> [PluginInfo] {
        // Fetch available plugins from marketplace
        let marketplaceURL = URL(string: "https://api.overlook.app/plugins")!
        
        let (data, _) = try await URLSession.shared.data(from: marketplaceURL)
        return try JSONDecoder().decode([PluginInfo].self, from: data)
    }
    
    func updatePlugin(_ plugin: OverlookPlugin) async throws {
        // Update plugin to latest version
    }
    
    func uninstallPlugin(_ plugin: OverlookPlugin) throws {
        // Uninstall plugin
        unregisterPlugin(plugin)
        
        // Remove plugin files
        let pluginDir = getPluginDirectory()
        let pluginURL = pluginDir.appendingPathComponent("\(plugin.id).overlookplugin")
        
        try? FileManager.default.removeItem(at: pluginURL)
    }
}
