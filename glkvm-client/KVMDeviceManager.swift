import Foundation
import Combine

struct KVMDevice: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    let host: String
    let port: Int
    var authToken: String

    var webRTCURL: String {
        "wss://\(host):\(port)/janus/ws"
    }
}

enum KVMError: Error, LocalizedError {
    case connectionFailed
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Failed to connect to KVM device"
        case .authenticationFailed:
            return "Authentication failed"
        }
    }
}

@MainActor
final class KVMDeviceManager: ObservableObject {
    @Published private(set) var connectedDevice: KVMDevice?
    @Published private(set) var glkvmClient: GLKVMClient?

    private let config = AppBuildConfig.current
    private static let savedTokenKey = "glkvm-client.static-device.auth-token.v1"

    private var staticDevice: KVMDevice {
        KVMDevice(
            id: "static-lan-device",
            name: config.appName,
            host: config.host,
            port: config.port,
            authToken: ""
        )
    }

    @discardableResult
    func connect(password: String? = nil, user: String = "admin") async throws -> KVMDevice {
        var device = staticDevice
        if let token = UserDefaults.standard.string(forKey: Self.savedTokenKey), !token.isEmpty {
            device.authToken = token
        }

        guard let client = try? GLKVMClient(device: device, allowInsecureTLS: true) else {
            throw KVMError.connectionFailed
        }

        do {
            try await client.authCheck()
        } catch {
            if let password, !password.isEmpty {
                let token = try await client.authLogin(user: user, password: password)
                client.authToken = token
                device.authToken = token
                UserDefaults.standard.set(token, forKey: Self.savedTokenKey)
            } else {
                throw KVMError.authenticationFailed
            }
        }

        if let edidHex = config.edidHex {
            try await client.setEDIDHex(edidHex)
        }

        connectedDevice = device
        glkvmClient = client
        return device
    }

    func disconnect() {
        connectedDevice = nil
        glkvmClient = nil
    }
}
