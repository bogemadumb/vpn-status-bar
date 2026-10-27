import Foundation

enum ServerError: Error, Equatable {
    case unreachable(String)
    case remote(String)
    case badOutput

    var text: String {
        switch self {
        case .unreachable(let s): return s
        case .remote(let s):
            switch s {
            case "user exists": return "Такой ключ уже есть"
            case "no such user": return "Такого ключа нет на сервере"
            case "refusing to revoke mac without --force": return "Ключ этого Мака не отзывается"
            case "command not allowed": return "Команда не разрешена ключом доступа"
            default: return "Сервер ответил: \(s)"
            }
        case .badOutput: return "Сервер вернул непонятный ответ"
        }
    }
}

struct VnstatMonth: Equatable {
    var iface: String
    var rx: Double
    var tx: Double
}

struct ServerHealth: Equatable {
    var xray: Bool
    var nginx: Bool
    var cpuPercent: Double
    var load: [Double]
    var cpus: Int
    var ramUsed: Double
    var ramTotal: Double
    var diskFree: Double
    var diskTotal: Double
    var uptime: Double
    var certNotAfter: Date?
    var vnstat: VnstatMonth?
    var xrayVersion: String?
}

struct ServerUserStat: Equatable {
    var up: Double
    var down: Double
    var lastSeen: Date?
}

struct ServerStats: Equatable {
    var month: String
    var users: [String: ServerUserStat]
}

struct ServerUserInfo: Equatable {
    var name: String
    var notorrent: Bool
    var created: String?
}

struct KeyRow: Identifiable, Equatable {
    var name: String
    var label: String
    var hint: String
    var up: Double
    var down: Double
    var lastSeen: Date?
    var notorrent: Bool
    var online: Bool
    var id: String { name }
}

enum Level: Int, Comparable {
    case ok = 0, warn, alarm
    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
}

struct ServerLevels: Equatable {
    var xray: Level
    var nginx: Level
    var cpu: Level
    var load: Level
    var ram: Level
    var disk: Level
    var cert: Level
}

enum ServerParse {
    static func date(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        return nil
    }

    static func object(_ d: Data) -> Result<[String: Any], ServerError> {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return .failure(.badOutput) }
        if let e = o["error"] as? String { return .failure(.remote(e)) }
        return .success(o)
    }

    static func health(_ d: Data) -> Result<ServerHealth, ServerError> {
        switch object(d) {
        case .failure(let e): return .failure(e)
        case .success(let o):
            guard let xray = o["xray"] as? Bool, let nginx = o["nginx"] as? Bool,
                  let cpu = num(o["cpu_percent"]), let cpus = num(o["cpus"]),
                  let ru = num(o["ram_used"]), let rt = num(o["ram_total"]),
                  let df = num(o["disk_free"]), let dt = num(o["disk_total"]),
                  let up = num(o["uptime_s"]) else { return .failure(.badOutput) }
            let load = (o["load"] as? [Any] ?? []).compactMap { num($0) }
            var vn: VnstatMonth?
            if let m = o["vnstat_month"] as? [String: Any], let rx = num(m["rx"]), let tx = num(m["tx"]) {
                vn = VnstatMonth(iface: m["iface"] as? String ?? "", rx: rx, tx: tx)
            }
            return .success(ServerHealth(
                xray: xray, nginx: nginx, cpuPercent: cpu, load: load, cpus: max(1, Int(cpus)),
                ramUsed: ru, ramTotal: rt, diskFree: df, diskTotal: dt, uptime: up,
                certNotAfter: date(o["cert_not_after"] as? String), vnstat: vn,
                xrayVersion: o["xray_version"] as? String))
        }
    }

    static func stats(_ d: Data) -> Result<ServerStats, ServerError> {
        switch object(d) {
        case .failure(let e): return .failure(e)
        case .success(let o):
            guard let month = o["month"] as? String, let arr = o["users"] as? [[String: Any]] else { return .failure(.badOutput) }
            var users: [String: ServerUserStat] = [:]
            for u in arr {
                guard let n = u["email"] as? String else { continue }
                users[n] = ServerUserStat(up: num(u["up"]) ?? 0, down: num(u["down"]) ?? 0, lastSeen: date(u["last_seen"] as? String))
            }
            return .success(ServerStats(month: month, users: users))
        }
    }

    static func users(_ d: Data) -> Result<[ServerUserInfo], ServerError> {
        switch object(d) {
        case .failure(let e): return .failure(e)
        case .success(let o):
            guard let arr = o["users"] as? [[String: Any]] else { return .failure(.badOutput) }
            return .success(arr.compactMap { u in
                guard let n = u["email"] as? String else { return nil }
                return ServerUserInfo(name: n, notorrent: u["notorrent"] as? Bool ?? false, created: u["created"] as? String)
            })
        }
    }

    static func link(_ d: Data) -> Result<String, ServerError> {
        switch object(d) {
        case .failure(let e): return .failure(e)
        case .success(let o):
            guard let l = o["link"] as? String, l.hasPrefix("vless://") else { return .failure(.badOutput) }
            return .success(l)
        }
    }

    static func ok(_ d: Data) -> Result<Bool, ServerError> {
        switch object(d) {
        case .failure(let e): return .failure(e)
        case .success(let o):
            guard o["ok"] as? Bool == true else { return .failure(.badOutput) }
            return .success(o["restart_needed"] as? Bool ?? false)
        }
    }
}

enum ServerLogic {
    static let protectedNames: Set<String> = ["mac", "home", "phone", "kaban"]
    static let onlineWindow: TimeInterval = 300

    static func validName(_ s: String) -> Bool {
        let u = Array(s.unicodeScalars)
        guard (1...32).contains(u.count) else { return false }
        func lower(_ c: Unicode.Scalar) -> Bool { (c.value >= 97 && c.value <= 122) || (c.value >= 48 && c.value <= 57) }
        guard lower(u[0]) else { return false }
        return u.dropFirst().allSatisfy { lower($0) || $0 == "_" || $0 == "-" }
    }

    static func nameError(_ s: String, existing: [String]) -> String? {
        if s.isEmpty { return nil }
        if !validName(s) { return "Только латиница a–z, цифры, _ и -; начало — буква или цифра; до 32 символов" }
        if existing.contains(s) { return "Такой ключ уже есть" }
        return nil
    }

    static func label(_ name: String) -> String {
        switch name {
        case "mac": return "Этот Мак"
        case "home": return "Домашний сервер (Acer)"
        case "phone": return "Телефон"
        case "kaban": return "Кабан"
        default: return name
        }
    }

    static func hint(_ name: String, created: String?) -> String {
        switch name {
        case "mac": return "mac · sing-box, TUN"
        case "home": return "home · xray, прокси для дома"
        case "phone": return "phone · iPhone"
        case "kaban": return "kaban"
        default: return created.map { "\(name) · создан \($0)" } ?? name
        }
    }

    static func isOnline(_ seen: Date?, now: Date) -> Bool {
        guard let s = seen else { return false }
        return now.timeIntervalSince(s) < onlineWindow
    }

    static func relative(_ d: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let d = d else { return "не подключался" }
        let secs = now.timeIntervalSince(d)
        if secs < onlineWindow { return "сейчас" }
        if secs < 3600 { return "\(Int(secs / 60)) мин назад" }
        let hm = DateFormatter()
        hm.locale = Locale(identifier: "ru_RU"); hm.calendar = calendar; hm.timeZone = calendar.timeZone
        hm.dateFormat = "HH:mm"
        if calendar.isDate(d, inSameDayAs: now) { return "\(Int(secs / 3600)) ч назад" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) {
            return "вчера, \(hm.string(from: d))"
        }
        hm.dateFormat = "dd.MM, HH:mm"
        return hm.string(from: d)
    }

    static func rows(users: [ServerUserInfo], stats: ServerStats?, now: Date) -> [KeyRow] {
        users.map { u in
            let s = stats?.users[u.name]
            return KeyRow(name: u.name, label: label(u.name), hint: hint(u.name, created: u.created),
                          up: s?.up ?? 0, down: s?.down ?? 0, lastSeen: s?.lastSeen,
                          notorrent: u.notorrent, online: isOnline(s?.lastSeen, now: now))
        }
    }

    static func limits(_ r: KeyRow) -> String { r.notorrent ? "без торрентов" : "нет" }

    static func certDays(_ h: ServerHealth, now: Date) -> Int? {
        guard let c = h.certNotAfter else { return nil }
        return Int((c.timeIntervalSince(now) / 86400).rounded(.down))
    }

    static func loadPerCpu(_ h: ServerHealth) -> Double? {
        h.load.first.map { $0 / Double(max(1, h.cpus)) }
    }

    static func levels(_ h: ServerHealth, now: Date) -> ServerLevels {
        let load: Level = (loadPerCpu(h) ?? 0) > 1 ? .warn : .ok
        let cpu: Level = h.cpuPercent >= 90 ? .warn : .ok
        let ram: Level = h.ramTotal > 0 && h.ramUsed / h.ramTotal >= 0.9 ? .warn : .ok
        let disk: Level = h.diskTotal > 0 && h.diskFree / h.diskTotal < 0.1 ? .warn : .ok
        var cert = Level.ok
        if let d = certDays(h, now: now) { cert = d < 7 ? .alarm : (d < 21 ? .warn : .ok) }
        return ServerLevels(xray: h.xray ? .ok : .alarm, nginx: h.nginx ? .ok : .alarm,
                            cpu: cpu, load: load, ram: ram, disk: disk, cert: cert)
    }

    static func monthTotal(_ h: ServerHealth) -> Double? {
        h.vnstat.map { $0.rx + $0.tx }
    }

    static func vnstatNote(now: Date, calendar: Calendar = .current) -> String? {
        let c = calendar.dateComponents([.year, .month], from: now)
        return c.year == 2026 && c.month == 10 ? "с 03.10" : nil
    }

    static func uptimeText(_ s: Double) -> String {
        let m = Int(s / 60)
        let d = m / 1440, h = (m % 1440) / 60, mm = m % 60
        if d > 0 { return "\(d) д \(h) ч" }
        if h > 0 { return "\(h) ч \(mm) мин" }
        return "\(mm) мин"
    }

    static func args(add name: String, noTorrent: Bool) -> [String] {
        noTorrent ? ["add", name, "--no-torrent"] : ["add", name]
    }
}
