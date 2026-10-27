import Foundation
import AppKit

enum SiteRule {
    static func forHost(_ host: String) -> (kind: RuleKind, value: String)? {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        if h.isEmpty { return nil }
        if let c = RuleDetect.cidr(h) { return (.ipCidr, c) }
        return (.domainSuffix, h.hasPrefix("www.") && h.count > 4 ? String(h.dropFirst(4)) : h)
    }
}

enum BrowserURL {
    enum Result: Equatable {
        case url(String)
        case noBrowser
        case denied
        case empty
    }

    private static let scripts: [(bundle: String, source: String)] = [
        ("com.apple.Safari", "tell application \"Safari\" to get URL of current tab of front window"),
        ("com.google.Chrome", "tell application \"Google Chrome\" to get URL of active tab of front window"),
    ]

    private static func exec(_ source: String) -> (value: String?, code: Int?) {
        var err: NSDictionary?
        guard let s = NSAppleScript(source: source) else { return (nil, nil) }
        let r = s.executeAndReturnError(&err)
        if let e = err { return (nil, (e[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1) }
        return (r.stringValue, nil)
    }

    static func front() -> Result {
        var any = false, denied = false
        for (bundle, source) in scripts where !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty {
            any = true
            let r = exec(source)
            if let v = r.value, !v.isEmpty { return .url(v) }
            if r.code == -1743 { denied = true }
        }
        if !any { return .noBrowser }
        return denied ? .denied : .empty
    }
}

@MainActor
final class RulesModel: ObservableObject {
    let files: RuleFiles
    @Published private(set) var user: [UserRule] = []
    @Published private(set) var alwaysVps: [String] = []
    @Published var toast: String?
    @Published var siteNote: String?
    @Published private(set) var busyBrowser = false

    init(files: RuleFiles = RuleFiles()) { self.files = files }

    func reload() {
        user = files.load()
        alwaysVps = files.alwaysVps()
    }

    func say(_ text: String) {
        toast = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if self?.toast == text { self?.toast = nil }
        }
    }

    @discardableResult
    func add(kind: RuleKind, value: String, target: RuleTarget) -> Bool {
        do {
            try files.add(value, kind: kind, target: target)
            reload()
            return true
        } catch {
            say("Не удалось записать правило: \(error.localizedDescription)")
            return false
        }
    }

    func remove(_ r: UserRule) {
        do {
            try files.remove(r)
            reload()
        } catch {
            say("Не удалось удалить правило")
        }
    }

    func addCurrentSite() {
        guard !busyBrowser else { return }
        busyBrowser = true
        Task { [weak self] in
            let r = await withCheckedContinuation { (c: CheckedContinuation<BrowserURL.Result, Never>) in
                DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: BrowserURL.front()) }
            }
            guard let self = self else { return }
            self.busyBrowser = false
            switch r {
            case .url(let u):
                guard let host = RuleDetect.hostFromURL(u), let rule = SiteRule.forHost(host) else {
                    self.flash("В браузере нет открытого сайта")
                    return
                }
                if self.files.find(rule.kind, rule.value) == .direct { self.flash("\(rule.value) уже напрямую"); return }
                if self.add(kind: rule.kind, value: rule.value, target: .direct) { self.flash("\(rule.value) — теперь напрямую") }
            case .noBrowser: self.flash("Открой сайт в Safari или Chrome")
            case .denied: self.flash("Нет доступа: Настройки → Конфиденциальность → Автоматизация")
            case .empty: self.flash("В браузере нет открытого сайта")
            }
        }
    }

    private func flash(_ text: String) {
        siteNote = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self?.siteNote == text { self?.siteNote = nil }
        }
    }
}

enum ConnFilter: CaseIterable {
    case all, vps, direct, local

    var label: String {
        switch self {
        case .all: return "Все"
        case .vps: return "Через VPS"
        case .direct: return "Напрямую"
        case .local: return "Локально"
        }
    }

    func matches(_ r: ConnRoute) -> Bool {
        switch self {
        case .all: return true
        case .vps: return r == .vps
        case .direct: return r == .direct
        case .local: return r == .local
        }
    }
}

struct ConnRow: Identifiable, Equatable {
    let id: String
    let app: String
    let host: String
    let rawHost: String
    let destIP: String
    let route: ConnRoute
    let ruleText: String
    let speed: Double
    let started: Date?
    var exit: String? = nil

    var exitLabel: String? { exit.map { ExitCatalog.info($0).short } }

    var searchText: String { "\(app) \(host) \(destIP) \(ruleText) \(route.label) \(exitLabel ?? "")".lowercased() }
}

@MainActor
final class ConnectionsModel: ObservableObject {
    @Published private(set) var rows: [ConnRow] = []
    @Published private(set) var failed = false
    @Published var filter: ConnFilter = .all
    @Published var search = ""

    var isActive: () -> Bool = { true }
    private let client: CoreClient
    private let rules: RulesModel
    private var prev: [String: (bytes: Double, at: Date)] = [:]

    init(client: CoreClient, rules: RulesModel) {
        self.client = client
        self.rules = rules
    }

    func count(_ f: ConnFilter) -> Int { rows.filter { f.matches($0.route) }.count }

    var visible: [ConnRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return rows.filter { filter.matches($0.route) && (q.isEmpty || $0.searchText.contains(q)) }
    }

    func run() async {
        while !Task.isCancelled {
            if isActive() {
                await poll()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            } else {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func poll() async {
        let raw: [RawConn]
        do { raw = try await client.connections() } catch {
            failed = true
            return
        }
        failed = false
        let now = Date()
        var next: [String: (bytes: Double, at: Date)] = [:]
        var out: [ConnRow] = []
        for c in raw {
            let total = c.download + c.upload
            next[c.id] = (total, now)
            var speed = 0.0
            if let p = prev[c.id] {
                let dt = now.timeIntervalSince(p.at)
                if dt > 0.2 { speed = max(0, (total - p.bytes) / dt) }
            } else if let st = c.start {
                speed = total / max(1, now.timeIntervalSince(st))
            }
            let name = ConnLogic.processName(c.processPath)
            out.append(ConnRow(
                id: c.id,
                app: name.isEmpty ? "—" : name,
                host: ConnLogic.hostName(host: c.host, ip: c.destIP, port: c.destPort),
                rawHost: c.host,
                destIP: c.destIP,
                route: ConnLogic.route(chains: c.chains, rule: c.rule, destIP: c.destIP),
                ruleText: ConnLogic.humanRule(c.rule),
                speed: speed,
                started: c.start,
                exit: ConnLogic.exitTag(chains: c.chains)))
        }
        prev = next
        out.sort { ($0.started ?? .distantPast) > ($1.started ?? .distantPast) }
        rows = out
    }

    func drop(_ r: ConnRow) {
        Task { [weak self] in
            guard let self = self else { return }
            do { try await self.client.closeConnection(r.id) } catch { self.rules.say("Не удалось оборвать соединение") }
            await self.poll()
        }
    }

    func ruleForSite(_ r: ConnRow, _ target: RuleTarget) {
        let h = r.rawHost.isEmpty ? r.destIP : r.rawHost
        guard let rule = SiteRule.forHost(h) else { return }
        if rules.add(kind: rule.kind, value: rule.value, target: target) {
            rules.say("\(rule.value) — \(target.label). Действует на новые соединения")
        }
    }

    func ruleForApp(_ r: ConnRow, _ target: RuleTarget) {
        guard r.app != "—" else { return }
        if rules.add(kind: .processName, value: r.app, target: target) {
            rules.say("\(r.app) — \(target.label). Действует на новые соединения")
        }
    }

    func preview(_ list: [ConnRow]) { rows = list }
}

@MainActor
final class RouteModel: ObservableObject {
    @Published private(set) var input: RouteInput?
    @Published private(set) var measuredAt: Date?
    @Published private(set) var measuring = false
    private var task: Task<Void, Never>?

    var analysis: (hops: [Hop], verdict: RouteVerdict)? { input.map(RouteAnalysis.analyze) }

    func start(client: CoreClient, tunnelUp: Bool, mobile: Bool, exitTag: String? = nil) {
        task?.cancel()
        measuring = true
        task = Task { [weak self] in
            let r = await RouteProbe.measure(client: client, tunnelUp: tunnelUp, mobile: mobile, exitTag: exitTag)
            guard let self = self, !Task.isCancelled else { return }
            self.input = r
            self.measuredAt = Date()
            self.measuring = false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        measuring = false
    }

    func preview(_ i: RouteInput, ago: TimeInterval = 12, measuring: Bool = false) {
        input = i
        measuredAt = Date().addingTimeInterval(-ago)
        self.measuring = measuring
    }
}
