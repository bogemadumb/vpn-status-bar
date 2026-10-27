import Foundation

enum NetParse {
    static func physicalDefault(_ netstat: String) -> (iface: String, gateway: String)? {
        for line in netstat.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 4, f[0] == "default", f[3].hasPrefix("en"), RuleDetect.isIPv4(f[1]) else { continue }
            return (f[3], f[1])
        }
        return nil
    }

    static func portNames(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var port = ""
        for line in text.split(separator: "\n") {
            if line.hasPrefix("Hardware Port: ") { port = String(line.dropFirst(15)) }
            else if line.hasPrefix("Device: ") { out[String(line.dropFirst(8))] = port }
        }
        return out
    }

    static func ssid(_ summary: String) -> String? {
        for raw in summary.split(separator: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("SSID : ") {
                let v = String(l.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                if v.isEmpty || v.contains("redacted") { return nil }
                return v
            }
        }
        return nil
    }

    static func firstPublicHop(_ trace: String, gateway: String) -> String? {
        for line in trace.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 2, Int(f[0]) != nil, RuleDetect.isIPv4(f[1]) else { continue }
            let ip = f[1]
            if ip == gateway || ConnLogic.isPrivateIP(ip) || ip.hasPrefix("0.") { continue }
            return ip
        }
        return nil
    }

    static func pingMedian(_ out: String) -> Double? {
        var v: [Double] = []
        for line in out.split(separator: "\n") {
            guard let r = line.range(of: "time=") else { continue }
            let rest = line[r.upperBound...]
            if let n = Double(rest.prefix { $0.isNumber || $0 == "." }) { v.append(n) }
        }
        guard !v.isEmpty else { return nil }
        v.sort()
        return v[v.count / 2]
    }
}
