import Foundation

/// Reads WhatsApp health and whitelist data directly from disk.
/// This avoids shelling out to helperctl for frequently-polled data.
struct WhatsAppStatusService {
    private let cbDir: String

    init(cbDir: String = "\(NSHomeDirectory())/.context-bridge") {
        self.cbDir = cbDir
    }

    // MARK: - Health

    struct HealthStatus: Decodable {
        var status: String
        var lastMessageAt: String?
        var uptimeSeconds: Int64?
        var error: String?

        enum CodingKeys: String, CodingKey {
            case status
            case lastMessageAt = "last_message_at"
            case uptimeSeconds = "uptime_seconds"
            case error
        }
    }

    /// Reads whatsapp-health.json and returns the parsed status.
    /// Returns nil if the file doesn't exist or can't be parsed.
    func fetchHealth() -> HealthStatus? {
        let path = "\(cbDir)/whatsapp-health.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }

        // Check staleness (>5 min old)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) > 300 {
            return HealthStatus(status: "stale")
        }

        return try? JSONDecoder().decode(HealthStatus.self, from: data)
    }

    /// Returns a human-readable display string for the WhatsApp status.
    var displayStatus: String {
        guard let health = fetchHealth() else {
            return "Not installed"
        }
        switch health.status {
        case "syncing":       return "Syncing"
        case "connected":     return "Syncing"
        case "disconnected":  return "Disconnected"
        case "paused":        return "Paused"
        case "error":         return "Error"
        case "stale":         return "Not running"
        case "not running":   return "Not running"
        default:              return health.status.capitalized
        }
    }

    /// Returns true if the status indicates a healthy/running state.
    var isHealthy: Bool {
        guard let health = fetchHealth() else { return false }
        return health.status == "syncing" || health.status == "connected"
    }

    // MARK: - Whitelist Contacts

    struct WhitelistContact: Decodable, Identifiable {
        var id: String
        var label: String
    }

    private struct PrivacyRules: Decodable {
        struct WhatsAppWhitelist: Decodable {
            var mode: String?
            var contacts: [WhitelistContact]?
        }
        var whatsappWhitelist: WhatsAppWhitelist?

        enum CodingKeys: String, CodingKey {
            case whatsappWhitelist = "whatsapp_whitelist"
        }
    }

    /// Reads privacy-rules.json and returns the WhatsApp whitelist contacts.
    func fetchWhitelistContacts() -> [WhitelistContact] {
        let path = "\(cbDir)/privacy-rules.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return []
        }
        guard let rules = try? JSONDecoder().decode(PrivacyRules.self, from: data) else {
            return []
        }
        return rules.whatsappWhitelist?.contacts ?? []
    }

    // MARK: - Binary check

    /// Returns true if the claw-whatsapp binary exists.
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: "\(cbDir)/bin/claw-whatsapp")
    }
}
