import Foundation
import SwiftUI

@MainActor
final class Guardian: ObservableObject {
    static let intentKey = "intentOn"
    static let killKey = "killSwitchEnabled"

    @Published private(set) var intentOn = true
    @Published private(set) var killSwitchEnabled = !Edition.isClient
    @Published private(set) var killSwitchActive = false
    @Published private(set) var lastAction: String?
    @Published private(set) var attemptsUsed = 0

    let live: Bool
    let db: HistoryDB?
    private var watchdog = Watchdog()
    private var drops = DropTracker()
    private var dropEvent: Int64 = 0
    private var intentKnown = false
    private var lastNet: String?
    private var lastNetChange = Date.distantPast
    private var ksBusy = false
    private var lastKSCheck = Date.distantPast
    private var lastKSWant: Bool?
    private var actionBusy = false

    init(live: Bool, db: HistoryDB?) {
        self.live = live
        self.db = db
        if let v = UserDefaults.standard.object(forKey: Self.killKey) as? Bool { killSwitchEnabled = v }
        if let v = UserDefaults.standard.object(forKey: Self.intentKey) as? Bool { intentOn = v; intentKnown = true }
        if live { db?.closeStaleDrops(at: Date()) }
    }

    func preview(killActive: Bool, attempts: Int, lastAction: String?) {
        killSwitchActive = killActive
        attemptsUsed = attempts
        self.lastAction = lastAction
    }

    func setIntent(_ on: Bool) {
        guard intentOn != on || !intentKnown else { return }
        intentKnown = true
        intentOn = on
        if live { UserDefaults.standard.set(on, forKey: Self.intentKey) }
        StateLog.write("intent=\(on ? "on" : "off")")
    }

    func setKillSwitch(_ on: Bool) {
        guard killSwitchEnabled != on else { return }
        killSwitchEnabled = on
        if live { UserDefaults.standard.set(on, forKey: Self.killKey) }
        StateLog.write("killswitch setting=\(on ? "on" : "off")")
        reconcileKillSwitch(force: true)
    }

    func noteNetwork(_ label: String) {
        if let l = lastNet, l != label { lastNetChange = Date() }
        lastNet = label
    }

    func observe(daemonRunning: Bool, disabled: Bool, apiOK: Bool, busy: Bool, state: VPNState,
                 outageSince: Date?, now: Date = Date()) {
        guard live else { return }
        if !intentKnown {
            setIntent(IntentSync.initial(stored: nil, daemonRunning: daemonRunning))
        }
        if let v = UserDefaults.standard.object(forKey: Self.killKey) as? Bool, v != killSwitchEnabled {
            killSwitchEnabled = v
            StateLog.write("killswitch setting changed externally=\(v ? "on" : "off")")
        }
        let synced = IntentSync.next(current: intentOn, daemonRunning: daemonRunning, daemonDisabled: disabled, busy: busy)
        if synced != intentOn { setIntent(synced) }

        if !busy && !actionBusy {
            let act = watchdog.evaluate(intentOn: intentOn, daemonRunning: daemonRunning, apiOK: apiOK, at: now)
            let used = watchdog.attemptsInWindow(at: now)
            if attemptsUsed != used { attemptsUsed = used }
            if act != .none { perform(act, downFor: watchdog.lastDownFor) }
        }

        updateDrops(daemonRunning: daemonRunning, apiOK: apiOK, busy: busy, state: state, outageSince: outageSince, now: now)
        reconcileKillSwitch(force: false)
    }

    private func perform(_ act: WatchdogAction, downFor: TimeInterval) {
        let n = attemptsUsed
        switch act {
        case .restart, .start:
            let what = act == .restart ? "ядро не отвечало \(Int(downFor)) с, перезапуск" : "ядро не работало, запуск"
            let detail = "\(what) (попытка \(n) из \(Watchdog.maxAttempts))"
            lastAction = detail
            StateLog.write("watchdog action=\(act == .restart ? "restart" : "start") down_for=\(Int(downFor)) attempt=\(n)")
            db?.insertEvent(start: Date(), end: Date(), kind: "watchdog", detail: detail)
            Notifier.shared.post(kind: "watchdog", title: "Сторож перезапустил VPN", body: detail)
            actionBusy = true
            let arg = act == .restart ? "restart" : "on"
            Task { [weak self] in
                await Task.detached { DaemonProbe.control(arg) }.value
                guard let self = self else { return }
                self.actionBusy = false
                self.reconcileKillSwitch(force: true)
            }
        case .giveUp:
            let detail = "\(Watchdog.maxAttempts) попытки за 10 минут не помогли, дальше только уведомление"
            lastAction = detail
            StateLog.write("watchdog action=giveup")
            db?.insertEvent(start: Date(), end: Date(), kind: "watchdog", detail: detail)
            Notifier.shared.post(kind: "giveup", title: "VPN не поднимается", body: "\(detail). Откройте окно VPN или выключите его вручную.")
        case .none: break
        }
    }

    private func updateDrops(daemonRunning: Bool, apiOK: Bool, busy: Bool, state: VPNState, outageSince: Date?, now: Date) {
        let coreGone = intentOn && !daemonRunning && !busy
        let isDrop = state == .down || coreGone
        let recovered = (daemonRunning && (state == .ok || state == .slow)) || !intentOn
        guard let change = drops.update(isDrop: isDrop, recovered: recovered,
                                        startHint: state == .down ? outageSince : nil, at: now) else { return }
        switch change {
        case .opened(let start):
            let r = DropReason.classify(daemonRunning: daemonRunning, apiOK: apiOK,
                                        netChangedRecently: now.timeIntervalSince(lastNetChange) < 180)
            dropEvent = db?.insertEvent(start: start, end: nil, kind: r.kind, detail: r.detail) ?? 0
            StateLog.write("drop opened kind=\(r.kind)")
            Notifier.shared.post(kind: "down", title: "VPN: связь с туннелем потеряна", body: r.detail.prefix(1).uppercased() + r.detail.dropFirst())
        case .closed(let start, let end):
            if dropEvent != 0 { db?.closeEvent(id: dropEvent, end: end) }
            dropEvent = 0
            let len = end.timeIntervalSince(start)
            StateLog.write("drop closed seconds=\(Int(len))")
            Notifier.shared.post(kind: "restored", title: "VPN: связь восстановлена", body: "Обрыв длился \(Format.span(len))")
        }
    }

    var dropOpen: Bool { drops.openSince != nil }

    func recordLeak(_ detail: String) {
        StateLog.write("leak detected \(detail)")
        db?.insertEvent(start: Date(), end: Date(), kind: "leak", detail: detail)
        Notifier.shared.post(kind: "leak", title: "VPN: обнаружена утечка", body: detail)
    }

    func recordSpeed(mbps: Double, bytes: Double, seconds: Double) {
        let detail = "\(SpeedMath.format(mbps)) МБ/с · \(Format.bytes(bytes)) за \(SpeedMath.format(seconds)) с"
        db?.insertEvent(start: Date(), end: Date(), kind: "speed", detail: detail)
    }

    func reconcileKillSwitch(force: Bool) {
        guard live, !ksBusy else { return }
        let want = killSwitchEnabled && intentOn
        if !force && lastKSWant == want && Date().timeIntervalSince(lastKSCheck) < 15 { return }
        lastKSCheck = Date()
        lastKSWant = want
        ksBusy = true
        Task { [weak self] in
            let (cur, after) = await Task.detached { () -> (Bool?, Bool?) in
                let c = KillSwitchCtl.status()
                guard let c = c, c != want else { return (c, c) }
                let ok = KillSwitchCtl.set(want)
                return (c, ok ? want : c)
            }.value
            guard let self = self else { return }
            self.ksBusy = false
            if let cur = cur, cur != want { StateLog.write("killswitch \(cur ? "on" : "off") -> \(after.map { $0 ? "on" : "off" } ?? "?")") }
            if cur == nil { StateLog.write("killswitch status unavailable") }
            if self.killSwitchActive != (after ?? false) { self.killSwitchActive = after ?? false }
        }
    }

    func recordSample(down: Double, up: Double, delay: Int?, state: VPNState) {
        guard live else { return }
        let s = dropOpen ? "down" : "\(state)"
        db?.insertSample(ts: Date(), down: down, up: up, delay: delay, state: s)
    }
}

@MainActor
final class ChecksModel: ObservableObject {
    @Published private(set) var items = LeakLogic.pending()
    @Published private(set) var running = false
    @Published private(set) var lastRun: Date?
    @Published private(set) var verdict = LeakVerdict(leak: false, detail: "")
    var onLeak: ((String) -> Void)?
    private var wasLeak = false

    var chips: [Chip] { LeakLogic.chips(items) }
    var externalAddress: String? { LeakLogic.externalAddress(items) }

    func run(mode: String) async {
        guard !running else { return }
        running = true
        let result = await LeakProbe.run(mode: mode)
        apply(result)
        running = false
    }

    func apply(_ result: [CheckItem]) {
        items = result
        lastRun = Date()
        verdict = LeakLogic.verdict(result)
        StateLog.write("checks " + result.map { "\($0.id)=\($0.status.rawValue)(\($0.text))" }.joined(separator: " "))
        if verdict.leak && !wasLeak { onLeak?(verdict.detail) }
        wasLeak = verdict.leak
    }

    func skip(_ reason: String) {
        guard items.contains(where: { $0.status != .skipped || $0.text != reason }) else { return }
        items = LeakLogic.skipped(reason)
        wasLeak = false
    }
}

@MainActor
final class SpeedModel: ObservableObject {
    enum Phase: Equatable {
        case idle, running(Double), done(Double), failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var finishedAt: Date?
    var onResult: ((Double, Double, Double) -> Void)?

    func preview(_ p: Phase) { phase = p; finishedAt = Date() }

    var isRunning: Bool { if case .running = phase { return true } else { return false } }

    func start() {
        guard !isRunning else { return }
        phase = .running(0)
        let tester = SpeedTester()
        Task { [weak self] in
            let r = await tester.run { [weak self] bytes, secs in
                let v = SpeedMath.mbps(bytes: bytes, seconds: secs)
                Task { @MainActor in
                    if self?.isRunning == true { self?.phase = .running(v) }
                }
            }
            guard let self = self else { return }
            self.finishedAt = Date()
            if let r = r {
                let v = SpeedMath.mbps(bytes: r.bytes, seconds: r.seconds)
                self.phase = .done(v)
                StateLog.write("speedtest mbps=\(SpeedMath.format(v)) bytes=\(Int(r.bytes)) seconds=\(String(format: "%.2f", r.seconds))")
                self.onResult?(v, r.bytes, r.seconds)
            } else {
                self.phase = .failed
                StateLog.write("speedtest failed")
            }
        }
    }
}

@MainActor
final class ObsModel: ObservableObject {
    var db: HistoryDB?
    @Published var range: ChartRange = .hour
    @Published private(set) var buckets: [Bucket?] = []
    @Published private(set) var events: [EventRow] = []
    @Published private(set) var apps: [AppRow] = []
    @Published private(set) var todayVPS = 0.0
    @Published private(set) var todayDirect = 0.0
    @Published private(set) var avgDelay: Int?

    func setRange(_ r: ChartRange) {
        range = r
        Task { await refresh() }
    }

    func refresh() async {
        guard let db = db else { return }
        let r = range
        let now = Date()
        let day = DayKey.of(now)
        let out = await Task.detached {
            (db.series(r, now: now), db.events(limit: 300), db.trafficRows(day: day, limit: 8),
             db.trafficTotals(day: day), db.averageDelay(since: now.addingTimeInterval(-3600)))
        }.value
        buckets = out.0
        events = out.1
        apps = out.2
        todayVPS = out.3.vps
        todayDirect = out.3.direct
        avgDelay = out.4.map { Int($0.rounded()) }
    }
}
