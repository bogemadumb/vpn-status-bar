import SwiftUI

enum Fmt {
    private static let hm: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "HH:mm"; return f
    }()
    private static let dm: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "dd.MM"; return f
    }()
    private static let dayLong: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMMM"; return f
    }()

    static func time(_ d: Date) -> String { hm.string(from: d) }
    static func dayMonth(_ d: Date) -> String { dm.string(from: d) }

    static func when(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "сегодня, \(time(d))" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "вчера, \(time(d))" }
        return "\(dayMonth(d)), \(time(d))"
    }

    static func dayHeader(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "Сегодня" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Вчера" }
        return dayLong.string(from: d)
    }

    static func kindName(_ k: String) -> String {
        switch k {
        case "core": return "Ядро"
        case "net": return "Сеть"
        case "server": return "Сервер"
        case "watchdog": return "Сторож"
        case "leak": return "Утечка"
        case "speed": return "Тест скорости"
        case "exit": return "Выход"
        default: return k
        }
    }
}

extension Theme {
    var blue: Color { isDark ? Color(hex: 0x9AAAFF) : Color(hex: 0x3A55C8) }

    func checkColor(_ s: CheckStatus) -> Color {
        switch s {
        case .ok: return ok
        case .warn: return warn
        case .fail: return alarm
        case .pending, .skipped: return ink2
        }
    }

    func eventColor(_ kind: String) -> Color {
        switch kind {
        case "leak": return alarm
        case "watchdog": return accent
        case "speed", "exit": return blue
        default: return warn
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        var frames: [CGRect] = []
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            frames.append(CGRect(x: x, y: y, width: sz.width, height: sz.height))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            maxX = max(maxX, x - spacing)
        }
        return (frames, CGSize(width: maxX, height: y + rowH))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(bounds.width, subviews)
        for (i, s) in subviews.enumerated() {
            s.place(at: CGPoint(x: bounds.minX + r.frames[i].minX, y: bounds.minY + r.frames[i].minY), proposal: .unspecified)
        }
    }
}

struct StatusChip: View {
    @Environment(\.theme) private var t
    let chip: Chip
    var body: some View {
        let c = t.checkColor(chip.status)
        let tinted = chip.status == .ok || chip.status == .warn || chip.status == .fail
        Text(chip.text)
            .font(appFont(12))
            .foregroundColor(c)
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(tinted ? c.opacity(0.12) : t.tile))
    }
}

struct ChipsRow: View {
    @EnvironmentObject private var checks: ChecksModel
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(checks.chips.enumerated()), id: \.offset) { StatusChip(chip: $0.element) }
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
    }
}

struct BarChart: View {
    @Environment(\.theme) private var t
    let buckets: [Bucket?]

    var body: some View {
        let hasData = buckets.contains { $0 != nil }
        Canvas { ctx, size in
            let n = max(buckets.count, 1)
            let gap: CGFloat = n > 70 ? 1 : 2
            let bw = max(1, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            let peak = max(buckets.compactMap { $0.map { $0.down + $0.up } }.max() ?? 0, Sparkline.floorBps)
            let usable = size.height - 6
            for (i, b) in buckets.enumerated() {
                let x = CGFloat(i) * (bw + gap)
                guard let b = b else {
                    ctx.fill(Path(CGRect(x: x, y: size.height - 1.5, width: bw, height: 1.5)), with: .color(t.ink3.opacity(0.35)))
                    continue
                }
                if b.drop {
                    ctx.fill(Path(CGRect(x: x, y: 0, width: bw, height: size.height)), with: .color(t.warn.opacity(0.18)))
                    ctx.fill(Path(CGRect(x: x, y: size.height - 4, width: bw, height: 4)), with: .color(t.warn))
                    continue
                }
                let hd = b.down > 0 ? max(2, CGFloat(b.down / peak) * usable) : 0
                let hu = b.up > 0 ? max(2, CGFloat(b.up / peak) * usable) : 0
                let r = min(2, bw / 2)
                if hu > 0 {
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: size.height - hu, width: bw, height: hu), cornerRadius: r), with: .color(t.blue))
                }
                if hd > 0 {
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: size.height - hu - hd - (hu > 0 ? 1 : 0), width: bw, height: hd), cornerRadius: r), with: .color(t.accent))
                }
            }
        }
        .overlay {
            if !hasData {
                Text("Данные копятся: запись раз в 10 секунд")
                    .font(appFont(12)).foregroundColor(t.ink2)
            }
        }
    }
}

struct SpeedChartCard: View {
    @EnvironmentObject private var model: VPNModel
    @EnvironmentObject private var obs: ObsModel
    @Environment(\.theme) private var t

    private func legend(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10)
            Text(s).font(appFont(12)).foregroundColor(t.ink2)
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 2) {
            ForEach(ChartRange.allCases) { r in
                let on = obs.range == r
                Button { obs.setRange(r) } label: {
                    Text(r.title)
                        .font(appFont(12, on ? .semibold : .regular))
                        .foregroundColor(on ? t.ink : t.ink3)
                        .padding(.horizontal, 12).frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(on ? t.card : Color.clear)
                            .shadow(color: on ? t.shadow : .clear, radius: 4, x: 0, y: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(t.bg2))
    }

    private var axis: [String] {
        let start = Date(timeIntervalSince1970: Double(obs.range.start(now: Date())))
        let mid = start.addingTimeInterval(Double(obs.range.step * obs.range.count) / 2)
        switch obs.range {
        case .hour: return [Fmt.time(start), Fmt.time(mid), "сейчас"]
        case .day: return [Fmt.time(start), Fmt.time(mid), "сейчас"]
        case .month: return [Fmt.dayMonth(start), Fmt.dayMonth(mid), "сегодня"]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                Text(obs.range.heading).font(appFont(16, .semibold))
                Spacer()
                legend(t.accent, "приём")
                legend(t.blue, "отдача")
                legend(t.warn, "обрыв")
                rangePicker
            }
            BarChart(buckets: obs.buckets)
                .frame(height: 140)
            HStack {
                Text(axis[0])
                Spacer()
                TrafficReader { tr in
                    Text("за сессию ↓ \(Format.bytes(tr.sessionDown))  ↑ \(Format.bytes(tr.sessionUp))")
                }
                Spacer()
                Text(axis[1])
                Spacer()
                Text(axis[2])
            }
            .font(appFont(11)).foregroundColor(t.ink2)
        }
        .card()
    }
}

struct ChecksCard: View {
    @EnvironmentObject private var model: VPNModel
    @EnvironmentObject private var checks: ChecksModel
    @EnvironmentObject private var guardian: Guardian
    @Environment(\.theme) private var t

    private var killText: (String, Color) {
        if guardian.killSwitchActive { return ("включён", t.ok) }
        if !guardian.killSwitchEnabled { return ("выключен в настройках", t.ink2) }
        if !guardian.intentOn { return ("не нужен: VPN выключен", t.ink2) }
        return ("ждёт включения", t.warn)
    }

    private func row(_ name: String, _ value: String, _ c: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(name).font(appFont(13))
            Spacer(minLength: 8)
            Text(value).font(appFont(13)).foregroundColor(c).lineLimit(1).multilineTextAlignment(.trailing)
        }
    }

    private var footnote: String {
        if checks.running { return "проверяю…" }
        guard let d = checks.lastRun else { return "ещё не проверялось" }
        return "проверено \(Format.span(Date().timeIntervalSince(d))) назад, дальше через 5 минут"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Проверки").font(appFont(16, .semibold))
                Spacer()
                Button { model.runChecksNow() } label: {
                    Text(checks.running ? "Проверяю…" : "Проверить")
                        .font(appFont(12))
                        .foregroundColor(t.ink)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.tile))
                }
                .buttonStyle(PressStyle())
                .disabled(checks.running || !model.daemonRunning)
            }
            ForEach(checks.items) { c in
                row(c.name, c.text, t.checkColor(c.status))
            }
            row("Kill switch", killText.0, killText.1)
            Text(footnote).font(appFont(11)).foregroundColor(t.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }
}

struct EventLine: View {
    @Environment(\.theme) private var t
    let e: EventRow
    var showKind = true
    var showWhen = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if showWhen { Text(Fmt.when(e.start)).font(appFont(13, .semibold)) }
                if showKind {
                    Text(Fmt.kindName(e.kind)).font(appFont(11))
                        .foregroundColor(t.eventColor(e.kind))
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Capsule().fill(t.eventColor(e.kind).opacity(0.14)))
                }
                Spacer()
                if let d = e.duration, d > 0 || e.kind == "server" || e.kind == "core" || e.kind == "net" {
                    Text(Format.span(d)).font(appNum(13)).foregroundColor(t.warn)
                } else if e.end == nil && ["core", "net", "server"].contains(e.kind) {
                    Text("идёт").font(appFont(13)).foregroundColor(t.alarm)
                }
            }
            Text(e.detail).font(appFont(12)).foregroundColor(t.ink2).lineLimit(2)
        }
    }
}

struct JournalCard: View {
    @EnvironmentObject private var model: VPNModel
    @EnvironmentObject private var obs: ObsModel
    @Environment(\.theme) private var t

    var body: some View {
        let list = Array(obs.events.filter { $0.kind != "speed" }.prefix(3))
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Журнал").font(appFont(16, .semibold))
                Spacer()
                Button { model.section = .log } label: {
                    Text("Все события").font(appFont(12)).foregroundColor(t.ink2)
                }
                .buttonStyle(.plain)
            }
            if list.isEmpty {
                Text("Обрывов не было. Здесь появятся обрывы туннеля, перезапуски ядра сторожем и утечки.")
                    .font(appFont(12)).foregroundColor(t.ink2)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, e in
                EventLine(e: e)
                if i < list.count - 1 { Rectangle().fill(t.line).frame(height: 1) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }
}

struct AppsCard: View {
    @EnvironmentObject private var obs: ObsModel
    @Environment(\.theme) private var t

    var body: some View {
        let peak = max(obs.apps.map { $0.total }.max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Трафик по приложениям").font(appFont(16, .semibold))
                Text("сегодня, примерно").font(appFont(12)).foregroundColor(t.ink2)
                Spacer()
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(t.ok).frame(width: 10, height: 10)
                    Text("через VPS").font(appFont(12)).foregroundColor(t.ink2)
                }
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(t.blue).frame(width: 10, height: 10)
                    Text("напрямую").font(appFont(12)).foregroundColor(t.ink2)
                }
                .padding(.leading, 10)
            }
            if obs.apps.isEmpty {
                Text("За сегодня данных пока нет. Считается по соединениям раз в 2 секунды, очень короткие соединения могут не попасть.")
                    .font(appFont(12)).foregroundColor(t.ink2)
            }
            ForEach(obs.apps) { a in
                HStack(spacing: 14) {
                    Text(a.process == "—" ? "не определено" : a.process)
                        .font(appFont(13)).lineLimit(1)
                        .frame(width: 170, alignment: .leading)
                    GeometryReader { g in
                        let w = g.size.width * CGFloat(a.total / peak)
                        HStack(spacing: 1) {
                            if a.vps > 0 { Rectangle().fill(t.ok).frame(width: max(2, w * CGFloat(a.vps / a.total))) }
                            if a.direct > 0 { Rectangle().fill(t.blue).frame(width: max(2, w * CGFloat(a.direct / a.total))) }
                        }
                        .frame(height: 8)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 14)
                    Text(Format.bytes(a.total)).font(appNum(13, .semibold)).frame(width: 70, alignment: .trailing)
                    Text("VPS \(Format.bytes(a.vps))").font(appNum(12)).foregroundColor(t.ink2).frame(width: 96, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }
}
