import Foundation
import Network
import Combine
import CoreGraphics

@MainActor
class HardwareControlManager: ObservableObject {
    @Published var virtualMediaMounted = false
    @Published var powerState: PowerState = .unknown
    @Published var availableMedia: [VirtualMedia] = []
    @Published var isTransferring = false
    @Published var transferProgress: Double = 0.0
    
    private var connectedDevice: KVMDevice?
    private var networkConnection: NWConnection?
    
    func setup(with device: KVMDevice) {
        connectedDevice = device
        setupNetworkConnection()
    }
    
    private func setupNetworkConnection() {
        guard let device = connectedDevice else { return }
        
        networkConnection = NWConnection(
            host: NWEndpoint.Host(device.host),
            port: NWEndpoint.Port(rawValue: UInt16(device.hardwareControlPort))!,
            using: .tcp
        )
        
        networkConnection?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.queryPowerState()
                    self?.queryVirtualMedia()
                case .failed, .cancelled:
                    self?.networkConnection = nil
                default:
                    break
                }
            }
        }
        
        networkConnection?.start(queue: DispatchQueue(label: "com.overlook.hardware"))
    }
    
    // MARK: - Virtual Media Management
    
    func mountVirtualMedia(_ media: VirtualMedia) async throws {
        guard let connection = networkConnection else {
            throw HardwareControlError.notConnected
        }
        
        isTransferring = true
        transferProgress = 0.0
        defer {
            isTransferring = false
            transferProgress = 0.0
        }
        
        do {
            // Start media transfer
            try await startMediaTransfer(media, connection: connection)
            
            // Mount the media
            try await sendMountCommand(media, connection: connection)
            
            virtualMediaMounted = true
            
        } catch {
            throw HardwareControlError.mediaMountFailed(error)
        }
    }
    
    private func startMediaTransfer(_ media: VirtualMedia, connection: NWConnection) async throws {
        let transferCommand = VirtualMediaCommand(
            type: .startTransfer,
            mediaType: media.type,
            fileName: media.fileName,
            fileSize: media.fileSize,
            imageData: media.imageData
        )
        
        let commandData = try JSONEncoder().encode(transferCommand)
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: commandData, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    private func sendMountCommand(_ media: VirtualMedia, connection: NWConnection) async throws {
        let mountCommand = VirtualMediaCommand(
            type: .mount,
            mediaType: media.type,
            fileName: media.fileName,
            fileSize: media.fileSize,
            imageData: nil
        )
        
        let commandData = try JSONEncoder().encode(mountCommand)
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: commandData, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    func unmountVirtualMedia() async throws {
        guard let connection = networkConnection else {
            throw HardwareControlError.notConnected
        }
        
        let unmountCommand = VirtualMediaCommand(
            type: .unmount,
            mediaType: .unknown,
            fileName: "",
            fileSize: 0,
            imageData: nil
        )
        
        let commandData = try JSONEncoder().encode(unmountCommand)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: commandData, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    Task { @MainActor in
                        self.virtualMediaMounted = false
                    }
                    continuation.resume()
                }
            })
        }
    }
    
    private func queryVirtualMedia() {
        guard let connection = networkConnection else { return }
        
        let queryCommand = VirtualMediaCommand(
            type: .query,
            mediaType: .unknown,
            fileName: "",
            fileSize: 0,
            imageData: nil
        )
        
        do {
            let commandData = try JSONEncoder().encode(queryCommand)
            connection.send(content: commandData, completion: .contentProcessed { _ in })
        } catch {
            print("Failed to query virtual media: \(error)")
        }
    }
    
    func createVirtualMedia(from url: URL, type: VirtualMediaType) async throws -> VirtualMedia {
        let imageData = try Data(contentsOf: url)
        let fileName = url.lastPathComponent
        
        return VirtualMedia(
            id: UUID().uuidString,
            name: fileName,
            type: type,
            fileName: fileName,
            fileSize: imageData.count,
            imageData: imageData,
            url: url
        )
    }
    
    // MARK: - ATX Power Management
    
    func powerOn() async throws {
        try await sendPowerCommand(.powerOn)
    }
    
    func powerOff() async throws {
        try await sendPowerCommand(.powerOff)
    }
    
    func powerCycle() async throws {
        try await sendPowerCommand(.powerCycle)
    }
    
    func reset() async throws {
        try await sendPowerCommand(.reset)
    }
    
    func sleep() async throws {
        try await sendPowerCommand(.sleep)
    }
    
    func wake() async throws {
        try await sendPowerCommand(.wake)
    }

    private func sendPowerCommand(_ command: PowerCommand.PowerCommandType) async throws {
        guard let connection = networkConnection else {
            throw HardwareControlError.notConnected
        }

        let powerCommand = PowerCommand(type: command)
        
        let powerCommandData = try JSONEncoder().encode(powerCommand)
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: powerCommandData, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    // Query power state after command
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.queryPowerState()
                    }
                    continuation.resume()
                }
            })
        }
    }
    
    private func queryPowerState() {
        guard let connection = networkConnection else { return }
        
        let queryCommand = PowerCommand(type: .query)
        
        do {
            let commandData = try JSONEncoder().encode(queryCommand)
            connection.send(content: commandData, completion: .contentProcessed { _ in })
        } catch {
            print("Failed to query power state: \(error)")
        }
    }
    
    // MARK: - Hardware Features
    
    func enableHardwareAcceleration(_ enabled: Bool) async throws {
        let command = HardwareFeatureCommand(
            type: .hardwareAcceleration,
            enabled: enabled
        )
        
        try await sendHardwareCommand(command)
    }
    
    func setVideoQuality(_ quality: VideoQuality) async throws {
        let command = HardwareFeatureCommand(
            type: .videoQuality,
            quality: quality
        )
        
        try await sendHardwareCommand(command)
    }
    
    func enableAudioStreaming(_ enabled: Bool) async throws {
        let command = HardwareFeatureCommand(
            type: .audioStreaming,
            enabled: enabled
        )
        
        try await sendHardwareCommand(command)
    }
    
    private func sendHardwareCommand(_ command: HardwareFeatureCommand) async throws {
        guard let connection = networkConnection else {
            throw HardwareControlError.notConnected
        }
        
        let commandData = try JSONEncoder().encode(command)
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: commandData, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    func disconnect() {
        networkConnection?.cancel()
        networkConnection = nil
        connectedDevice = nil
        virtualMediaMounted = false
        powerState = .unknown
    }
}

// MARK: - Supporting Types
struct VirtualMedia: Identifiable, Codable {
    let id: String
    let name: String
    let type: VirtualMediaType
    let fileName: String
    let fileSize: Int
    let imageData: Data?
    let url: URL?
    
    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }
}

enum VirtualMediaType: String, Codable, CaseIterable {
    case cd = "cd"
    case dvd = "dvd"
    case usb = "usb"
    case floppy = "floppy"
    case iso = "iso"
    case unknown = "unknown"
    
    var displayName: String {
        switch self {
        case .cd:
            return "CD-ROM"
        case .dvd:
            return "DVD"
        case .usb:
            return "USB Drive"
        case .floppy:
            return "Floppy Disk"
        case .iso:
            return "ISO Image"
        case .unknown:
            return "Unknown"
        }
    }
}

struct VirtualMediaCommand: Codable {
    let type: VirtualMediaCommandType
    let mediaType: VirtualMediaType
    let fileName: String
    let fileSize: Int
    let imageData: Data?
    
    enum VirtualMediaCommandType: String, Codable {
        case mount = "mount"
        case unmount = "unmount"
        case startTransfer = "start_transfer"
        case query = "query"
    }
}

enum PowerState: String, Codable, CaseIterable {
    case on = "on"
    case off = "off"
    case sleeping = "sleeping"
    case unknown = "unknown"
    
    var displayName: String {
        switch self {
        case .on:
            return "Powered On"
        case .off:
            return "Powered Off"
        case .sleeping:
            return "Sleeping"
        case .unknown:
            return "Unknown"
        }
    }
}

struct PowerCommand: Codable {
    let type: PowerCommandType
    let timestamp: TimeInterval
    
    init(type: PowerCommandType) {
        self.type = type
        self.timestamp = Date().timeIntervalSince1970
    }
    
    enum PowerCommandType: String, Codable {
        case powerOn = "power_on"
        case powerOff = "power_off"
        case powerCycle = "power_cycle"
        case reset = "reset"
        case sleep = "sleep"
        case wake = "wake"
        case query = "query"
    }
}

struct HardwareFeatureCommand: Codable {
    let type: HardwareFeatureType
    let enabled: Bool?
    let quality: VideoQuality?

    init(type: HardwareFeatureType, enabled: Bool? = nil, quality: VideoQuality? = nil) {
        self.type = type
        self.enabled = enabled
        self.quality = quality
    }
    
    enum HardwareFeatureType: String, Codable {
        case hardwareAcceleration = "hardware_acceleration"
        case videoQuality = "video_quality"
        case audioStreaming = "audio_streaming"
        case ocrEnhancement = "ocr_enhancement"
    }
}

enum VideoQuality: String, Codable, CaseIterable {
    case low = "low"
    case medium = "medium"
    case high = "high"
    case ultra = "ultra"
    
    var displayName: String {
        switch self {
        case .low:
            return "Low (480p)"
        case .medium:
            return "Medium (720p)"
        case .high:
            return "High (1080p)"
        case .ultra:
            return "Ultra (4K)"
        }
    }
    
    var resolution: CGSize {
        switch self {
        case .low:
            return CGSize(width: 640, height: 480)
        case .medium:
            return CGSize(width: 1280, height: 720)
        case .high:
            return CGSize(width: 1920, height: 1080)
        case .ultra:
            return CGSize(width: 3840, height: 2160)
        }
    }
}

enum HardwareControlError: Error, LocalizedError {
    case notConnected
    case mediaMountFailed(Error)
    case powerCommandFailed
    case hardwareFeatureNotSupported
    case transferFailed
    
    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to KVM device"
        case .mediaMountFailed(let error):
            return "Failed to mount virtual media: \(error.localizedDescription)"
        case .powerCommandFailed:
            return "Failed to execute power command"
        case .hardwareFeatureNotSupported:
            return "Hardware feature not supported by device"
        case .transferFailed:
            return "File transfer failed"
        }
    }
}

// MARK: - KVM Device Extension
extension KVMDevice {
    var hardwareControlPort: Int {
        switch type {
        case .glinetComet:
            return 8444 // Hardware control port for GL.iNet Comet
        case .generic:
            return port + 1 // Assume hardware control is on next port
        case .tailscale:
            return port + 1
        case .custom:
            return port + 1
        }
    }
    
    var supportsVirtualMedia: Bool {
        return capabilities.contains(.virtualMedia)
    }
    
    var supportsPowerManagement: Bool {
        return capabilities.contains(.powerManagement)
    }
}
