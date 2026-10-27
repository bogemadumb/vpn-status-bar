import Foundation
import UserNotifications

enum Runtime {
    nonisolated(unsafe) static var live = false
}

enum KillSwitchCtl {
    static let path = "/usr/local/libexec/vpn-ctl"

    static func status() -> Bool? {
        let r = DaemonProbe.run("/usr/bin/sudo", ["-n", path, "killswitch", "status"])
        if r.out.contains("killswitch: on") { return true }
        if r.out.contains("killswitch: off") { return false }
        return nil
    }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        let r = DaemonProbe.run("/usr/bin/sudo", ["-n", path, "killswitch", on ? "on" : "off"])
        return r.status == 0
    }
}

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate, ObservableObject {
    static let shared = Notifier()
    @Published private(set) var authText = "не запрошено"
    private var limiter = RateLimiter()

    func start() {
        guard Runtime.live, Bundle.main.bundleIdentifier != nil else { return }
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { granted, err in
            StateLog.write("notify auth granted=\(granted) err=\(err.map { "\($0)" } ?? "none")")
            Task { @MainActor in self.refreshAuth() }
        }
    }

    func refreshAuth() {
        guard Runtime.live, Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let text: String
            switch s.authorizationStatus {
            case .authorized, .provisional, .ephemeral: text = "разрешены"
            case .denied: text = "запрещены в Системных настройках"
            default: text = "ещё не разрешены"
            }
            Task { @MainActor in self.authText = text }
        }
    }

    func post(kind: String, title: String, body: String, interval: TimeInterval? = nil) {
        guard Runtime.live, Bundle.main.bundleIdentifier != nil else {
            StateLog.write("notify skip kind=\(kind) not-live")
            return
        }
        guard limiter.allow(kind, at: Date(), interval: interval) else {
            StateLog.write("notify rate-limited kind=\(kind)")
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            guard s.authorizationStatus == .authorized || s.authorizationStatus == .provisional else {
                StateLog.write("notify no-op kind=\(kind) auth=\(s.authorizationStatus.rawValue)")
                return
            }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            c.sound = .default
            let req = UNNotificationRequest(identifier: "vpn-\(kind)-\(Int(Date().timeIntervalSince1970))", content: c, trigger: nil)
            UNUserNotificationCenter.current().add(req) { err in
                StateLog.write("notify sent kind=\(kind) err=\(err.map { "\($0)" } ?? "none")")
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

enum LeakProbe {
    static func session(timeout: TimeInterval) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout + 2
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }

    static func trace(_ url: String, timeout: TimeInterval = 8) async -> Fetch {
        guard let u = URL(string: url) else { return .failed("bad url") }
        do {
            let (data, resp) = try await session(timeout: timeout).data(from: u)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return .response(status: code, body: String(data: data, encoding: .utf8) ?? "")
        } catch { return .failed("\((error as NSError).code)") }
    }

    static func site(_ url: String, timeout: TimeInterval = 8) async -> Fetch {
        guard let u = URL(string: url) else { return .failed("bad url") }
        var r = URLRequest(url: u)
        r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        do {
            let (_, resp) = try await session(timeout: timeout).bytes(for: r)
            return .response(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: "")
        } catch { return .failed("\((error as NSError).code)") }
    }

    static func bestSite(_ urls: [String]) async -> Fetch {
        var first: Fetch?
        for u in urls {
            let r = await site(u)
            if case .response(let s, _) = r, s > 0, s < 500 { return r }
            if first == nil { first = r }
        }
        return first ?? .failed("no sites")
    }

    static func once() async -> LeakFetches {
        async let geo = trace("https://\(AppConfig.shared.traceHost)/cdn-cgi/trace")
        async let v6 = trace("https://[2606:4700:4700::1111]/cdn-cgi/trace")
        async let dns = trace("https://1.1.1.1/cdn-cgi/trace")
        async let local = bestSite(AppConfig.shared.localSites)
        async let external = bestSite(AppConfig.shared.externalSites)
        return await LeakFetches(geo: geo, ipv6: v6, dns: dns, local: local, external: external)
    }

    static func run(mode: String) async -> [CheckItem] {
        var f = await once()
        var items = LeakLogic.evaluate(f, mode: mode)
        let retry = items.filter { $0.status == .fail || $0.status == .warn }.map { $0.id }
        if !retry.isEmpty {
            let again = await once()
            if retry.contains("geo") { f.geo = again.geo }
            if retry.contains("dns") { f.dns = again.dns }
            if retry.contains("local") { f.local = again.local }
            if retry.contains("external") { f.external = again.external }
            if retry.contains("ipv6") { f.ipv6 = again.ipv6 }
            items = LeakLogic.evaluate(f, mode: mode)
        }
        return items
    }
}

final class SpeedTester: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let url = "https://speed.cloudflare.com/__down?bytes=25000000"
    private var received = 0.0
    private var started = Date()
    private var lastReport = Date.distantPast
    private var cont: CheckedContinuation<(bytes: Double, seconds: Double)?, Never>?
    private var progress: (@Sendable (Double, Double) -> Void)?
    private var session: URLSession?

    func run(progress: @escaping @Sendable (Double, Double) -> Void) async -> (bytes: Double, seconds: Double)? {
        self.progress = progress
        return await withCheckedContinuation { c in
            cont = c
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 15
            cfg.timeoutIntervalForResource = 45
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            session = s
            started = Date()
            s.dataTask(with: URL(string: Self.url)!).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += Double(data.count)
        let now = Date()
        if now.timeIntervalSince(lastReport) >= 0.25 {
            lastReport = now
            progress?(received, now.timeIntervalSince(started))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let secs = Date().timeIntervalSince(started)
        let ok = error == nil && received > 1_000_000
        session.finishTasksAndInvalidate()
        cont?.resume(returning: ok ? (received, secs) : nil)
        cont = nil
    }
}
