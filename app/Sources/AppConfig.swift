import Foundation

struct AppConfig: Decodable, Equatable {
    var serverIP = "203.0.113.10"
    var sshUser = "root"
    var sshKey = "~/.ssh/vpn_status_bar"
    var serverCountryCode = "FI"
    var traceHost = "www.cloudflare.com"
    var localSites = ["https://example.org"]
    var externalSites = ["https://www.wikipedia.org"]
    var pinnedDomainsLabel = "Закреплённые домены"

    static let path = NSHomeDirectory() + "/Library/Application Support/VPNMonitor/config.json"

    static func parse(_ data: Data) -> AppConfig {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return AppConfig() }
        var c = AppConfig()
        if let v = raw["server_ip"] as? String, !v.isEmpty { c.serverIP = v }
        if let v = raw["ssh_user"] as? String, !v.isEmpty { c.sshUser = v }
        if let v = raw["ssh_key"] as? String, !v.isEmpty { c.sshKey = v }
        if let v = raw["server_country_code"] as? String, !v.isEmpty { c.serverCountryCode = v }
        if let v = raw["trace_host"] as? String, !v.isEmpty { c.traceHost = v }
        if let v = raw["local_sites"] as? [String], !v.isEmpty { c.localSites = v }
        if let v = raw["external_sites"] as? [String], !v.isEmpty { c.externalSites = v }
        return c
    }

    static let shared: AppConfig = {
        guard let d = FileManager.default.contents(atPath: path) else { return AppConfig() }
        return parse(d)
    }()

    var sshKeyPath: String { (sshKey as NSString).expandingTildeInPath }
    var localHost: String { URL(string: localSites[0])?.host ?? localSites[0] }
    var sshTarget: String { "\(sshUser)@\(serverIP)" }
}
