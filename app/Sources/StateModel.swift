import Foundation
import Darwin
import SwiftUI

extension VPNState {
    var title: String {
        switch self {
        case .ok: return "Всё открывается"
        case .slow: return "Медленно, но работает"
        case .degraded: return "Работает с перебоями"
        case .down: return "Сервер недоступен"
        case .off: return "VPN выключен"
        case .connecting: return "Подключаюсь…"
        }
    }
}

enum DaemonProbe {
    static let label = "system/" + Edition.daemonLabel

    static func run(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func readDisabled() -> Bool {
        IntentSync.isDisabled(run("/bin/launchctl", ["print-disabled", "system"]).out, label: Edition.daemonLabel)
    }

    static func read() -> (running: Bool, started: Date?) {
        let r = run("/bin/launchctl", ["print", label])
        guard r.status == 0 else { return (false, nil) }
        var running = false
        var pid: Int32?
        for raw in r.out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "state = running" { running = true }
            if line.hasPrefix("pid = "), let n = Int32(line.dropFirst(6)) { pid = n }
        }
        guard running else { return (false, nil) }
        var started: Date?
        if let pid = pid {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            if sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 {
                let tv = info.kp_proc.p_un.__p_starttime
                started = Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
            }
        }
        return (true, started)
    }

    static func control(_ arg: String) {
        _ = run("/usr/bin/sudo", ["-n", "/usr/local/libexec/vpn-ctl", arg])
    }
}

@MainActor
final class TrafficModel: ObservableObject {
    private(set) var downBps: Double = 0
    private(set) var upBps: Double = 0
    private(set) var downHistory: [Double] = []
    private(set) var upHistory: [Double] = []
    private(set) var sessionDown: Double = 0
    private(set) var sessionUp: Double = 0
    private var shown: Set<String> = []

    var active: Bool { !shown.isEmpty }

    func setVisible(_ key: String, _ on: Bool) {
        let was = active
        if shown.contains(key) != on { StateLog.write("ui \(key)=\(on ? 1 : 0)") }
        if on { shown.insert(key) } else { shown.remove(key) }
        if active && !was { objectWillChange.send() }
    }

    func push(up: Double, down: Double, limit: Int) {
        upBps = up
        downBps = down
        upHistory.append(up)
        downHistory.append(down)
        let extra = downHistory.count - limit
        if extra > 0 {
            downHistory.removeFirst(extra)
            upHistory.removeFirst(extra)
        }
        notify()
    }

    func reset() {
        upBps = 0
        downBps = 0
        notify()
    }

    func setSession(down: Double, up: Double) {
        sessionDown = down
        sessionUp = up
        notify()
    }

    func setPreview(down: [Double], up: [Double]) {
        downHistory = down
        upHistory = up
        downBps = down.last ?? 0
        upBps = up.last ?? 0
    }

    private func notify() { if active { objectWillChange.send() } }
}

struct TrafficReader<Content: View>: View {
    @EnvironmentObject private var traffic: TrafficModel
    let content: (TrafficModel) -> Content
    init(@ViewBuilder _ content: @escaping (TrafficModel) -> Content) { self.content = content }
    var body: some View { content(traffic) }
}

struct VisibilityProbe: NSViewRepresentable {
    let onChange: (Bool) -> Void

    final class Probe: NSView {
        var onChange: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []

        private func report(_ closing: Bool = false) {
            let vis = !closing && (window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false)
            onChange?(vis)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
            tokens = []
            guard let w = window else { report(); return }
            let nc = NotificationCenter.default
            for n in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                tokens.append(nc.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            tokens.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report(true) }
            })
            report()
        }

        deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
    }

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ v: Probe, context: Context) { v.onChange = onChange }
}

extension View {
    func trackVisibility(_ traffic: TrafficModel, _ key: String) -> some View {
        background(VisibilityProbe { traffic.setVisible(key, $0) })
    }
}

@MainActor
final class VPNModel: ObservableObject {
    @Published private(set) var state: VPNState = .connecting
    @Published private(set) var daemonRunning = false
    @Published private(set) var apiOK = false
    @Published private(set) var mode = "Rule"
    @Published private(set) var delayMs: Int?
    @Published private(set) var isExpensive = false
    @Published private(set) var outageSince: Date?
    @Published private(set) var connectedSince: Date?
    @Published private(set) var singboxVersion: String?
    @Published private(set) var apiError: String?
    @Published private(set) var busy = false
    @Published var confirmingOff = false
    @Published var section: WindowSection = .overview
    @Published var routeShown = false
    @Published private(set) var now = Date()

    nonisolated static let historyLimit = 300

    let traffic = TrafficModel()
    var downBps: Double { traffic.downBps }
    var upBps: Double { traffic.upBps }
    var downHistory: [Double] { traffic.downHistory }
    var upHistory: [Double] { traffic.upHistory }
    var sessionDown: Double { traffic.sessionDown }
    var sessionUp: Double { traffic.sessionUp }

    let client = CoreClient()
    let guardian: Guardian
    let checks = ChecksModel()
    let speed = SpeedModel()
    let obs = ObsModel()
    #if !CLIENT_EDITION
    let server: ServerModel
    #endif
    let rules = RulesModel()
    let route = RouteModel()
    let exits = ExitModel()
    lazy var conns: ConnectionsModel = {
        let m = ConnectionsModel(client: client, rules: rules)
        m.isActive = { [weak self] in self?.traffic.active ?? false }
        return m
    }()
    private var machine = StateMachine()
    private var loaded = false
    private var daemonStarted: Date?
    private var tasks: [Task<Void, Never>] = []
    private var probeNudge = false
    private var netLabel = "none"
    private var netWatch: NetworkWatch?
    private var totalsBase: (down: Double, up: Double) = (0, 0)
    private var totalsAcc: (down: Double, up: Double) = (0, 0)
    private var daemonDisabled = false
    private var tracker = TrafficTracker()
    private var checksNudge = false
    private var checksWaitStart = Date()

    init(live: Bool = true) {
        let db = live && Runtime.live ? HistoryDB(path: HistoryDB.defaultPath) : nil
        guardian = Guardian(live: live && Runtime.live, db: db)
        obs.db = db
        exits.db = db
        #if !CLIENT_EDITION
        server = ServerModel(live: live && Runtime.live)
        #endif
        if live { start() }
    }

    func start() {
        guard tasks.isEmpty else { return }
        let watch = NetworkWatch { [weak self] expensive, label in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if self.isExpensive != expensive || self.netLabel != label {
                    self.isExpensive = expensive
                    self.netLabel = label
                    RouteProbe.invalidateCache()
                    self.guardian.noteNetwork(label)
                    StateLog.write("net=\(label) expensive=\(expensive ? 1 : 0)")
                }
            }
        }
        watch.start()
        netWatch = watch
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                await self.refreshDaemon()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                await self.probe()
                var waited = 0.0
                let target = self.machine.wantsFastProbe ? 5.0 : 15.0
                while waited < target && !self.probeNudge {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    waited += 0.5
                }
                self.probeNudge = false
            }
        })
        tasks.append(Task { [weak self] in
            guard let self = self else { return }
            await self.client.runTraffic { event in
                Task { @MainActor [weak self] in self?.handle(event) }
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self?.now = Date()
            }
        })
        guard Runtime.live else { return }
        Notifier.shared.start()
        checks.onLeak = { [weak self] d in self?.guardian.recordLeak(d) }
        speed.onResult = { [weak self] v, b, s in self?.guardian.recordSpeed(mbps: v, bytes: b, seconds: s) }
        checksWaitStart = Date()
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                self?.recordSample()
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.pollTraffic()
            }
        })
        tasks.append(Task { [weak self] in
            var pruned = Date.distantPast
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self = self else { return }
                if Date().timeIntervalSince(pruned) > 3600, let db = self.guardian.db {
                    pruned = Date()
                    Task.detached { db.prune(now: Date()) }
                }
                await self.checksTick()
            }
        })
    }

    private func recordSample() {
        guard loaded else { return }
        let n = min(10, downHistory.count)
        let d = n > 0 ? downHistory.suffix(n).reduce(0, +) / Double(n) : 0
        let u = n > 0 ? upHistory.suffix(n).reduce(0, +) / Double(n) : 0
        guardian.recordSample(down: d, up: u, delay: delayMs, state: state)
    }

    private func pollTraffic() async {
        guard daemonRunning, apiOK, let db = guardian.db, let list = try? await client.connections() else { return }
        let snaps = list.compactMap { c -> ConnSnap? in
            let route = ConnLogic.route(chains: c.chains, rule: c.rule, destIP: c.destIP)
            guard route != .block else { return nil }
            let name = ConnLogic.processName(c.processPath)
            return ConnSnap(id: c.id, process: name.isEmpty ? "—" : name, via: route.rawValue, down: c.download, up: c.upload)
        }
        let deltas = tracker.update(snaps)
        guard !deltas.isEmpty else { return }
        let day = DayKey.of(Date())
        Task.detached { db.addTraffic(day: day, deltas) }
    }

    private func checksTick() async {
        guard loaded else { return }
        if !daemonRunning { checks.skip("VPN выключен"); checksNudge = true; return }
        guard apiOK, state != .connecting, !checks.running else { return }
        let first = checks.lastRun == nil && Date().timeIntervalSince(checksWaitStart) > 12
        let due = checks.lastRun.map { Date().timeIntervalSince($0) >= 300 } ?? false
        if first || due || checksNudge {
            checksNudge = false
            await checks.run(mode: mode)
        }
    }

    func runChecksNow() {
        guard daemonRunning, !checks.running else { return }
        Task { [weak self] in
            guard let self = self else { return }
            await self.checks.run(mode: self.mode)
        }
    }

    func syncGuardian() {
        guardian.observe(daemonRunning: daemonRunning, disabled: daemonDisabled, apiOK: apiOK, busy: busy,
                         state: state, outageSince: outageSince)
    }

    private func handle(_ e: TrafficEvent) {
        switch e {
        case .connected:
            totalsAcc = (0, 0)
            Task { [weak self] in
                guard let self = self else { return }
                if let t = try? await self.client.totals() {
                    self.totalsBase = t
                    self.syncTotals()
                }
            }
        case .sample(let up, let down):
            traffic.push(up: up, down: down, limit: Self.historyLimit)
            totalsAcc.down += down
            totalsAcc.up += up
            syncTotals()
        case .disconnected:
            traffic.reset()
            totalsBase = (0, 0)
            totalsAcc = (0, 0)
            syncTotals()
        }
    }

    private func syncTotals() {
        traffic.setSession(down: totalsBase.down + totalsAcc.down, up: totalsBase.up + totalsAcc.up)
    }

    func refreshDaemon() async {
        let r = await Task.detached { () -> (running: Bool, started: Date?, disabled: Bool) in
            let x = DaemonProbe.read()
            return (x.running, x.started, x.running ? false : DaemonProbe.readDisabled())
        }.value
        let was = daemonRunning
        if daemonRunning != r.running { daemonRunning = r.running }
        daemonDisabled = r.disabled
        daemonStarted = r.started
        loaded = true
        if !r.running {
            if apiOK { apiOK = false }
            if delayMs != nil { delayMs = nil }
            if connectedSince != nil { connectedSince = nil }
            feed(api: false, delay: nil)
        } else if !was {
            probeNudge = true
        }
        syncGuardian()
    }

    func probe() async {
        guard loaded else { return }
        guard daemonRunning else { exits.reset(); feed(api: false, delay: nil); return }
        var api = false
        do {
            let v = try await client.version()
            let c = try await client.configs()
            if singboxVersion != v { singboxVersion = v }
            if mode != c.mode { mode = c.mode }
            api = true
            if apiError != nil { apiError = nil }
        } catch {
            let msg: String?
            if !client.hasSecret { msg = "нет ключа в Keychain" }
            else if case CoreError.http(401) = error { msg = "ключ не подходит" }
            else { msg = nil }
            if apiError != msg { apiError = msg }
        }
        if api { await exits.refresh(client: client, visible: traffic.active) } else { exits.reset() }
        var d: Int?
        if api {
            d = try? await client.delay(timeoutMs: isExpensive ? 10_000 : 5_000)
        }
        feed(api: api, delay: d)
        syncGuardian()
    }

    private func feed(api: Bool, delay: Int?) {
        guard loaded else { return }
        let before = machine.state
        if apiOK != api { apiOK = api }
        machine.tick(daemonRunning: daemonRunning, apiOK: api, delayMs: delay, at: Date(), isExpensive: isExpensive)
        var newDelay = self.delayMs
        if !api { newDelay = nil }
        else if let d = delay { newDelay = d }
        else if machine.failStreak >= 2 { newDelay = nil }
        if newDelay != self.delayMs { self.delayMs = newDelay }
        let next = machine.state
        if next != state { state = next }
        if outageSince != machine.outageSince { outageSince = machine.outageSince }
        if daemonRunning && (next == .ok || next == .slow) && connectedSince == nil {
            connectedSince = daemonStarted ?? Date()
        }
        guard next != .off || before != .off else { return }
        var line = "state=\(next) daemon=\(daemonRunning ? 1 : 0) api=\(api ? 1 : 0) delay=\(delay.map(String.init) ?? "fail") fails=\(machine.failStreak) exp=\(isExpensive ? 1 : 0) net=\(netLabel) down=\(Int(downBps)) up=\(Int(upBps))"
        if before != next { line += " transition=\(before)->\(next)" }
        StateLog.write(line)
    }

    func toggle() {
        if busy { return }
        if daemonRunning {
            confirmingOff = true
        } else {
            runControl("on")
        }
    }

    func confirmOff() {
        confirmingOff = false
        guardian.setIntent(false)
        runControl("off")
    }

    func cancelOff() { confirmingOff = false }

    func setMode(_ m: String) {
        guard apiOK, mode != m else { return }
        let old = mode
        mode = m
        Task { [weak self] in
            guard let self = self else { return }
            do { try await self.client.setMode(m) } catch { self.mode = old }
        }
    }

    var directHint: Bool { mode == "Direct" }

    func showRoute() {
        routeShown = true
        measureRoute()
    }

    func hideRoute() {
        routeShown = false
        route.cancel()
    }

    func measureRoute() {
        route.start(client: client, tunnelUp: daemonRunning && apiOK, mobile: isExpensive, exitTag: exits.active?.tag)
    }

    private func runControl(_ arg: String) {
        busy = true
        if arg == "on" { state = .connecting; guardian.setIntent(true) }
        Task { [weak self] in
            await Task.detached { DaemonProbe.control(arg) }.value
            guard let self = self else { return }
            await self.refreshDaemon()
            self.busy = false
            self.guardian.reconcileKillSwitch(force: true)
        }
    }

    var modeName: String {
        switch mode {
        case "Rule": return "умный режим"
        case "Global": return "всё через VPS"
        case "Direct": return "напрямую"
        default: return mode
        }
    }

    var modeShort: String {
        switch mode {
        case "Rule": return "умный"
        case "Global": return "всё через VPS"
        case "Direct": return "напрямую"
        default: return mode
        }
    }

    var modeIndex: Int {
        switch mode {
        case "Global": return 1
        case "Direct": return 2
        default: return 0
        }
    }

    var stateDetail: String? {
        switch state {
        case .slow: return delayMs.map { "медленно: пинг \($0) мс" } ?? "медленно"
        case .degraded: return "связь неустойчива"
        case .down:
            let since = outageSince ?? now
            return "нет связи с сервером \(Format.duration(now.timeIntervalSince(since)))"
        default: return nil
        }
    }

    var subtitle: String {
        var s: String
        switch state {
        case .ok:
            if let c = connectedSince {
                s = "подключено \(Format.duration(now.timeIntervalSince(c))) · \(modeName)"
            } else {
                s = modeName
            }
        case .slow, .degraded, .down: s = stateDetail ?? ""
        case .off: return "туннель остановлен"
        case .connecting: s = apiError ?? "запускаю туннель"
        }
        if isExpensive { s += " · мобильная сеть" }
        return s
    }

    func preview(state: VPNState, delay: Int?, expensive: Bool = false, outageMinutes: Int = 0,
                 history: Bool = true, mode: String = "Rule") {
        self.state = state
        self.delayMs = delay
        self.isExpensive = expensive
        self.mode = mode
        self.daemonRunning = state != .off
        self.apiOK = state != .off && state != .down
        self.now = Date()
        self.connectedSince = Date().addingTimeInterval(-(3 * 3600 + 25 * 60))
        self.outageSince = outageMinutes > 0 ? Date().addingTimeInterval(-Double(outageMinutes) * 60) : nil
        self.singboxVersion = "sing-box 1.14.0"
        traffic.setSession(down: 3.4e9, up: 1.2e8)
        guard history else { return }
        var d: [Double] = [], u: [Double] = []
        for i in 0..<Self.historyLimit {
            let x = Double(i)
            var dv = 90_000 + 60_000 * sin(x / 9) + 40_000 * sin(x / 3.1)
            if i > 120 && i < 175 { dv += 1_050_000 * sin(Double(i - 120) / 55 * .pi) + 90_000 * sin(x * 1.7) }
            var uv = 12_000 + 9_000 * sin(x / 5)
            if i > 130 && i < 160 { uv += 160_000 * sin(Double(i - 130) / 30 * .pi) }
            if state == .down && i > 250 { dv = 0; uv = 0 }
            d.append(max(0, dv)); u.append(max(0, uv))
        }
        traffic.setPreview(down: d, up: u)
    }
}

enum Format {
    static func duration(_ sec: TimeInterval) -> String {
        let m = max(0, Int(sec / 60))
        if m < 1 { return "меньше минуты" }
        let d = m / 1440, h = (m % 1440) / 60, mm = m % 60
        if d > 0 { return "\(d) д \(h) ч" }
        if h > 0 { return "\(h) ч \(mm) мин" }
        return "\(mm) мин"
    }

    static func span(_ sec: TimeInterval) -> String {
        let s = max(0, Int(sec.rounded()))
        if s < 60 { return "\(s) с" }
        if s < 3600 { return s % 60 == 0 || s >= 600 ? "\(s / 60) мин" : "\(s / 60) мин \(s % 60) с" }
        return "\(s / 3600) ч \((s % 3600) / 60) мин"
    }

    static func rate(_ bps: Double) -> (value: String, unit: String) {
        if bps >= 100_000 {
            return (String(format: "%.1f", bps / 1_000_000).replacingOccurrences(of: ".", with: ","), "МБ/с")
        }
        return (String(Int((bps / 1000).rounded())), "КБ/с")
    }

    static func axis(_ bps: Double) -> String {
        if bps >= 1_000_000 {
            return String(format: "%.1f МБ/с", bps / 1_000_000).replacingOccurrences(of: ".", with: ",")
        }
        return "\(Int((bps / 1000).rounded())) КБ/с"
    }

    static func bytes(_ b: Double) -> String {
        let units = ["Б", "КБ", "МБ", "ГБ", "ТБ"]
        var v = b, i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        let f = i == 0 ? String(Int(v)) : String(format: v < 10 ? "%.1f" : "%.0f", v).replacingOccurrences(of: ".", with: ",")
        return "\(f) \(units[i])"
    }

    static func ping(_ ms: Int?) -> (value: String, unit: String) {
        guard let ms = ms else { return ("—", "") }
        return (String(ms), "мс")
    }
}
