#if !CLIENT_EDITION
import SwiftUI
import AppKit

@MainActor
enum Stage34Snapshot {
    static func renderHosted<V: View>(_ view: V, size: CGSize, dark: Bool, to path: String) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        Snapshot.spin(0.6)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("rep failed"); return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)px")
        }
    }

    static var slowProvider: RouteInput {
        RouteInput(netName: "Wi-Fi · iPhone, раздача", mobile: true, gateway: "172.20.10.1",
                   routerMs: 12, providerMs: 95, providerAddr: "100.64.12.1", vpsMs: 112, siteMs: 140, gstaticMs: 118,
                   tunnelUp: true)
    }

    static func run(dir: String) {
        StateLog.enabled = false
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let model = VPNModel()
        var waited = 0.0
        while waited < 15 && (model.state == .connecting || model.delayMs == nil && model.state != .off) {
            Snapshot.spin(0.5); waited += 0.5
        }
        Snapshot.spin(3)
        model.rules.reload()
        Task { await model.conns.poll() }
        Snapshot.spin(2.3)
        Task { await model.conns.poll() }
        Snapshot.spin(1)
        print("state=\(model.state) mode=\(model.mode) conns=\(model.conns.rows.count) vps=\(model.conns.count(.vps)) direct=\(model.conns.count(.direct)) local=\(model.conns.count(.local))")

        let win = CGSize(width: 1100, height: 720)
        for (name, dark) in [("dark", true), ("light", false)] {
            model.section = .connections
            renderHosted(WindowView(scrollable: true).environmentObject(model), size: win, dark: dark, to: "\(dir)/window-connections-\(name).png")
            model.section = .rules
            renderHosted(WindowView(scrollable: true).environmentObject(model), size: win, dark: dark, to: "\(dir)/window-rules-\(name).png")
        }
        model.section = .overview

        model.routeShown = true
        model.measureRoute()
        var w = 0.0
        while model.route.measuring && w < 9 { Snapshot.spin(0.25); w += 0.25 }
        print("route measuring_wait=\(w) s")
        if let a = model.route.analysis {
            for h in a.hops { print("  \(h.name) | \(h.sub) | \(h.ms.map(String.init) ?? "-") | +\(h.delta.map(String.init) ?? "-") | \(h.status)") }
            print("  verdict: \(a.verdict.title)")
        }
        let psize = CGSize(width: 360, height: PanelBody.panelHeight)
        for (name, dark) in [("dark", true), ("light", false)] {
            renderHosted(PanelView().environmentObject(model), size: psize, dark: dark, to: "\(dir)/panel-route-live-\(name).png")
        }
        model.routeShown = false
        for (name, dark) in [("dark", true), ("light", false)] {
            renderHosted(PanelView().environmentObject(model), size: psize, dark: dark, to: "\(dir)/panel-main-\(name).png")
        }

        let slow = VPNModel(live: false)
        slow.preview(state: .slow, delay: 140, expensive: true)
        slow.route.preview(slowProvider, ago: 12)
        slow.routeShown = true
        for (name, dark) in [("dark", true), ("light", false)] {
            renderHosted(PanelView().environmentObject(slow), size: psize, dark: dark, to: "\(dir)/panel-route-slow-\(name).png")
        }
        let measuring = VPNModel(live: false)
        measuring.preview(state: .ok, delay: 68)
        measuring.routeShown = true
        measuring.route.preview(RouteInput(), measuring: true)
        renderHosted(PanelView().environmentObject(measuring), size: psize, dark: true, to: "\(dir)/panel-route-measuring-dark.png")
        let direct = VPNModel(live: false)
        direct.preview(state: .ok, delay: 68, mode: "Direct")
        renderHosted(PanelView().environmentObject(direct), size: psize, dark: true, to: "\(dir)/panel-direct-dark.png")
        exit(0)
    }
}
#endif
