import SwiftUI
import AppKit

struct VPNApp: App {
    @StateObject private var model = VPNModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(model)
        } label: {
            ShieldLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("VPN", id: "main") {
            WindowView().environmentObject(model)
        }
        .defaultSize(width: 1100, height: 720)
        .windowStyle(.hiddenTitleBar)
    }
}

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        setvbuf(stdout, nil, _IOLBF, 0)
        #if !CLIENT_EDITION
        if adminCommand(args) { return }
        #endif
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dir = args[i + 1]
            MainActor.assumeIsolated { Snapshot.run(dir: dir) }
        } else if args.contains("--open-window") {
            DistributedNotificationCenter.default().postNotificationName(MainWindow.notification, object: nil, userInfo: nil, deliverImmediately: true)
        } else if args.contains("--probe-route") {
            CLI.probeRoute()
        } else if args.contains("--probe-conns") {
            CLI.probeConns()
        } else if let i = args.firstIndex(of: "--test-mode"), i + 1 < args.count {
            CLI.mode(args[i + 1])
        } else if let i = args.firstIndex(of: "--test-add-direct"), i + 1 < args.count {
            CLI.addDirect(args[i + 1])
        } else if let i = args.firstIndex(of: "--test-add"), i + 2 < args.count {
            CLI.rule(add: true, args[i + 1], args[i + 2])
        } else if let i = args.firstIndex(of: "--test-remove"), i + 2 < args.count {
            CLI.rule(add: false, args[i + 1], args[i + 2])
        } else if let i = args.firstIndex(of: "--traffic-probe"), i + 1 < args.count, let n = Int(args[i + 1]) {
            TrafficProbe.run(seconds: n)
        } else if args.contains("--probe-leaks") {
            CLI.probeLeaks()
        } else if args.contains("--notify-status") {
            CLI.notifyStatus()
        } else if args.contains("--speedtest") {
            CLI.speedTest()
        } else {
            Runtime.live = true
            VPNApp.main()
        }
    }

    #if !CLIENT_EDITION
    static func adminCommand(_ args: [String]) -> Bool {
        if let i = args.firstIndex(of: "--snapshot-stage34"), i + 1 < args.count {
            let dir = args[i + 1]
            MainActor.assumeIsolated { Stage34Snapshot.run(dir: dir) }
        } else if let i = args.firstIndex(of: "--snapshot-stage56"), i + 1 < args.count {
            let dir = args[i + 1]
            MainActor.assumeIsolated { Stage56Snapshot.run(dir: dir) }
        } else if let i = args.firstIndex(of: "--snapshot-stage789"), i + 1 < args.count {
            let dir = args[i + 1]
            MainActor.assumeIsolated { Stage789Snapshot.run(dir: dir) }
        } else if args.contains("--test-keys") {
            CLI.testKeys()
        } else if let i = args.firstIndex(of: "--test-key-cycle"), i + 1 < args.count {
            CLI.testKeyCycle(args[i + 1])
        } else {
            return false
        }
        return true
    }
    #endif
}

@MainActor
enum Snapshot {
    static func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func render<V: View>(_ view: V, size: CGSize?, to path: String) {
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let s = size { r.proposedSize = ProposedViewSize(s) }
        guard let img = r.cgImage else { print("render failed: \(path)"); return }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(img.width)x\(img.height)px")
    }

    static func fitting<V: View>(_ view: V) -> CGSize {
        let host = NSHostingView(rootView: view)
        return host.fittingSize
    }

    static func renderIcons(to path: String) {
        let states: [VPNState] = [.ok, .slow, .degraded, .down, .connecting, .off]
        let scale: CGFloat = 4, cell = CGSize(width: 44, height: 34)
        let wPx = Int(cell.width * CGFloat(states.count) * scale), hPx = Int(cell.height * 2 * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: wPx, pixelsHigh: hPx, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: scale, y: scale)
        let rows: [(NSAppearance.Name, NSColor)] = [
            (.aqua, NSColor(srgbRed: 0xE6 / 255, green: 0xE4 / 255, blue: 0xE0 / 255, alpha: 1)),
            (.darkAqua, NSColor(srgbRed: 0x23 / 255, green: 0x23 / 255, blue: 0x26 / 255, alpha: 1))]
        for (r, row) in rows.enumerated() {
            let ap = NSAppearance(named: row.0)!
            let y = CGFloat(1 - r) * cell.height
            row.1.setFill()
            NSRect(x: 0, y: y, width: cell.width * CGFloat(states.count), height: cell.height).fill()
            for (i, st) in states.enumerated() {
                let img = ShieldIcon.draw(state: st)
                ap.performAsCurrentDrawingAppearance {
                    img.draw(in: NSRect(x: CGFloat(i) * cell.width + 13, y: y + 8, width: 18, height: 18))
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) \(wPx)x\(hPx)px")
        }
    }

    static func run(dir: String) {
        StateLog.enabled = false
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        renderIcons(to: "\(dir)/icons.png")
        let model = VPNModel()
        var waited = 0.0
        while waited < 15 && (model.state == .connecting || model.delayMs == nil && model.state != .off) {
            spin(0.5); waited += 0.5
        }
        spin(6)
        print("state=\(model.state) daemon=\(model.daemonRunning) api=\(model.apiOK) mode=\(model.mode) delay=\(model.delayMs.map(String.init) ?? "nil") down=\(Int(model.downBps)) up=\(Int(model.upBps)) samples=\(model.downHistory.count) version=\(model.singboxVersion ?? "nil") since=\(model.connectedSince.map { "\($0)" } ?? "nil") inter=\(Fonts.hasInter)")

        for (name, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
            render(PanelView().environmentObject(model).environment(\.colorScheme, scheme),
                   size: nil, to: "\(dir)/panel-\(name).png")
            render(WindowView(scrollable: false).environmentObject(model).environment(\.colorScheme, scheme),
                   size: CGSize(width: 1100, height: 720), to: "\(dir)/window-\(name).png")
        }
        #if !CLIENT_EDITION
        model.section = .keys
        render(WindowView(scrollable: false).environmentObject(model).environment(\.colorScheme, .light),
               size: CGSize(width: 1100, height: 720), to: "\(dir)/window-keys-light.png")
        #endif
        model.section = .overview
        model.confirmingOff = true
        spin(0.4)
        render(PanelView().environmentObject(model).environment(\.colorScheme, .dark),
               size: nil, to: "\(dir)/panel-confirm-dark.png")
        render(WindowView(scrollable: false).environmentObject(model).environment(\.colorScheme, .dark),
               size: CGSize(width: 1100, height: 720), to: "\(dir)/window-confirm-dark.png")
        model.confirmingOff = false

        let variants: [(String, VPNState, Int?, Bool, Int, String)] = [
            ("ok", .ok, 68, false, 0, "Rule"), ("ok-mobile", .ok, 71, true, 0, "Global"),
            ("slow", .slow, 780, false, 0, "Rule"), ("degraded", .degraded, nil, false, 0, "Rule"),
            ("down", .down, nil, false, 4, "Rule"), ("off", .off, nil, false, 0, "Rule")]
        for (name, st, d, exp, mins, mode) in variants {
            let m = VPNModel(live: false)
            m.preview(state: st, delay: d, expensive: exp, outageMinutes: mins, mode: mode)
            for (sn, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
                render(PanelView().environmentObject(m).environment(\.colorScheme, scheme),
                       size: nil, to: "\(dir)/panel-\(name)-\(sn).png")
            }
            if ["slow", "down", "ok"].contains(name) {
                render(WindowView(scrollable: false).environmentObject(m).environment(\.colorScheme, name == "slow" ? .light : .dark),
                       size: CGSize(width: 1100, height: 720), to: "\(dir)/window-\(name).png")
            }
        }

        let pFit = fitting(PanelView().environmentObject(model))
        let pIdeal = fitting(PanelView(fixedWidth: nil).environmentObject(model))
        print("panel: fitting \(Int(pFit.width))x\(Int(pFit.height)) frame-width 360; ideal-unconstrained-width \(Int(pIdeal.width)) (must be <= 360)")
        let wIdeal = fitting(WindowView(fixedSize: nil).environmentObject(model))
        let detailIdeal = fitting(OverviewContent().injectModels(model).environment(\.theme, .dark).padding(EdgeInsets(top: 38, leading: 32, bottom: 40, trailing: 32)))
        print("window: ideal-unconstrained \(Int(wIdeal.width))x\(Int(wIdeal.height)); overview content ideal \(Int(detailIdeal.width))x\(Int(detailIdeal.height)) vs available 880x720 (must be <=)")
        exit(0)
    }
}

enum TrafficProbe {
    static func run(seconds: Int) {
        StateLog.enabled = false
        let client = CoreClient()
        let stamp = { String(format: "%.3f", Date().timeIntervalSince1970) }
        let done = DispatchSemaphore(value: 0)
        let task = Task {
            await client.runTraffic { e in
                if case .sample(let up, let down) = e { print("S \(stamp()) \(Int(up)) \(Int(down))") }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds)) { task.cancel(); done.signal() }
        done.wait()
        exit(0)
    }
}
