import Foundation

struct AppBuildConfig {
    let appName: String
    let host: String
    let port: Int
    let edidHex: String?

    static let current = AppBuildConfig(bundle: .main)

    init(bundle: Bundle) {
        let config = Self.loadBuildConfigJSON(bundle: bundle)

        appName = Self.requiredValue(config["appName"], envName: "GLKVM_APP_NAME")
        let hostURLString = Self.requiredValue(config["hostURL"], envName: "GLKVM_HOST_URL")

        let parsed = Self.parseHostURL(hostURLString)
        host = parsed.host
        port = parsed.port

        edidHex = Self.normalizedEDID(config["edidHex"])
    }

    private static func loadBuildConfigJSON(bundle: Bundle) -> [String: String] {
        guard let url = bundle.url(forResource: "BuildConfig", withExtension: "json") else {
            fatalError("Missing BuildConfig.json in app bundle. Run build scripts with required env vars.")
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            fatalError("Failed to read BuildConfig.json from app bundle.")
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fatalError("BuildConfig.json is invalid JSON.")
        }

        var result: [String: String] = [:]
        for (key, value) in object {
            if let stringValue = value as? String {
                result[key] = stringValue
            }
        }

        return result
    }

    private static func requiredValue(_ raw: String?, envName: String) -> String {
        guard let raw else {
            fatalError("Missing build config value. Set \(envName) at build time.")
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "__REQUIRED__" else {
            fatalError("Build config value is empty. Set \(envName) at build time.")
        }

        return trimmed
    }

    private static func parseHostURL(_ value: String) -> (host: String, port: Int) {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty,
              (components.path.isEmpty || components.path == "/"),
              components.query == nil,
              components.fragment == nil,
              scheme == "https" else {
            fatalError("GLKVM_HOST_URL must be a valid https URL.")
        }

        let port = components.port ?? 443
        return (host, port)
    }

    private static func normalizedEDID(_ raw: String?) -> String? {
        guard let raw else { return nil }

        let compact = raw.split(whereSeparator: { $0.isWhitespace }).joined()
        guard !compact.isEmpty else { return nil }

        let isHex = compact.range(of: "^[0-9A-Fa-f]+$", options: .regularExpression) != nil
        guard isHex, compact.count % 2 == 0 else {
            fatalError("GLKVM_EDID_HEX must contain an even number of hex characters.")
        }

        return compact.uppercased()
    }
}
