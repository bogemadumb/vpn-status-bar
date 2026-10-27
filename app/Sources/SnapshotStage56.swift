#if !CLIENT_EDITION
import SwiftUI
import AppKit

@MainActor
enum Stage56Snapshot {
    static func seedDB() -> HistoryDB? {
        guard let db = HistoryDB(path: ":memory:") else { return nil }
        let now = Date()
        let t = Int(now.timeIntervalSince1970)
        let dropStart = t - 40 * 60
        for i in stride(from: 3 * 3600, to: 0, by: -10) {
            let ts = t - i
            let x = Double(ts % 100000)
            var down = 150_000 + 120_000 * abs(sin(x / 400)) + 40_000 * abs(sin(x / 37))
            if ts % 1800 < 300 { down += 1_800_000 * abs(sin(x / 90)) }
            let up = 20_000 + 25_000 * abs(sin(x / 150))
            let inDrop = ts >= dropStart && ts < dropStart + 120
            db.insertSample(ts: Date(timeIntervalSince1970: Double(ts)), down: inDrop ? 0 : down, up: inDrop ? 0 : up,
                            delay: inDrop ? nil : 55 + Int(20 * abs(sin(x / 300))), state: inDrop ? "down" : "ok")
        }
        for i in stride(from: 30 * 86400, to: 3 * 3600, by: -300) {
            let ts = t - i
            let x = Double(ts % 1_000_000)
            let day = Double((ts / 3600) % 24)
            let busy = day > 8 && day < 23 ? 1.0 : 0.15
            let ok = ts % (86400 * 9) > 3600
            db.insertSample(ts: Date(timeIntervalSince1970: Double(ts)), down: ok ? busy * (200_000 + 500_000 * abs(sin(x / 5000))) : 0,
                            up: ok ? busy * 40_000 : 0, delay: ok ? 60 + Int(15 * abs(sin(x / 900))) : nil, state: ok ? "ok" : "down")
        }
        let day = DayKey.of(now)
        db.addTraffic(day: day, [
            TrafficDelta(process: "Safari", via: "vps", down: 1_240_000_000, up: 40_000_000),
            TrafficDelta(process: "Safari", via: "direct", down: 180_000_000, up: 9_000_000),
            TrafficDelta(process: "claude", via: "vps", down: 410_000_000, up: 95_000_000),
            TrafficDelta(process: "Telegram", via: "vps", down: 220_000_000, up: 60_000_000),
            TrafficDelta(process: "Telegram", via: "direct", down: 30_000_000, up: 4_000_000),
            TrafficDelta(process: "Google Chrome Helper", via: "vps", down: 150_000_000, up: 12_000_000),
            TrafficDelta(process: "curl", via: "direct", down: 52_000_000, up: 1_000_000),
            TrafficDelta(process: "Spotify", via: "vps", down: 48_000_000, up: 2_000_000),
            TrafficDelta(process: "—", via: "vps", down: 22_000_000, up: 2_000_000),
        ])
        let d = now.addingTimeInterval(-40 * 60)
        db.insertEvent(start: now.addingTimeInterval(-26 * 3600), end: now.addingTimeInterval(-26 * 3600 + 540), kind: "net", detail: "сменилась сеть, туннель не удержался")
        db.insertEvent(start: now.addingTimeInterval(-20 * 3600), end: now.addingTimeInterval(-20 * 3600), kind: "speed", detail: "14,2 МБ/с · 25 МБ за 1,8 с")
        db.insertEvent(start: d, end: d.addingTimeInterval(125), kind: "server", detail: "сервер недоступен: туннель не отвечает")
        db.insertEvent(start: d.addingTimeInterval(10), end: d.addingTimeInterval(10), kind: "watchdog", detail: "ядро не отвечало 63 с, перезапуск (попытка 1 из 3)")
        db.insertEvent(start: now.addingTimeInterval(-2 * 3600), end: now.addingTimeInterval(-2 * 3600), kind: "leak", detail: "Утечка IPv6: утечка: RU · 2a00:1fa0::1")
        return db
    }

    static func demo(db: HistoryDB?, state: VPNState = .ok) -> VPNModel {
        let m = VPNModel(live: false)
        m.preview(state: state, delay: 68)
        m.obs.db = db
        m.guardian.preview(killActive: true, attempts: 1, lastAction: "ядро не отвечало 63 с, перезапуск (попытка 1 из 3)")
        m.checks.apply(LeakLogic.evaluate(LeakFetches(
            geo: .response(status: 200, body: "ip=203.0.113.10\nloc=FI\n"), ipv6: .failed("x"),
            dns: .response(status: 200, body: "ip=203.0.113.10\nloc=FI\n"),
            local: .response(status: 302, body: ""), external: .response(status: 200, body: "")), mode: "Rule"))
        m.speed.preview(.done(14.2))
        return m
    }

    static func run(dir: String) {
        StateLog.enabled = false
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let win = CGSize(width: 1100, height: 720)
        let psize = CGSize(width: 360, height: PanelBody.panelHeight)
        let m = demo(db: seedDB())
        Task { await m.obs.refresh() }
        Snapshot.spin(1.5)
        print("demo events=\(m.obs.events.count) apps=\(m.obs.apps.count) buckets=\(m.obs.buckets.compactMap { $0 }.count) today=\(Int(m.obs.todayVPS + m.obs.todayDirect))")
        let empty = demo(db: HistoryDB(path: ":memory:"))
        Task { await empty.obs.refresh() }
        Snapshot.spin(0.8)
        let bad = demo(db: seedDB())
        bad.checks.apply(LeakLogic.evaluate(LeakFetches(
            geo: .response(status: 200, body: "ip=198.51.100.68\nloc=RU\n"), ipv6: .response(status: 200, body: "ip=2a00::1\nloc=RU\n"),
            dns: .response(status: 200, body: "ip=203.0.113.10\nloc=FI\n"),
            local: .response(status: 302, body: ""), external: .failed("timeout")), mode: "Rule"))
        bad.guardian.preview(killActive: false, attempts: 3, lastAction: "3 попытки за 10 минут не помогли, дальше только уведомление")
        Task { await bad.obs.refresh() }
        Snapshot.spin(1.2)
        for (name, dark) in [("dark", true), ("light", false)] {
            Stage34Snapshot.renderHosted(PanelView().environmentObject(m), size: psize, dark: dark, to: "\(dir)/panel-\(name).png")
            m.section = .overview
            Stage34Snapshot.renderHosted(WindowView(fixedSize: CGSize(width: 1100, height: 1180), scrollable: false).environmentObject(m), size: CGSize(width: 1100, height: 1180), dark: dark, to: "\(dir)/overview-\(name).png")
            m.section = .log
            Stage34Snapshot.renderHosted(WindowView(scrollable: false).environmentObject(m), size: win, dark: dark, to: "\(dir)/journal-\(name).png")
            empty.section = .log
            Stage34Snapshot.renderHosted(WindowView(scrollable: false).environmentObject(empty), size: win, dark: dark, to: "\(dir)/journal-empty-\(name).png")
            m.section = .settings
            Stage34Snapshot.renderHosted(WindowView(scrollable: false).environmentObject(m), size: win, dark: dark, to: "\(dir)/settings-\(name).png")
        }
        bad.section = .overview
        Stage34Snapshot.renderHosted(PanelView().environmentObject(bad), size: psize, dark: true, to: "\(dir)/panel-leak-dark.png")
        Stage34Snapshot.renderHosted(WindowView(fixedSize: CGSize(width: 1100, height: 1180), scrollable: false).environmentObject(bad), size: CGSize(width: 1100, height: 1180), dark: true, to: "\(dir)/overview-leak-dark.png")
        m.section = .overview
        for r in [ChartRange.day, ChartRange.month] {
            m.obs.setRange(r)
            Snapshot.spin(1.0)
            Stage34Snapshot.renderHosted(WindowView(fixedSize: CGSize(width: 1100, height: 1180), scrollable: false).environmentObject(m), size: CGSize(width: 1100, height: 1180), dark: false, to: "\(dir)/overview-\(r.rawValue)-light.png")
        }
        let off = VPNModel(live: false)
        off.preview(state: .off, delay: nil)
        off.checks.skip("VPN выключен")
        Stage34Snapshot.renderHosted(PanelView().environmentObject(off), size: psize, dark: true, to: "\(dir)/panel-off-dark.png")
        let pIdeal = Snapshot.fitting(PanelView(fixedWidth: nil).injectModels(m).environment(\.colorScheme, .dark))
        let pFit = Snapshot.fitting(PanelView().environmentObject(m).environment(\.colorScheme, .dark))
        print("panel fitting \(Int(pFit.width))x\(Int(pFit.height)) ideal-width \(Int(pIdeal.width)) height-budget \(Int(PanelBody.panelHeight))")
        exit(0)
    }
}
#endif
