import Foundation

struct ExitInfo: Equatable {
    let tag: String
    let flag: String
    let country: String
    let adjective: String
    let own: Bool
    let owner: String
    let host: String
    let port: UInt16

    var noun: String { own ? "VPS" : (owner.isEmpty ? tag : "сервер") }
    var label: String { owner.isEmpty ? country : "\(country) (\(owner))" }
    var short: String { "\(flag) \(country)" }
}

enum ExitCatalog {
    static let selector = "vps"
    static let autoTag = "auto"

    static let list: [ExitInfo] = [
        ExitInfo(tag: "fin", flag: "\u{1F1EB}\u{1F1EE}", country: "Финляндия", adjective: "Финский", own: true, owner: "свой", host: AppConfig.shared.serverIP, port: 443),
        ExitInfo(tag: "ext-nl", flag: "\u{1F1F3}\u{1F1F1}", country: "Нидерланды", adjective: "Нидерландский", own: false, owner: "внешний", host: "nl.example.net", port: 443),
        ExitInfo(tag: "ext-lt", flag: "\u{1F1F1}\u{1F1F9}", country: "Литва", adjective: "Литовский", own: false, owner: "внешний", host: "lt.example.net", port: 443),
        ExitInfo(tag: "ext-se", flag: "\u{1F1F8}\u{1F1EA}", country: "Швеция", adjective: "Шведский", own: false, owner: "внешний", host: "se.example.net", port: 443),
    ]

    static func info(_ tag: String) -> ExitInfo {
        list.first { $0.tag == tag }
            ?? ExitInfo(tag: tag, flag: "\u{1F310}", country: tag, adjective: tag, own: false, owner: "", host: "", port: 443)
    }

    static let fallback = list[0]
}

struct ActiveExit: Equatable {
    let tag: String
    let auto: Bool
}

enum ExitPing: Equatable {
    case ms(Int)
    case down
    case unknown
}

struct ExitSnapshot: Equatable {
    var active: ActiveExit?
    var pings: [String: ExitPing]
    var hasSelector: Bool
}

struct ExitChange: Equatable {
    let from: ActiveExit
    let to: ActiveExit
    var tagChanged: Bool { from.tag != to.tag }
}

enum ExitLogic {
    static func resolve(vpsNow: String?, autoNow: String?) -> ActiveExit? {
        guard let v = vpsNow, !v.isEmpty else { return nil }
        if v == ExitCatalog.autoTag {
            guard let a = autoNow, !a.isEmpty, a != ExitCatalog.autoTag else { return nil }
            return ActiveExit(tag: a, auto: true)
        }
        return ActiveExit(tag: v, auto: false)
    }

    static func chainExit(_ chains: [String]) -> String? {
        guard chains.contains(ExitCatalog.selector), let f = chains.first,
              f != ExitCatalog.selector, f != ExitCatalog.autoTag else { return nil }
        return f
    }

    static func ping(_ proxy: [String: Any]?, now: Date, staleAfter: TimeInterval = 180) -> ExitPing {
        guard let h = (proxy?["history"] as? [[String: Any]])?.last else { return .unknown }
        if let ts = (h["time"] as? String).flatMap(ConnLogic.parseDate), now.timeIntervalSince(ts) > staleAfter {
            return .unknown
        }
        let d = (h["delay"] as? NSNumber)?.intValue ?? 0
        return d > 0 ? .ms(d) : .down
    }

    static func snapshot(_ o: [String: Any], now: Date) -> ExitSnapshot {
        let p = o["proxies"] as? [String: Any] ?? [:]
        guard let vps = p[ExitCatalog.selector] as? [String: Any], vps["type"] as? String == "Selector" else {
            return ExitSnapshot(active: nil, pings: [:], hasSelector: false)
        }
        let autoNow = (p[ExitCatalog.autoTag] as? [String: Any])?["now"] as? String
        var pings: [String: ExitPing] = [:]
        for e in ExitCatalog.list { pings[e.tag] = ping(p[e.tag] as? [String: Any], now: now) }
        return ExitSnapshot(active: resolve(vpsNow: vps["now"] as? String, autoNow: autoNow), pings: pings, hasSelector: true)
    }

    static func merge(passive: [String: ExitPing], probed: [String: (ping: ExitPing, at: Date)],
                      now: Date, fresh: TimeInterval = 20) -> [String: ExitPing] {
        var out = passive
        for (tag, p) in probed where now.timeIntervalSince(p.at) < fresh { out[tag] = p.ping }
        return out
    }

    static func change(prev: ActiveExit?, next: ActiveExit?) -> ExitChange? {
        guard let a = prev, let b = next, a != b else { return nil }
        return ExitChange(from: a, to: b)
    }

    static func direction(_ to: String) -> String {
        ExitCatalog.info(to).own ? "exit-own" : "exit-ext"
    }

    static func detail(_ c: ExitChange, byUser: Bool) -> String {
        let to = ExitCatalog.info(c.to.tag)
        if !c.tagChanged {
            return c.to.auto ? "автовыбор: \(to.label)" : "закреплён: \(to.label)"
        }
        let from = ExitCatalog.info(c.from.tag)
        var s = "\(from.label) → \(to.label)"
        if byUser { s += c.to.auto ? " · автовыбор" : " · закреплён вручную" }
        else if c.to.auto { s += " · автоматически" }
        return s
    }

    static func notification(_ c: ExitChange, fromDown: Bool) -> (title: String, body: String) {
        let from = ExitCatalog.info(c.from.tag)
        let to = ExitCatalog.info(c.to.tag)
        if to.own { return ("VPN: выход снова свой", "Выход вернулся: \(from.label) → \(to.label)") }
        let body = fromDown ? "\(from.adjective) \(from.noun) не отвечает → \(to.label)" : "\(from.label) → \(to.label)"
        return ("VPN: выход переключён", body)
    }

    static func pingText(_ p: ExitPing?) -> String {
        switch p {
        case .ms(let v): return "\(v) мс"
        case .down: return "не отвечает"
        default: return "—"
        }
    }

    static func switchesText(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        let word = m10 == 1 && m100 != 11 ? "переключение"
            : ((2...4).contains(m10) && !(12...14).contains(m100) ? "переключения" : "переключений")
        return "\(n) \(word) за сутки"
    }
}
