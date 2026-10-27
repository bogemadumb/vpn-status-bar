import Foundation
import Darwin

enum RuleTarget: String, CaseIterable {
    case direct, proxy, block

    var fileName: String { rawValue + ".json" }

    var label: String {
        switch self {
        case .direct: return "напрямую"
        case .proxy: return "через VPS"
        case .block: return "блок"
        }
    }
}

enum RuleKind: String, CaseIterable {
    case domain
    case domainSuffix = "domain_suffix"
    case ipCidr = "ip_cidr"
    case processName = "process_name"

    var label: String {
        switch self {
        case .domain: return "домен"
        case .domainSuffix: return "сайт и поддомены"
        case .ipCidr: return "адрес"
        case .processName: return "приложение"
        }
    }
}

struct UserRule: Identifiable, Hashable {
    let target: RuleTarget
    let kind: RuleKind
    let value: String
    var id: String { "\(target.rawValue)|\(kind.rawValue)|\(value)" }
}

enum RuleDetect {
    static func isIPv4(_ s: String) -> Bool {
        let p = s.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count == 4 else { return false }
        return p.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCII) && Int($0).map { $0 <= 255 } == true }
    }

    static func isIPv6(_ s: String) -> Bool {
        var a = in6_addr()
        return s.contains(":") && inet_pton(AF_INET6, s, &a) == 1
    }

    static func cidr(_ raw: String) -> String? {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2, let ip = parts.first else { return nil }
        if isIPv4(ip) {
            if parts.count == 1 { return ip + "/32" }
            guard let n = Int(parts[1]), (0...32).contains(n) else { return nil }
            return "\(ip)/\(n)"
        }
        if isIPv6(ip) {
            if parts.count == 1 { return ip.lowercased() + "/128" }
            guard let n = Int(parts[1]), (0...128).contains(n) else { return nil }
            return "\(ip.lowercased())/\(n)"
        }
        return nil
    }

    static func hostFromURL(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let h = URL(string: s)?.host, !h.isEmpty else { return nil }
        var host = h.lowercased()
        if host.hasPrefix("www.") && host.count > 4 { host.removeFirst(4) }
        return host
    }

    static func parse(_ raw: String) -> (kind: RuleKind, value: String)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if s.contains("://") {
            guard let h = hostFromURL(s) else { return nil }
            s = h
        }
        if let c = cidr(s) { return (.ipCidr, c) }
        if s.contains("/") {
            let base = s.split(separator: "/").last.map(String.init) ?? ""
            return base.isEmpty ? nil : (.processName, base)
        }
        if s.hasPrefix("*.") { s.removeFirst(2) }
        if s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { return nil }
        if s.contains(".") && !s.contains(" ") && !s.hasSuffix(".") {
            return (.domainSuffix, s.lowercased())
        }
        return (.processName, s)
    }
}

struct RuleDoc {
    static let placeholder = "placeholder.invalid"
    var buckets: [RuleKind: [String]] = [:]
    var opaque: [Any] = []
    var trailingNewline = true

    static func parse(_ data: Data) -> RuleDoc? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rules = obj["rules"] as? [Any] else { return nil }
        var doc = RuleDoc()
        doc.trailingNewline = data.last == 0x0A
        for r in rules {
            if let d = r as? [String: Any], d.count == 1, let k = d.keys.first,
               let kind = RuleKind(rawValue: k), let vals = d[k] as? [String] {
                for v in vals where !(kind == .domain && v == placeholder) {
                    if !(doc.buckets[kind] ?? []).contains(v) { doc.buckets[kind, default: []].append(v) }
                }
            } else {
                doc.opaque.append(r)
            }
        }
        return doc
    }

    var entries: [(kind: RuleKind, value: String)] {
        RuleKind.allCases.flatMap { k in (buckets[k] ?? []).map { (k, $0) } }
    }

    func contains(_ kind: RuleKind, _ value: String) -> Bool { (buckets[kind] ?? []).contains(value) }

    mutating func add(_ kind: RuleKind, _ value: String) {
        if !contains(kind, value) { buckets[kind, default: []].append(value) }
    }

    mutating func remove(_ kind: RuleKind, _ value: String) {
        buckets[kind]?.removeAll { $0 == value }
        if buckets[kind]?.isEmpty == true { buckets[kind] = nil }
    }

    func serialize() -> Data {
        var rules: [String] = []
        for k in RuleKind.allCases {
            if let v = buckets[k], !v.isEmpty { rules.append("{\(Self.str(k.rawValue)): \(Self.arr(v))}") }
        }
        for o in opaque { rules.append(Self.py(o)) }
        if rules.isEmpty { rules.append("{\"domain\": [\(Self.str(Self.placeholder))]}") }
        let text = "{\"version\": 2, \"rules\": [\(rules.joined(separator: ", "))]}" + (trailingNewline ? "\n" : "")
        return Data(text.utf8)
    }

    static func str(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]),
              let t = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(t.dropFirst().dropLast())
    }

    static func arr(_ v: [String]) -> String { "[" + v.map(str).joined(separator: ", ") + "]" }

    static func py(_ o: Any) -> String {
        if let d = o as? [String: Any] {
            return "{" + d.keys.sorted().map { "\(str($0)): \(py(d[$0]!))" }.joined(separator: ", ") + "}"
        }
        if let a = o as? [Any] { return "[" + a.map(py).joined(separator: ", ") + "]" }
        if let s = o as? String { return str(s) }
        if let n = o as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        return "null"
    }
}

struct RuleFiles {
    static let defaultDir = "/usr/local/etc/singbox/user"
    let dir: String

    init(dir: String = RuleFiles.defaultDir) { self.dir = dir }

    func path(_ t: RuleTarget) -> String { dir + "/" + t.fileName }

    private func read(_ t: RuleTarget) throws -> RuleDoc {
        guard let data = FileManager.default.contents(atPath: path(t)), let doc = RuleDoc.parse(data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return doc
    }

    private func write(_ doc: RuleDoc, _ t: RuleTarget) throws {
        let p = path(t)
        let data = doc.serialize()
        if FileManager.default.contents(atPath: p) == data { return }
        let mode = ((try? FileManager.default.attributesOfItem(atPath: p))?[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        let tmp = "\(dir)/.\(t.fileName).tmp\(getpid())"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: mode]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(tmp, p) != 0 {
            try? FileManager.default.removeItem(atPath: tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func load() -> [UserRule] {
        var out: [UserRule] = []
        for t in [RuleTarget.block, .direct, .proxy] {
            guard let doc = try? read(t) else { continue }
            out += doc.entries.map { UserRule(target: t, kind: $0.kind, value: $0.value) }
        }
        return out
    }

    func alwaysVps() -> [String] {
        guard let data = FileManager.default.contents(atPath: dir + "/always-vps.json"),
              let doc = RuleDoc.parse(data) else { return [] }
        return doc.entries.map { $0.value }
    }

    @discardableResult
    func add(_ value: String, kind: RuleKind, target: RuleTarget) throws -> Bool {
        var doc = try read(target)
        var changed = !doc.contains(kind, value)
        doc.add(kind, value)
        try write(doc, target)
        for other in RuleTarget.allCases where other != target {
            var o = try read(other)
            if o.contains(kind, value) {
                o.remove(kind, value)
                try write(o, other)
                changed = true
            }
        }
        return changed
    }

    func remove(_ rule: UserRule) throws {
        var doc = try read(rule.target)
        doc.remove(rule.kind, rule.value)
        try write(doc, rule.target)
    }

    func find(_ kind: RuleKind, _ value: String) -> RuleTarget? {
        load().first { $0.kind == kind && $0.value == value }?.target
    }
}
