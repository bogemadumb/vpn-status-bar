import Foundation
import Security

enum CoreError: Error {
    case noSecret
    case http(Int)
    case badBody
}

enum TrafficEvent {
    case connected
    case sample(up: Double, down: Double)
    case disconnected
}

enum Keychain {
    #if !CLIENT_EDITION
    static let service = "dev.vpnstatusbar.clash"

    static func viaSecurityTool() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-a", NSUserName(), "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let s = String(data: data, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    #endif

    static func fromFile() -> String? {
        let path = NSHomeDirectory() + "/Library/Application Support/VPNMonitor/clash-secret"
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func clashSecret() -> String? {
        #if CLIENT_EDITION
        return fromFile()
        #else
        return viaSecurityTool()
        #endif
    }
}

final class CoreClient: @unchecked Sendable {
    private let base = "http://127.0.0.1:9090"
    private let lock = NSLock()
    private var secret: String?
    private var lastKeychainTry = Date.distantPast
    private let session: URLSession
    private let streamSession: URLSession

    init() {
        let a = URLSessionConfiguration.ephemeral
        a.timeoutIntervalForRequest = 20
        a.waitsForConnectivity = false
        a.connectionProxyDictionary = [:]
        session = URLSession(configuration: a)
        let b = URLSessionConfiguration.ephemeral
        b.timeoutIntervalForRequest = 8
        b.timeoutIntervalForResource = 86400
        b.connectionProxyDictionary = [:]
        streamSession = URLSession(configuration: b)
    }

    var hasSecret: Bool { currentSecret() != nil }

    private func currentSecret() -> String? {
        lock.lock(); defer { lock.unlock() }
        if secret == nil, Date().timeIntervalSince(lastKeychainTry) > 60 {
            lastKeychainTry = Date()
            secret = Keychain.clashSecret()
        }
        return secret
    }

    private func makeRequest(_ path: String, timeout: TimeInterval = 8, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let s = currentSecret() else { throw CoreError.noSecret }
        guard let url = URL(string: base + path) else { throw CoreError.badBody }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = timeout
        r.setValue("Bearer \(s)", forHTTPHeaderField: "Authorization")
        if let body = body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func send(_ method: String, _ path: String, body: Data? = nil) async throws {
        let (_, resp) = try await session.data(for: makeRequest(path, method: method, body: body))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw CoreError.http(code) }
    }

    private func getJSON(_ path: String, timeout: TimeInterval = 8) async throws -> [String: Any] {
        let (data, resp) = try await session.data(for: makeRequest(path, timeout: timeout))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw CoreError.http(code) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CoreError.badBody }
        return obj
    }

    func version() async throws -> String {
        let o = try await getJSON("/version")
        guard let v = o["version"] as? String else { throw CoreError.badBody }
        return v
    }

    func configs() async throws -> (mode: String, modes: [String]) {
        let o = try await getJSON("/configs")
        let m = o["mode"] as? String ?? "Rule"
        let l = o["mode-list"] as? [String] ?? ["Rule", "Global", "Direct"]
        return (m, l)
    }

    static let probeURL204 = "https://www.gstatic.com/generate_204"

    func delay(timeoutMs: Int, url: String = CoreClient.probeURL204, proxy: String = "vps") async throws -> Int {
        let enc = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url
        let o = try await getJSON(
            "/proxies/\(proxy)/delay?url=\(enc)&timeout=\(timeoutMs)",
            timeout: Double(timeoutMs) / 1000 + 3)
        guard let d = o["delay"] as? Int else { throw CoreError.badBody }
        return d
    }

    func exits() async throws -> ExitSnapshot {
        ExitLogic.snapshot(try await getJSON("/proxies"), now: Date())
    }

    func selectExit(_ tag: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["name": tag])
        try await send("PUT", "/proxies/\(ExitCatalog.selector)", body: body)
    }

    func setMode(_ mode: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["mode": mode])
        try await send("PATCH", "/configs", body: body)
    }

    func closeConnection(_ id: String) async throws {
        guard let enc = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-"))) else { throw CoreError.badBody }
        try await send("DELETE", "/connections/\(enc)")
    }

    func connections() async throws -> [RawConn] {
        let o = try await getJSON("/connections")
        let list = o["connections"] as? [[String: Any]] ?? []
        return list.compactMap { RawConn(json: $0) }
    }

    func totals() async throws -> (down: Double, up: Double) {
        let o = try await getJSON("/connections")
        return ((o["downloadTotal"] as? NSNumber)?.doubleValue ?? 0,
                (o["uploadTotal"] as? NSNumber)?.doubleValue ?? 0)
    }

    func runTraffic(_ handler: @escaping @Sendable (TrafficEvent) -> Void) async {
        var connected = false
        while !Task.isCancelled {
            do {
                let (bytes, resp) = try await streamSession.bytes(for: makeRequest("/traffic"))
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) {
                    connected = true
                    handler(.connected)
                    for try await line in bytes.lines {
                        guard let d = line.data(using: .utf8),
                              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                        else { continue }
                        let up = (o["up"] as? NSNumber)?.doubleValue ?? 0
                        let down = (o["down"] as? NSNumber)?.doubleValue ?? 0
                        handler(.sample(up: up, down: down))
                    }
                }
            } catch {}
            if connected { handler(.disconnected); connected = false }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
}
