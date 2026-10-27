import Foundation

enum CheckStatus: String {
    case pending, ok, warn, fail, skipped
}

struct CheckItem: Identifiable, Equatable {
    let id: String
    let name: String
    var status: CheckStatus
    var text: String
}

enum Fetch: Equatable {
    case response(status: Int, body: String)
    case failed(String)
}

struct LeakFetches {
    var geo: Fetch
    var ipv6: Fetch
    var dns: Fetch
    var local: Fetch
    var external: Fetch
}

struct LeakVerdict: Equatable {
    var leak: Bool
    var detail: String
}

struct Chip: Equatable {
    let text: String
    let status: CheckStatus
}

enum LeakLogic {
    static var vpsIP: String { AppConfig.shared.serverIP }
    static var finland: String { AppConfig.shared.serverCountryCode }

    static func parseTrace(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            guard let eq = raw.firstIndex(of: "=") else { continue }
            let k = String(raw[..<eq]).trimmingCharacters(in: .whitespaces)
            let v = String(raw[raw.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = v }
        }
        return out
    }

    private static func trace(_ f: Fetch) -> (loc: String, ip: String)? {
        guard case .response(let s, let body) = f, (200..<300).contains(s) else { return nil }
        let t = parseTrace(body)
        guard let loc = t["loc"], !loc.isEmpty else { return nil }
        return (loc, t["ip"] ?? "")
    }

    static func pending() -> [CheckItem] {
        [CheckItem(id: "local", name: "Локальные сайты", status: .pending, text: "проверяю…"),
         CheckItem(id: "external", name: "Внешние сайты", status: .pending, text: "проверяю…"),
         CheckItem(id: "ipv6", name: "Утечка IPv6", status: .pending, text: "проверяю…"),
         CheckItem(id: "dns", name: "DNS", status: .pending, text: "проверяю…"),
         CheckItem(id: "geo", name: "Гео-проверка", status: .pending, text: "проверяю…")]
    }

    static func skipped(_ reason: String) -> [CheckItem] {
        pending().map { CheckItem(id: $0.id, name: $0.name, status: .skipped, text: reason) }
    }

    static func geo(_ f: Fetch) -> CheckItem {
        let name = "Гео-проверка"
        guard let t = trace(f) else { return CheckItem(id: "geo", name: name, status: .warn, text: "нет ответа") }
        if t.loc == finland && (t.ip == vpsIP || t.ip.contains(":")) {
            return CheckItem(id: "geo", name: name, status: .ok, text: "\(t.loc) · \(t.ip)")
        }
        if t.loc == finland {
            return CheckItem(id: "geo", name: name, status: .warn, text: "FI, но адрес \(t.ip), не сервер")
        }
        return CheckItem(id: "geo", name: name, status: .fail, text: "утечка: \(t.loc) · \(t.ip)")
    }

    static func ipv6(_ f: Fetch) -> CheckItem {
        let name = "Утечка IPv6"
        if let t = trace(f) {
            if t.loc == finland { return CheckItem(id: "ipv6", name: name, status: .ok, text: "нет, через туннель (\(finland))") }
            return CheckItem(id: "ipv6", name: name, status: .fail, text: "утечка: \(t.loc) · \(t.ip)")
        }
        return CheckItem(id: "ipv6", name: name, status: .ok, text: "нет")
    }

    static func dns(_ f: Fetch) -> CheckItem {
        let name = "DNS"
        guard let t = trace(f) else { return CheckItem(id: "dns", name: name, status: .warn, text: "нет ответа от 1.1.1.1") }
        if t.loc == finland { return CheckItem(id: "dns", name: name, status: .ok, text: "через туннель, 1.1.1.1") }
        return CheckItem(id: "dns", name: name, status: .fail, text: "утечка: 1.1.1.1 виден из \(t.loc)")
    }

    static func site(id: String, name: String, _ f: Fetch) -> CheckItem {
        if case .response(let s, _) = f, s > 0, s < 500 {
            return CheckItem(id: id, name: name, status: .ok, text: "открываются")
        }
        return CheckItem(id: id, name: name, status: .fail, text: "не открываются")
    }

    static func evaluate(_ f: LeakFetches, mode: String) -> [CheckItem] {
        var items = [site(id: "local", name: "Локальные сайты", f.local),
                     site(id: "external", name: "Внешние сайты", f.external),
                     ipv6(f.ipv6), dns(f.dns), geo(f.geo)]
        if mode == "Direct" {
            for i in items.indices where items[i].id == "ipv6" || items[i].id == "dns" {
                items[i].status = .skipped
                items[i].text = "режим «напрямую»"
            }
        }
        return items
    }

    static func verdict(_ items: [CheckItem]) -> LeakVerdict {
        let bad = items.filter { $0.status == .fail && ["geo", "ipv6", "dns"].contains($0.id) }
        return LeakVerdict(leak: !bad.isEmpty, detail: bad.map { "\($0.name): \($0.text.replacingOccurrences(of: "утечка: ", with: ""))" }.joined(separator: "; "))
    }

    static func chips(_ items: [CheckItem]) -> [Chip] {
        func item(_ id: String) -> CheckItem? { items.first { $0.id == id } }
        guard !items.isEmpty, !items.allSatisfy({ $0.status == .skipped }) else { return [] }
        if items.allSatisfy({ $0.status == .pending }) { return [Chip(text: "проверяю связь…", status: .pending)] }
        var out: [Chip] = []
        if let r = item("local") {
            out.append(Chip(text: r.status == .ok ? "локальные сайты открываются" : "локальные сайты не открываются", status: r.status))
        }
        if let b = item("external") {
            out.append(Chip(text: b.status == .ok ? "внешние сайты открываются" : "внешние сайты не открываются", status: b.status))
        }
        let v = verdict(items)
        if v.leak {
            out.append(Chip(text: "утечка", status: .fail))
        } else if ["geo", "ipv6", "dns"].contains(where: { item($0)?.status == .warn }) {
            out.append(Chip(text: "утечки не подтверждены", status: .warn))
        } else {
            out.append(Chip(text: "утечек нет", status: .ok))
        }
        return out
    }

    static func externalAddress(_ items: [CheckItem]) -> String? {
        guard let g = items.first(where: { $0.id == "geo" }), g.status == .ok || g.status == .fail || g.status == .warn,
              g.text.contains("·") else { return nil }
        return g.text.replacingOccurrences(of: "утечка: ", with: "")
    }
}

enum SpeedMath {
    static func mbps(bytes: Double, seconds: Double) -> Double {
        seconds > 0 ? bytes / seconds / 1_000_000 : 0
    }

    static func format(_ v: Double) -> String {
        String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
    }
}
