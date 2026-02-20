import Foundation
import Network
import Combine

@MainActor
final class KVMDeviceManager: NSObject, ObservableObject {
    @Published var availableDevices: [KVMDevice] = []
    @Published var connectedDevice: KVMDevice?
    @Published var glkvmClient: GLKVMClient?
    
    private static let savedDevicesKey = "glkvm-client.saved_devices.v1"

    private struct PersistedDevice: Codable, Hashable {
        let host: String
        let port: Int
        let name: String
        let type: KVMDeviceType
        let authToken: String
        let capabilities: Set<KVMCapability>
    }
    
    override init() {
        super.init()
        loadPersistedDevices()
    }
    
    private func removeDuplicates(from devices: [KVMDevice]) -> [KVMDevice] {
        var uniqueDevices: [KVMDevice] = []
        var seenHosts: Set<String> = []
        
        for device in devices {
            let hostKey = "\(device.host):\(device.port)"
            if !seenHosts.contains(hostKey) {
                seenHosts.insert(hostKey)
                uniqueDevices.append(device)
            }
        }
        
        return uniqueDevices
    }
    
    @discardableResult
    func addManualDevice(host: String, port: Int, type: KVMDeviceType, authToken: String = "") -> KVMDevice {
        let device = KVMDevice(
            id: "manual-\(UUID().uuidString)",
            name: "Manual KVM @ \(host):\(port)",
            host: host,
            port: port,
            type: type,
            authToken: authToken,
            capabilities: [.videoStreaming, .keyboardInput, .mouseInput]
        )
        
        availableDevices.append(device)
        return device
    }
    
    func removeDevice(_ device: KVMDevice) {
        availableDevices.removeAll { $0.id == device.id }
        
        if connectedDevice?.id == device.id {
            connectedDevice = nil
        }
    }

    func forgetDevice(_ device: KVMDevice) {
        let host = device.host
        let port = device.port

        var current = readPersistedDevices()
        current.removeAll { $0.host == host && $0.port == port }
        writePersistedDevices(current)

        availableDevices.removeAll { $0.host == host && $0.port == port }
        if connectedDevice?.host == host, connectedDevice?.port == port {
            connectedDevice = nil
            glkvmClient = nil
        }
    }
    
    @discardableResult
    func connectToDevice(_ device: KVMDevice, authToken: String? = nil, password: String? = nil, user: String = "admin") async throws -> KVMDevice {
        // Validate device connection
        let isValid = try await validateDeviceConnection(device)
        guard isValid else {
            throw KVMError.connectionFailed
        }
        
        // Update device auth token if provided
        var finalDevice: KVMDevice
        if let token = authToken {
            var updatedDevice = device
            updatedDevice.authToken = token

            // Update in available devices
            if let index = availableDevices.firstIndex(where: { $0.id == device.id }) {
                availableDevices[index] = updatedDevice
            }

            finalDevice = updatedDevice
        } else {
            finalDevice = device
        }

        guard let client = try? GLKVMClient(device: finalDevice, allowInsecureTLS: true) else {
            throw KVMError.connectionFailed
        }

        do {
            try await client.authCheck()
        } catch {
            if let password, !password.isEmpty {
                let token = try await client.authLogin(user: user, password: password)
                client.authToken = token

                var updated = finalDevice
                updated.authToken = token
                if let index = availableDevices.firstIndex(where: { $0.id == updated.id }) {
                    availableDevices[index] = updated
                }
                finalDevice = updated
            } else {
                throw KVMError.authenticationFailed
            }
        }

        let persisted = persistDevice(finalDevice)
        connectedDevice = persisted
        glkvmClient = client
        return persisted
    }

    private func persistDevice(_ device: KVMDevice) -> KVMDevice {
        let record = PersistedDevice(
            host: device.host,
            port: device.port,
            name: device.name,
            type: device.type,
            authToken: device.authToken,
            capabilities: device.capabilities
        )

        var current = readPersistedDevices()
        if let index = current.firstIndex(where: { $0.host == device.host && $0.port == device.port }) {
            current[index] = record
        } else {
            current.append(record)
        }
        writePersistedDevices(current)

        var saved = device
        saved.id = savedDeviceId(host: device.host, port: device.port)

        availableDevices.removeAll { $0.host == device.host && $0.port == device.port }
        availableDevices.append(saved)
        availableDevices = removeDuplicates(from: availableDevices).sorted { $0.name < $1.name }
        return saved
    }

    private func loadPersistedDevices() {
        let records = readPersistedDevices()
        guard !records.isEmpty else { return }

        let devices: [KVMDevice] = records.map { record in
            KVMDevice(
                id: savedDeviceId(host: record.host, port: record.port),
                name: record.name,
                host: record.host,
                port: record.port,
                type: record.type,
                authToken: record.authToken,
                capabilities: record.capabilities
            )
        }
        availableDevices = removeDuplicates(from: devices).sorted { $0.name < $1.name }
    }

    private func savedDeviceId(host: String, port: Int) -> String {
        let safeHost = host.replacingOccurrences(of: ":", with: "_")
        return "saved-\(safeHost)-\(port)"
    }

    private func readPersistedDevices() -> [PersistedDevice] {
        guard let data = UserDefaults.standard.data(forKey: Self.savedDevicesKey) else { return [] }
        return (try? JSONDecoder().decode([PersistedDevice].self, from: data)) ?? []
    }

    private func writePersistedDevices(_ devices: [PersistedDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: Self.savedDevicesKey)
    }
    
    private func validateDeviceConnection(_ device: KVMDevice) async throws -> Bool {
        guard let port = NWEndpoint.Port(rawValue: UInt16(device.port)) else {
            return false
        }

        final class Flag {
            var value: Bool = false
        }

        let queue = DispatchQueue(label: "com.glkvm-client.validate")
        let connection = NWConnection(host: NWEndpoint.Host(device.host), port: port, using: .tcp)

        return await withCheckedContinuation { continuation in
            let finished = Flag()

            let timeoutWorkItem = DispatchWorkItem {
                if finished.value { return }
                finished.value = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: false)
            }

            queue.asyncAfter(deadline: .now() + 5, execute: timeoutWorkItem)

            connection.stateUpdateHandler = { (state: NWConnection.State) in
                switch state {
                case .ready:
                    if finished.value { return }
                    finished.value = true
                    timeoutWorkItem.cancel()
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    if finished.value { return }
                    finished.value = true
                    timeoutWorkItem.cancel()
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }
    
    func disconnectFromDevice() {
        connectedDevice = nil
        glkvmClient = nil
    }
    
}

// MARK: - KVM Device Model
struct KVMDevice: Identifiable, Codable {
    var id: String
    var name: String
    let host: String
    let port: Int
    var type: KVMDeviceType
    var authToken: String
    let capabilities: Set<KVMCapability>
    
    var connectionString: String {
        return "\(host):\(port)"
    }
    
    var webRTCURL: String {
        return "wss://\(host):\(port)/janus/ws"
    }
}

extension KVMDevice: Hashable {
    static func == (lhs: KVMDevice, rhs: KVMDevice) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum KVMDeviceType: String, Codable, CaseIterable {
    case glinetComet = "glinet_comet"
    case generic = "generic"
    case custom = "custom"
    
    var displayName: String {
        switch self {
        case .glinetComet:
            return "GL.iNet Comet"
        case .generic:
            return "Generic KVM"
        case .custom:
            return "Custom KVM"
        }
    }
}

enum KVMCapability: String, Codable, CaseIterable {
    case videoStreaming = "video_streaming"
    case keyboardInput = "keyboard_input"
    case mouseInput = "mouse_input"
    case virtualMedia = "virtual_media"
    case powerManagement = "power_management"
    
    var displayName: String {
        switch self {
        case .videoStreaming:
            return "Video Streaming"
        case .keyboardInput:
            return "Keyboard Input"
        case .mouseInput:
            return "Mouse Input"
        case .virtualMedia:
            return "Virtual Media"
        case .powerManagement:
            return "Power Management"
        }
    }
}

enum KVMError: Error, LocalizedError {
    case deviceNotFound
    case connectionFailed
    case authenticationFailed
    case unsupportedCapability
    case networkUnavailable
    
    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "KVM device not found"
        case .connectionFailed:
            return "Failed to connect to KVM device"
        case .authenticationFailed:
            return "Authentication failed"
        case .unsupportedCapability:
            return "Device does not support this capability"
        case .networkUnavailable:
            return "Network is not available"
        }
    }
}
