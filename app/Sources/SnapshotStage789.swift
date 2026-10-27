#if !CLIENT_EDITION
import SwiftUI
import AppKit

@MainActor
enum Stage789Snapshot {
    static func run(dir: String) {
        StateLog.enabled = false
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        HotKey.registered = true
        let win = CGSize(width: 1100, height: 720)
        let tall = CGSize(width: 1100, height: 1500)
        let psize = CGSize(width: 360, height: PanelBody.panelHeight)

        let m = Stage56Snapshot.demo(db: Stage56Snapshot.seedDB())
        m.server.live = true
        Task { await m.obs.refresh(); await m.server.refreshHealth(force: true); await m.server.refreshKeys(force: true) }
        Snapshot.spin(7)
        print("server health=\(m.server.health != nil) err=\(m.server.healthError ?? "-") keys=\(m.server.keys.map { $0.name }) keysErr=\(m.server.keysError ?? "-")")

        let live = VPNModel()
        var waited = 0.0
        while waited < 15 && (live.state == .connecting || live.delayMs == nil && live.state != .off) { Snapshot.spin(0.5); waited += 0.5 }
        Snapshot.spin(2)
        live.rules.reload()
        Task { await live.conns.poll() }
        Snapshot.spin(2.3)
        Task { await live.conns.poll() }
        Snapshot.spin(1)
        print("live state=\(live.state) conns=\(live.conns.rows.count)")

        for (name, dark) in [("dark", true), ("light", false)] {
            Stage34Snapshot.renderHosted(PanelView().environmentObject(m), size: psize, dark: dark, to: "\(dir)/panel-\(name).png")
            m.section = .overview
            Stage34Snapshot.renderHosted(WindowView(fixedSize: tall, scrollable: false).environmentObject(m), size: tall, dark: dark, to: "\(dir)/overview-\(name).png")
            live.section = .connections
            Stage34Snapshot.renderHosted(WindowView(scrollable: true).environmentObject(live), size: win, dark: dark, to: "\(dir)/connections-\(name).png")
            live.section = .rules
            Stage34Snapshot.renderHosted(WindowView(scrollable: true).environmentObject(live), size: win, dark: dark, to: "\(dir)/rules-\(name).png")
            m.section = .keys
            Stage34Snapshot.renderHosted(WindowView(scrollable: false).environmentObject(m), size: win, dark: dark, to: "\(dir)/keys-\(name).png")
            Stage34Snapshot.renderHosted(WindowView(fixedSize: CGSize(width: 960, height: 720), scrollable: false).environmentObject(m), size: CGSize(width: 960, height: 720), dark: dark, to: "\(dir)/keys-narrow-\(name).png")
            m.section = .log
            Stage34Snapshot.renderHosted(WindowView(scrollable: false).environmentObject(m), size: win, dark: dark, to: "\(dir)/journal-\(name).png")
            m.section = .settings
            Stage34Snapshot.renderHosted(WindowView(fixedSize: CGSize(width: 1100, height: 1000), scrollable: false).environmentObject(m), size: CGSize(width: 1100, height: 1000), dark: dark, to: "\(dir)/settings-\(name).png")
            Stage34Snapshot.renderHosted(ThemedRoot { QRSheet(name: "Телефон", link: "vless://example", onClose: {}) }.environmentObject(m),
                                         size: CGSize(width: 460, height: 520), dark: dark, to: "\(dir)/qr-sheet-\(name).png")
        }

        live.routeShown = true
        live.measureRoute()
        var w = 0.0
        while live.route.measuring && w < 9 { Snapshot.spin(0.25); w += 0.25 }
        for (name, dark) in [("dark", true), ("light", false)] {
            Stage34Snapshot.renderHosted(PanelView().environmentObject(live), size: psize, dark: dark, to: "\(dir)/route-\(name).png")
        }
        live.routeShown = false

        let off = Stage56Snapshot.demo(db: nil, state: .down)
        off.server.preview(health: nil, keys: [])
        off.section = .overview
        Stage34Snapshot.renderHosted(WindowView(fixedSize: tall, scrollable: false).environmentObject(off), size: tall, dark: true, to: "\(dir)/overview-noserver-dark.png")
        exit(0)
    }
}
#endif
