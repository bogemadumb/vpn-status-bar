import SwiftUI

enum WindowSection: String, CaseIterable, Identifiable {
    #if CLIENT_EDITION
    case overview, connections, rules, log, settings
    #else
    case overview, connections, rules, keys, log, settings
    #endif
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Обзор"
        case .connections: return "Соединения"
        case .rules: return "Правила"
        #if !CLIENT_EDITION
        case .keys: return "Ключи"
        #endif
        case .log: return "Журнал"
        case .settings: return "Настройки"
        }
    }

    var stage: Int {
        switch self {
        case .overview: return 1
        case .connections, .rules: return 4
        #if !CLIENT_EDITION
        case .keys: return 8
        #endif
        case .log: return 5
        case .settings: return 5
        }
    }
}

extension View {
    func injectModels(_ m: VPNModel) -> some View {
        environmentObject(m).environmentObject(m.checks).environmentObject(m.guardian)
            .environmentObject(m.obs).environmentObject(m.speed).environmentObject(m.traffic).environmentObject(m.exits)
            #if !CLIENT_EDITION
            .environmentObject(m.server)
            #endif
    }
}

struct WindowView: View {
    @EnvironmentObject private var model: VPNModel
    var fixedSize: CGSize? = CGSize(width: 1100, height: 720)
    var scrollable = true
    var body: some View {
        ThemedRoot { WindowBody(fixedSize: fixedSize, scrollable: scrollable) }
            .injectModels(model)
    }
}

struct WindowBody: View {
    @EnvironmentObject private var model: VPNModel
    @Environment(\.theme) private var t
    var fixedSize: CGSize?
    var scrollable = true

    private var detailPadded: some View {
        detail
            .padding(EdgeInsets(top: 38, leading: 32, bottom: 40, trailing: 32))
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(t.line).frame(width: 1)
            if scrollable && model.section != .connections {
                ScrollView { detailPadded }
            } else {
                detailPadded.frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(width: fixedSize?.width, height: fixedSize?.height)
        .frame(minWidth: 960, minHeight: 600)
        .background(t.bg)
        .trackVisibility(model.traffic, "window")
        .foregroundColor(t.ink)
        .font(appFont(13.5))
    }

    @ViewBuilder var detail: some View {
        switch model.section {
        case .overview: OverviewContent()
        case .connections: ConnectionsContent()
        case .rules: RulesContent()
        #if !CLIENT_EDITION
        case .keys: KeysContent()
        #endif
        case .log: JournalContent()
        case .settings: SettingsContent()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "shield.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(t.accent)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.accentSoft))
                Text("Свой VPN").font(appFont(15, .semibold))
            }
            .padding(EdgeInsets(top: 14, leading: 12, bottom: 18, trailing: 12))
            ForEach(WindowSection.allCases) { s in
                let on = model.section == s
                Button { model.section = s } label: {
                    Text(s.title)
                        .font(appFont(14, on ? .semibold : .regular))
                        .foregroundColor(on ? t.ink : t.navInk)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(on ? t.card : Color.clear)
                                .shadow(color: on ? t.shadow : .clear, radius: t.isDark ? 9 : 5, x: 0, y: t.isDark ? 6 : 1))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(EdgeInsets(top: 24, leading: 14, bottom: 24, trailing: 14))
        .frame(width: 220)
        .animation(.easeOut(duration: 0.2), value: model.section)
    }
}

struct EmptySection: View {
    @Environment(\.theme) private var t
    let section: WindowSection
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(section.title).font(appFont(22, .semibold))
            VStack(spacing: 8) {
                Text("Появится на этапе \(section.stage)")
                    .font(appFont(16, .semibold))
                Text("Раздел пока пустой")
                    .font(appFont(13))
                    .foregroundColor(t.ink2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 64)
            .card()
        }
    }
}

struct OverviewContent: View {
    @EnvironmentObject private var model: VPNModel
    @EnvironmentObject private var obs: ObsModel
    @EnvironmentObject private var speed: SpeedModel
    @EnvironmentObject private var checks: ChecksModel
    @EnvironmentObject private var guardian: Guardian
    @EnvironmentObject private var exits: ExitModel
    #if !CLIENT_EDITION
    @EnvironmentObject private var server: ServerModel
    #endif
    @Environment(\.theme) private var t

    var body: some View {
        let c = t.stateColor(model.state)
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Text("Обзор").font(appFont(22, .semibold))
                Spacer(minLength: 12)
                ModeSegments(windowStyle: true)
                speedButton
                toggleButton
            }
            if model.confirmingOff {
                ConfirmOff(compact: true)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.alarm.opacity(0.14)))
                    .transition(.opacity)
            }
            statusCard(c)
            HStack(spacing: 14) { kpis }
            if exits.supported { ExitCard() }
            SpeedChartCard()
            HStack(alignment: .top, spacing: 14) {
                ChecksCard()
                JournalCard()
            }
            #if !CLIENT_EDITION
            ServerCard()
            #endif
            AppsCard()
        }
        .animation(.easeOut(duration: 0.35), value: model.state)
        .animation(.easeOut(duration: 0.25), value: model.confirmingOff)
        .task {
            while !Task.isCancelled {
                if model.traffic.active {
                    await obs.refresh()
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        #if !CLIENT_EDITION
        .task {
            while !Task.isCancelled {
                if model.traffic.active {
                    await server.refreshHealth()
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        #endif
    }

    private var speedLabel: String {
        switch speed.phase {
        case .idle: return "Тест скорости"
        case .running(let v): return "↓ \(SpeedMath.format(v)) МБ/с…"
        case .done(let v): return "Тест: \(SpeedMath.format(v)) МБ/с"
        case .failed: return "Тест не удался"
        }
    }

    private var speedButton: some View {
        Button { speed.start() } label: {
            HStack(spacing: 7) {
                Image(systemName: "speedometer").font(.system(size: 13, weight: .medium))
                Text(speedLabel).font(appNum(13)).lineLimit(1)
            }
            .foregroundColor(t.navInk)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.tile))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(t.line, lineWidth: 1))
        }
        .buttonStyle(PressStyle())
        .disabled(speed.isRunning || !model.apiOK)
        .help("Скачать 25 МБ через туннель и показать МБ/с")
    }

    private var toggleButton: some View {
        let off = model.state == .off
        return Button { model.toggle() } label: {
            Text(off ? "Включить VPN" : "Выключить VPN")
                .font(appFont(13, off ? .semibold : .regular))
                .foregroundColor(off ? t.btnFg : t.navInk)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(off ? t.btnBg : t.tile))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(off ? Color.clear : t.line, lineWidth: 1))
        }
        .buttonStyle(PressStyle())
        .disabled(model.busy)
    }

    private func statusCard(_ c: Color) -> some View {
        HStack(spacing: 20) {
            PowerButton(size: 64, iconSize: 28, ringWidth: 2, halo: false)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.state.title).font(appFont(22, .bold)).foregroundColor(c).lineLimit(1)
                Text(windowSubtitle).font(appFont(13)).foregroundColor(t.ink2).lineLimit(1)
            }
            Spacer(minLength: 12)
            HStack(spacing: 28) {
                fact("Внешний адрес", checks.externalAddress ?? "—")
                fact("Режим", model.modeShort, hint: model.directHint ? "закреплённые домены всё равно через VPS" : nil)
                fact("Kill switch", guardian.killSwitchActive ? "включён" : "выключен",
                     hint: guardian.killSwitchActive ? nil : (guardian.killSwitchEnabled ? "включится с VPN" : "отключён в настройках"))
            }
        }
        .card()
    }

    private var windowSubtitle: String {
        var parts: [String] = []
        switch model.state {
        case .ok:
            if let s = model.connectedSince {
                parts.append("Подключено \(Format.duration(model.now.timeIntervalSince(s)))")
            }
        case .slow, .degraded, .down:
            if let d = model.stateDetail { parts.append(d.prefix(1).uppercased() + d.dropFirst()) }
        case .off: parts.append("Туннель остановлен")
        case .connecting: parts.append(model.apiError.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Запускаю туннель")
        }
        if let v = model.singboxVersion { parts.append(v) }
        return parts.joined(separator: " · ")
    }

    private func fact(_ label: String, _ value: String, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(appFont(12)).foregroundColor(t.ink2)
            Text(value).font(appNum(15, .semibold)).lineLimit(1)
            if let h = hint { Text(h).font(appFont(11)).foregroundColor(t.ink2).lineLimit(1) }
        }
    }

    @ViewBuilder private var kpis: some View {
        let ping = Format.ping(model.delayMs)
        let today = obs.todayVPS + obs.todayDirect
        TrafficReader { tr in
            let down = Format.rate(tr.downBps)
            let up = Format.rate(tr.upBps)
            kpi("Скорость сейчас", "↓ \(down.value) \(down.unit)", "↑ \(up.value) \(up.unit)")
        }
        kpi("Пинг до сервера", ping.unit.isEmpty ? ping.value : "\(ping.value) \(ping.unit)",
            obs.avgDelay.map { "в среднем за час \($0) мс" } ?? "через туннель")
        kpi("Трафик сегодня", today > 0 ? Format.bytes(today) : "—",
            today > 0 ? "через VPS \(Format.bytes(obs.todayVPS)) · примерно" : "считается по соединениям")
        #if !CLIENT_EDITION
        serverKpi
        #endif
    }

    #if !CLIENT_EDITION
    private var serverKpi: some View {
        let h = server.health
        let total = h.flatMap { ServerLogic.monthTotal($0) }
        let note = ServerLogic.vnstatNote(now: Date())
        let sub: String = {
            guard let v = h?.vnstat else { return server.healthError == nil ? "опрашиваю сервер" : "нет связи с сервером" }
            let parts = ["↓ \(Format.bytes(v.rx)) ↑ \(Format.bytes(v.tx))"]
            return ((note.map { [$0] } ?? []) + parts).joined(separator: " · ")
        }()
        return kpi("Сервер за месяц", total.map { Format.bytes($0) } ?? "—", sub)
    }
    #endif

    private func kpi(_ label: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(appFont(12)).foregroundColor(t.ink2)
            Text(value).font(appNum(24, .bold)).lineLimit(1).minimumScaleFactor(0.8).numeric(value)
            Text(sub).font(appFont(12)).foregroundColor(t.ink2).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
