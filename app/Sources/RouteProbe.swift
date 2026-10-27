import Foundation
import Network

final class ProcBox: @unchecked Sendable {
    private let lock = NSLock()
    private var proc: Process?
    private var cancelled = false

    func set(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        proc = p
        return true
    }

    func kill() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let p = proc, p.isRunning { p.terminate() }
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

enum Shell {
    static func runSync(_ path: String, _ args: [String], timeout: Double, box: ProcBox) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard box.set(p) else { return nil }
        do { try p.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    static func run(_ path: String, _ args: [String], timeout: Double) async -> String? {
        let box = ProcBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                DispatchQueue.global().async { c.resume(returning: runSync(path, args, timeout: timeout, box: box)) }
            }
        } onCancel: { box.kill() }
    }
}

struct NetInfo: Equatable {
    var iface: String
    var gateway: String
    var kind: String
    var name: String
    var note: String
    var key: String { "\(iface)|\(gateway)|\(note)" }
}

enum RouteProbe {
    static let vpsPort: UInt16 = 443
    static var siteURL: String { "https://" + AppConfig.shared.traceHost }
    static let budget = 6.0
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var hopCache: [String: (ip: String?, at: Date)] = [:]

    static func invalidateCache() {
        cacheLock.withLock { hopCache.removeAll() }
    }

    private static func cacheGet(_ key: String) -> (ip: String?, at: Date)? {
        cacheLock.withLock { hopCache[key] }
    }

    private static func cacheSet(_ key: String, _ ip: String?, _ at: Date) {
        cacheLock.withLock { hopCache[key] = (ip, at) }
    }

    static func detect() async -> NetInfo? {
        guard let ns = await Shell.run("/usr/sbin/netstat", ["-rn", "-f", "inet"], timeout: 2),
              let d = NetParse.physicalDefault(ns) else { return nil }
        async let ports = Shell.run("/usr/sbin/networksetup", ["-listallhardwareports"], timeout: 2)
        async let summary = Shell.run("/usr/sbin/ipconfig", ["getsummary", d.iface], timeout: 2)
        let port = NetParse.portNames(await ports ?? "")[d.iface] ?? ""
        let ssid = NetParse.ssid(await summary ?? "")
        let hotspot = d.gateway == "172.20.10.1"
        var kind = "other", name = port.isEmpty ? d.iface : port
        if port.contains("Wi-Fi") {
            kind = "wifi"
            name = ssid.map { "Wi-Fi · \($0)" } ?? "Wi-Fi"
        } else if port.contains("Ethernet") || port.contains("LAN") {
            kind = "ethernet"
            name = "Ethernet"
        }
        if hotspot { name += " · раздача с iPhone" }
        return NetInfo(iface: d.iface, gateway: d.gateway, kind: kind, name: name, note: hotspot ? "hotspot" : "")
    }

    static func ping(_ ip: String, iface: String) async -> Int? {
        guard let out = await Shell.run("/sbin/ping", ["-b", iface, "-c", "3", "-i", "0.2", "-t", "3", ip], timeout: 4.5),
              let ms = NetParse.pingMedian(out) else { return nil }
        return max(0, Int(ms.rounded()))
    }

    static func providerAddr(net: NetInfo) async -> String? {
        let now = Date()
        if let h = cacheGet(net.key), h.ip != nil || now.timeIntervalSince(h.at) < 30 { return h.ip }
        guard let tr = await Shell.run("/usr/sbin/traceroute", ["-n", "-m", "5", "-q", "1", "-w", "1", "-i", net.iface, "1.1.1.1"], timeout: 4.5)
        else { return nil }
        let ip = NetParse.firstPublicHop(tr, gateway: net.gateway)
        if !Task.isCancelled { cacheSet(net.key, ip, now) }
        return ip
    }

    static func providerPing(net: NetInfo) async -> (String?, Int?) {
        guard let ip = await providerAddr(net: net) else { return (nil, nil) }
        return (ip, await ping(ip, iface: net.iface))
    }

    static func lookupInterface(_ name: String) async -> NWInterface? {
        await withCheckedContinuation { (c: CheckedContinuation<NWInterface?, Never>) in
            let m = NWPathMonitor()
            let q = DispatchQueue(label: "vpnmonitor.iflookup")
            let once = Once()
            m.pathUpdateHandler = { path in
                guard once.take() else { return }
                m.cancel()
                c.resume(returning: path.availableInterfaces.first { $0.name == name })
            }
            m.start(queue: q)
            q.asyncAfter(deadline: .now() + 0.8) {
                guard once.take() else { return }
                m.cancel()
                c.resume(returning: nil)
            }
        }
    }

    static func tcpOnce(host: String, port: UInt16, iface: NWInterface?, kind: String, timeout: Double) async -> Double? {
        let params = NWParameters.tcp
        if let i = iface { params.requiredInterface = i }
        else if kind == "wifi" { params.requiredInterfaceType = .wifi }
        else if kind == "ethernet" { params.requiredInterfaceType = .wiredEthernet }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
        let q = DispatchQueue(label: "vpnmonitor.tcpprobe")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Double?, Never>) in
                let once = Once()
                let t0 = DispatchTime.now()
                conn.stateUpdateHandler = { st in
                    switch st {
                    case .ready:
                        guard once.take() else { return }
                        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
                        conn.cancel()
                        c.resume(returning: ms)
                    case .failed, .cancelled:
                        guard once.take() else { return }
                        conn.cancel()
                        c.resume(returning: nil)
                    default: break
                    }
                }
                conn.start(queue: q)
                q.asyncAfter(deadline: .now() + timeout) {
                    guard once.take() else { return }
                    conn.cancel()
                    c.resume(returning: nil)
                }
            }
        } onCancel: { conn.cancel() }
    }

    static func vpsTCP(net: NetInfo, exit: ExitInfo) async -> Int? {
        let iface = await lookupInterface(net.iface)
        var v: [Double] = []
        for _ in 0..<3 {
            if Task.isCancelled { break }
            if let ms = await tcpOnce(host: exit.host, port: exit.port, iface: iface, kind: net.kind, timeout: 1.3) { v.append(ms) }
        }
        guard !v.isEmpty else { return nil }
        v.sort()
        return Int(v[v.count / 2].rounded())
    }

    static func measure(client: CoreClient, tunnelUp: Bool, mobile: Bool, exitTag: String? = nil) async -> RouteInput {
        let exit = exitTag.map(ExitCatalog.info) ?? ExitCatalog.fallback
        let box = PartialBox(RouteInput(mobile: mobile, tunnelUp: tunnelUp, exitTag: exitTag))
        let work = Task {
            guard let net = await detect() else { return }
            box.update { $0.netName = net.name; $0.gateway = net.gateway; $0.netNote = net.kind }
            await withTaskGroup(of: Void.self) { g in
                g.addTask {
                    let ms = await ping(net.gateway, iface: net.iface)
                    box.update { $0.routerMs = ms }
                }
                g.addTask {
                    async let traced = providerPing(net: net)
                    async let viaCore: Int? = {
                        guard tunnelUp else { return nil }
                        _ = try? await client.delay(timeoutMs: 2500, url: AppConfig.shared.localSites[0], proxy: "direct")
                        return try? await client.delay(timeoutMs: 2500, url: AppConfig.shared.localSites[0], proxy: "direct")
                    }()
                    var (ip, ms) = await traced
                    let fallback = await viaCore
                    var viaHTTPS = false
                    if ms == nil, let d = fallback {
                        ip = AppConfig.shared.localHost; ms = d; viaHTTPS = true
                    }
                    box.update { $0.providerAddr = ip; $0.providerMs = ms; $0.providerViaHTTPS = viaHTTPS }
                }
                g.addTask {
                    let ms = await vpsTCP(net: net, exit: exit)
                    box.update { $0.vpsMs = ms }
                }
                if tunnelUp {
                    g.addTask {
                        let ms = try? await client.delay(timeoutMs: 4000, url: siteURL)
                        box.update { $0.siteMs = ms }
                    }
                    g.addTask {
                        let ms = try? await client.delay(timeoutMs: 4000)
                        box.update { $0.gstaticMs = ms }
                    }
                }
            }
        }
        let guardTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            work.cancel()
        }
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
            guardTask.cancel()
        }
        guardTask.cancel()
        return box.value
    }
}

final class PartialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: RouteInput
    init(_ v: RouteInput) { self.v = v }
    var value: RouteInput { lock.lock(); defer { lock.unlock() }; return v }
    func update(_ f: (inout RouteInput) -> Void) { lock.lock(); f(&v); lock.unlock() }
}
