import Foundation

struct RawConn {
    let id: String
    let processPath: String
    let host: String
    let destIP: String
    let destPort: String
    let network: String
    let chains: [String]
    let rule: String
    let download: Double
    let upload: Double
    let start: Date?

    init?(json o: [String: Any]) {
        guard let id = o["id"] as? String else { return nil }
        let m = o["metadata"] as? [String: Any] ?? [:]
        self.id = id
        processPath = m["processPath"] as? String ?? ""
        host = m["host"] as? String ?? ""
        destIP = m["destinationIP"] as? String ?? ""
        destPort = m["destinationPort"] as? String ?? ""
        network = m["network"] as? String ?? ""
        chains = o["chains"] as? [String] ?? []
        rule = o["rule"] as? String ?? ""
        download = (o["download"] as? NSNumber)?.doubleValue ?? 0
        upload = (o["upload"] as? NSNumber)?.doubleValue ?? 0
        start = (o["start"] as? String).flatMap(ConnLogic.parseDate)
    }
}

enum ConnRoute: String {
    case vps, direct, local, block

    var label: String {
        switch self {
        case .vps: return "VPS"
        case .direct: return "напрямую"
        case .local: return "локально"
        case .block: return "блок"
        }
    }
}

enum ConnLogic {
    nonisolated(unsafe) private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()

    static func parseDate(_ s: String) -> Date? {
        if let d = isoFrac.date(from: s) { return d }
        if let d = isoPlain.date(from: s) { return d }
        if let dot = s.firstIndex(of: "."), let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            return isoPlain.date(from: String(s[..<dot]) + String(s[tz...]))
        }
        return nil
    }

    static func stripUser(_ path: String) -> String {
        guard path.hasSuffix(")"), let r = path.range(of: " (", options: .backwards) else { return path }
        let user = path[r.upperBound...].dropLast()
        return user.contains("(") || user.contains(")") || user.contains("/") ? path : String(path[..<r.lowerBound])
    }

    static func processName(_ path: String) -> String {
        let p = stripUser(path).trimmingCharacters(in: .whitespaces)
        if p.isEmpty { return "" }
        return p.split(separator: "/").last.map(String.init) ?? p
    }

    static func isPrivateIP(_ ip: String) -> Bool {
        if ip.contains(":") {
            let l = ip.lowercased()
            return l == "::1" || l.hasPrefix("fe80") || l.hasPrefix("fc") || l.hasPrefix("fd")
        }
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || p[0] == 127 || (p[0] == 169 && p[1] == 254)
            || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
    }

    static func action(_ rule: String) -> String {
        guard let r = rule.range(of: " => ") else { return "" }
        return String(rule[r.upperBound...])
    }

    static func route(chains: [String], rule: String, destIP: String) -> ConnRoute {
        let act = action(rule)
        if act.hasPrefix("reject") || act.hasPrefix("drop") { return .block }
        var out: String?
        if !chains.isEmpty {
            out = chains.contains("vps") ? "vps" : chains.last
        } else if act.hasPrefix("route("), act.hasSuffix(")") {
            out = String(act.dropFirst(6).dropLast())
        }
        guard let o = out else { return .block }
        if o == "direct" {
            return rule.contains("ip_is_private") || isPrivateIP(destIP) ? .local : .direct
        }
        return .vps
    }

    static func exitTag(chains: [String]) -> String? { ExitLogic.chainExit(chains) }

    static func humanRule(_ rule: String) -> String {
        if rule == "final" { return "Всё остальное" }
        let cond = rule.range(of: " => ").map { String(rule[..<$0.lowerBound]) } ?? rule
        let table: [(String, String)] = [
            ("rule_set=user-always-vps", "Закреплённые: всегда VPS"),
            ("rule_set=user-direct", "Мои: напрямую"),
            ("rule_set=user-proxy", "Мои: через VPS"),
            ("rule_set=user-block", "Мои: блок"),
            ("rule_set=geoip-local", "Локальные сайты"),
            ("ip_cidr=\(AppConfig.shared.serverIP)/32", "Сам сервер"),
            ("ip_cidr=17.0.0.0/8", "Apple"),
            ("ip_is_private", "Локальная сеть"),
            ("clash_mode=Direct", "Режим «напрямую»"),
            ("clash_mode=Global", "Режим «всё через VPS»"),
            ("protocol=dns", "DNS"),
        ]
        for (k, v) in table where cond.contains(k) { return v }
        if cond.hasPrefix("port=") { return "Почтовые порты" }
        return cond.isEmpty ? rule : cond
    }

    static func hostName(host: String, ip: String, port: String) -> String {
        if !host.isEmpty { return host }
        if ip.isEmpty { return "—" }
        return port.isEmpty ? ip : "\(ip):\(port)"
    }

    static func speed(_ bps: Double) -> String {
        if bps <= 0 { return "0" }
        if bps >= 100_000 { return String(format: "%.1f МБ/с", bps / 1_000_000).replacingOccurrences(of: ".", with: ",") }
        if bps >= 1000 { return "\(Int((bps / 1000).rounded())) КБ/с" }
        return "\(Int(bps)) Б/с"
    }

    static func age(_ sec: TimeInterval) -> String {
        let s = max(0, Int(sec))
        if s < 60 { return "\(s) с" }
        if s < 3600 { return "\(s / 60) мин" }
        if s < 86400 { return "\(s / 3600) ч" }
        return "\(s / 86400) д"
    }
}
