import SwiftUI
import AppKit

final class WindowRef {
    weak var window: NSWindow?
}

struct WindowGrabber: NSViewRepresentable {
    let ref: WindowRef
    var onAppear: () -> Void = {}

    final class Probe: NSView {
        var ref: WindowRef?
        var onAppear: () -> Void = {}
        private var obs: NSKeyValueObservation?
        private var clickMonitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            ref?.window = w
            if clickMonitor == nil {
                clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak w] event in
                    if let w, event.window === w, !w.isKeyWindow {
                        NSApp.activate(ignoringOtherApps: true)
                        w.makeKey()
                    }
                    return event
                }
            }
            obs = w.observe(\.isVisible, options: [.initial, .new]) { [weak self] win, _ in
                guard win.isVisible else { return }
                DispatchQueue.main.async { self?.onAppear() }
            }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.ref = ref
        v.onAppear = onAppear
        return v
    }

    func updateNSView(_ v: Probe, context: Context) {}
}

struct PanelView: View {
    @EnvironmentObject private var model: VPNModel
    var fixedWidth: CGFloat? = 360
    var body: some View {
        ThemedRoot { PanelBody(fixedWidth: fixedWidth) }
            .injectModels(model)
    }
}

struct PowerButton: View {
    @EnvironmentObject private var model: VPNModel
    @Environment(\.theme) private var t
    var size: CGFloat = 128
    var iconSize: CGFloat = 46
    var ringWidth: CGFloat = 2
    var halo = true
    @State private var pulse = false

    var body: some View {
        let c = t.stateColor(model.state)
        let connecting = model.state == .connecting
        ZStack {
            if halo {
                Circle()
                    .stroke(c.opacity(0.07), lineWidth: size * 0.078)
                    .frame(width: size * 1.078, height: size * 1.078)
                    .scaleEffect(connecting && pulse ? 1.07 : 1)
                    .opacity(connecting && pulse ? 0.4 : 1)
            }
            Button { model.toggle() } label: {
                ZStack {
                    Circle().fill(t.bg)
                    Circle().fill(c.opacity(t.isDark ? 0.12 : 0.10))
                    Circle().strokeBorder(c, lineWidth: ringWidth)
                    Image(systemName: "power")
                        .font(.system(size: iconSize, weight: .medium))
                        .foregroundColor(c)
                }
                .frame(width: size, height: size)
                .shadow(color: c.opacity(model.state == .off ? 0 : (t.isDark ? 0.22 : 0.16)), radius: size * 0.19)
            }
            .buttonStyle(PressStyle())
            .disabled(model.busy)
        }
        .frame(width: halo ? size * 1.078 : size, height: halo ? size * 1.078 : size)
        .animation(connecting ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                              : .easeOut(duration: 0.35), value: pulse)
        .animation(.easeOut(duration: 0.35), value: model.state)
        .onAppear { pulse = connecting }
        .onChange(of: connecting) { pulse = $0 }
        .help(model.state == .off ? "Включить VPN" : "Выключить VPN")
    }
}

struct PanelBody: View {
    @EnvironmentObject private var model: VPNModel
    @EnvironmentObject private var guardian: Guardian
    @EnvironmentObject private var speed: SpeedModel
    @EnvironmentObject private var exits: ExitModel
    @Environment(\.theme) private var t
    @Environment(\.openWindow) private var openWindow
    var fixedWidth: CGFloat?
    @State private var panelRef = WindowRef()

    private func activatePanel() {
        if model.routeShown { model.hideRoute() }
        for d in [0.0, 0.15] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                NSApp.activate(ignoringOtherApps: true)
                panelRef.window?.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func openMain(_ section: WindowSection) {
        model.section = section
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        let panel = panelRef.window
        func front(_ tries: Int) {
            let main = NSApp.windows.first { $0 !== panel && $0.title == "VPN" && !($0 is NSPanel) }
            if let w = main {
                panel?.orderOut(nil)
                w.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else if tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { front(tries - 1) }
            } else {
                panel?.orderOut(nil)
            }
        }
        DispatchQueue.main.async { front(20) }
    }

    static let panelHeight: CGFloat = 716
    static let exitStripHeight: CGFloat = 82
    private var height: CGFloat { Self.panelHeight + (exits.supported ? Self.exitStripHeight : 0) }

    var body: some View {
        ZStack {
            mainFace
                .rotation3DEffect(.degrees(model.routeShown ? -90 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
                .opacity(model.routeShown ? 0 : 1)
                .allowsHitTesting(!model.routeShown)
                .animation(model.routeShown ? .easeIn(duration: 0.2) : .easeOut(duration: 0.2).delay(0.2), value: model.routeShown)
            RouteFace(openWindow: { openMain(.overview) })
                .rotation3DEffect(.degrees(model.routeShown ? 0 : 90), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
                .opacity(model.routeShown ? 1 : 0)
                .allowsHitTesting(model.routeShown)
                .animation(model.routeShown ? .easeOut(duration: 0.2).delay(0.2) : .easeIn(duration: 0.2), value: model.routeShown)
        }
        .frame(width: fixedWidth, height: height)
        .background(t.bg)
        .background(WindowGrabber(ref: panelRef, onAppear: activatePanel))
        .trackVisibility(model.traffic, "panel")
        .foregroundColor(t.ink)
        .font(appFont(13.5))
    }

    private var mainFace: some View {
        let c = t.stateColor(model.state)
        return VStack(spacing: 12) {
            header
            VStack(spacing: 12) {
                PowerButton()
                ZStack {
                    if model.confirmingOff {
                        ConfirmOff().transition(.opacity)
                    } else {
                        VStack(spacing: 4) {
                            Text(model.state.title)
                                .font(appFont(22, .semibold))
                                .foregroundColor(c)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            subtitleText
                                .font(appNum(12))
                                .foregroundColor(t.ink2)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .transition(.opacity)
                    }
                }
                .frame(height: 64)
            }
            .padding(.top, 4)
            tiles
            TrafficReader { tr in
            VStack(spacing: 6) {
                Sparkline(down: tr.downHistory, up: tr.upHistory, color: c, upColor: t.accent)
                    .frame(height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.card))
                    .help("Приём и отдача за последние 5 минут")
                HStack(spacing: 10) {
                    Text("за сессию").foregroundColor(t.ink2)
                    Spacer(minLength: 4)
                    Text("↓ \(Format.bytes(tr.sessionDown))").foregroundColor(c)
                    Text("↑ \(Format.bytes(tr.sessionUp))").foregroundColor(t.accent)
                }
                .font(appNum(11))
                .lineLimit(1)
            }
            }
            VStack(spacing: 6) {
                ModeSegments()
                Text(model.directHint ? "закреплённые домены всё равно через VPS" : " ")
                    .font(appFont(12)).foregroundColor(t.ink2).frame(height: 14)
            }
            if exits.supported { ExitStrip() }
            ChipsRow()
            siteButton
            footer
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
        .frame(width: fixedWidth, height: height, alignment: .top)
        .animation(.easeOut(duration: 0.35), value: model.state)
        .animation(.easeOut(duration: 0.25), value: model.confirmingOff)
    }

    private var subtitleText: Text {
        if guardian.killSwitchActive {
            return Text(Image(systemName: "lock.shield.fill")) + Text(" ") + Text(model.subtitle)
        }
        return Text(model.subtitle)
    }

    private var speedLabel: some View {
        Group {
            switch speed.phase {
            case .running(let v):
                Text(SpeedMath.format(v)).font(appNum(12, .semibold))
            case .done(let v) where Date().timeIntervalSince(speed.finishedAt ?? .distantPast) < 20:
                Text(SpeedMath.format(v)).font(appNum(12, .semibold)).foregroundColor(t.ok)
            case .failed where Date().timeIntervalSince(speed.finishedAt ?? .distantPast) < 20:
                Text("ошибка").font(appFont(11)).foregroundColor(t.alarm)
            default:
                Image(systemName: "speedometer").font(.system(size: 14, weight: .medium))
            }
        }
    }

    private var exitLine: String {
        guard exits.supported else { return "\(ExitCatalog.fallback.country) · \(AppConfig.shared.serverIP)" }
        guard let e = exits.info else { return "выход не определён" }
        var s = "\(e.short) · \(e.owner)"
        if let d = model.delayMs { s += " · \(d) мс" }
        return s
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Свой VPN").font(appFont(13, .semibold)).tracking(0.26)
                    if let a = exits.active { ExitMarker(auto: a.auto) }
                }
                Text(exitLine).font(appNum(12)).foregroundColor(t.ink2).lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 8)
            Button { openMain(.settings) } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(t.ink2)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.tile))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(t.line, lineWidth: 1))
            }
            .buttonStyle(PressStyle())
            .help("Настройки")
        }
    }

    private var tiles: some View {
        let ping = Format.ping(model.delayMs)
        return HStack(spacing: 8) {
            TrafficReader { tr in
                let down = Format.rate(tr.downBps)
                let up = Format.rate(tr.upBps)
                tile("приём", down.value, down.unit)
                tile("отдача", up.value, up.unit)
            }
            tile("пинг", ping.value, ping.unit)
        }
    }

    private func tile(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(appFont(11)).foregroundColor(t.ink2)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(appNum(17, .semibold)).lineLimit(1).numeric(value)
                Text(unit).font(appFont(11)).foregroundColor(t.ink2).lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.tile))
    }

    private var siteButton: some View {
        Button { model.rules.addCurrentSite() } label: {
            HStack(spacing: 8) {
                Image(systemName: "globe").font(.system(size: 13, weight: .medium)).foregroundColor(t.ink2)
                Text(model.rules.siteNote ?? "Этот сайт — напрямую")
                    .font(appFont(model.rules.siteNote == nil ? 13 : 12))
                    .foregroundColor(t.ink).lineLimit(2).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity).frame(minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.tile))
        }
        .buttonStyle(PressStyle())
        .animation(.easeOut(duration: 0.2), value: model.rules.siteNote)
        .help("Домен из открытой вкладки Safari (или Chrome) пойдёт мимо VPN")
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Rectangle().fill(t.line).frame(height: 1)
            HStack(spacing: 8) {
                Button { openMain(.overview) } label: {
                    footerLabel("Открыть окно")
                }
                .help("Открыть окно")
                Button { model.showRoute() } label: { footerLabel("Где тормозит?") }
                    .help("Замер: роутер, провайдер, сервер, сайт")
                Button { speed.start() } label: {
                    speedLabel
                        .foregroundColor(t.ink)
                        .frame(width: 44, height: 36)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.tile))
                }
                .disabled(speed.isRunning || !model.apiOK)
                .opacity(model.apiOK ? 1 : 0.5)
                .help("Тест скорости: скачать 25 МБ через туннель")
            }
            .buttonStyle(PressStyle())
        }
    }

    private func footerLabel(_ s: String) -> some View {
        Text(s)
            .font(appFont(13))
            .foregroundColor(t.ink)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.tile))
    }
}
