import SwiftUI

struct RouteChip: View {
    @Environment(\.theme) private var t
    let route: ConnRoute
    var exit: String? = nil

    private var colors: (bg: Color, fg: Color) {
        switch route {
        case .vps: return (t.ok.opacity(0.14), t.ok)
        case .direct:
            let b = t.isDark ? Color(hex: 0x9AAAFF) : Color(hex: 0x3A55C8)
            return (b.opacity(t.isDark ? 0.15 : 0.12), b)
        case .local: return (t.ink2.opacity(0.16), t.isDark ? t.navInk : t.ink2)
        case .block: return (t.alarm.opacity(0.15), t.alarm)
        }
    }

    var body: some View {
        Text(route.label)
            .font(appFont(12))
            .foregroundColor(colors.fg)
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(colors.bg))
            .help(exit.map { "Выход: \($0)" } ?? "")
    }
}

struct FieldBox: ViewModifier {
    @Environment(\.theme) private var t
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(appFont(13))
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(t.isDark ? t.bg : t.card))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(t.isDark ? Color.white.opacity(0.1) : t.line, lineWidth: 1))
    }
}

struct PlainField: View {
    @Environment(\.theme) private var t
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField("", text: $text)
            .modifier(FieldBox())
            .overlay(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder).font(appFont(13)).foregroundColor(t.ink3).padding(.leading, 12).allowsHitTesting(false)
                }
            }
    }
}

struct ToastBar: View {
    @Environment(\.theme) private var t
    @ObservedObject var rules: RulesModel

    var body: some View {
        if let s = rules.toast {
            Text(s)
                .font(appFont(13))
                .foregroundColor(t.ink)
                .lineLimit(2)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.card)
                    .shadow(color: t.shadow, radius: 8, x: 0, y: 3))
                .transition(.opacity)
        }
    }
}

struct ConnectionsContent: View {
    @EnvironmentObject private var model: VPNModel
    var body: some View {
        ConnectionsBody(conns: model.conns, rules: model.rules)
            .task { await model.conns.run() }
    }
}

private enum Col {
    static let app: CGFloat = 130
    static let chip: CGFloat = 82
    static let speed: CGFloat = 80
    static let age: CGFloat = 52
    static let gap: CGFloat = 12
}

struct ConnectionsBody: View {
    @Environment(\.theme) private var t
    @ObservedObject var conns: ConnectionsModel
    @ObservedObject var rules: RulesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("Соединения").font(appFont(22, .semibold))
                Spacer(minLength: 12)
                PlainField(placeholder: "приложение или сайт", text: $conns.search)
                    .frame(width: 240)
            }
            HStack(spacing: 6) {
                ForEach(ConnFilter.allCases, id: \.self) { chip($0) }
                Spacer()
            }
            table
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) { ToastBar(rules: rules).padding(.bottom, 4) }
        .animation(.easeOut(duration: 0.2), value: rules.toast)
    }

    private func chip(_ f: ConnFilter) -> some View {
        let on = conns.filter == f
        return Button { conns.filter = f } label: {
            Text("\(f.label) · \(conns.count(f))")
                .font(appFont(13, on ? .semibold : .regular))
                .foregroundColor(on ? Color.white : t.navInk)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(on ? t.accent : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(on ? Color.clear : (t.isDark ? Color(hex: 0x3A3C42) : Color(hex: 0xCFCCC4)), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private var header: some View {
        HStack(spacing: Col.gap) {
            Text("Приложение").frame(width: Col.app, alignment: .leading)
            Text("Куда").frame(maxWidth: .infinity, alignment: .leading)
            Text("Путь").frame(width: Col.chip, alignment: .leading)
            Text("Правило").frame(minWidth: 110, maxWidth: 150, alignment: .leading)
            Text("Скорость").frame(width: Col.speed, alignment: .leading)
            Text("Длится").frame(width: Col.age, alignment: .leading)
        }
        .font(appFont(12, .medium))
        .foregroundColor(t.ink2)
        .lineLimit(1)
        .padding(.horizontal, 18)
        .padding(.top, 14).padding(.bottom, 10)
    }

    private var table: some View {
        let list = conns.visible
        return VStack(spacing: 0) {
            header
            if list.isEmpty {
                Text(conns.failed ? "Ядро не отвечает" : "Нет соединений")
                    .font(appFont(13)).foregroundColor(t.ink2)
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(list) { r in row(r) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.card)
            .shadow(color: t.shadow, radius: t.isDark ? 15 : 8, x: 0, y: t.isDark ? 10 : 2))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func row(_ r: ConnRow) -> some View {
        HStack(spacing: Col.gap) {
            Text(r.app).font(appFont(13, .semibold)).lineLimit(1).truncationMode(.tail)
                .frame(width: Col.app, alignment: .leading)
            Text(r.host).font(appFont(13)).foregroundColor(t.navInk).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            RouteChip(route: r.route, exit: r.exitLabel).frame(width: Col.chip, alignment: .leading)
            Text(r.ruleText).font(appFont(13)).foregroundColor(t.ink2).lineLimit(1).truncationMode(.tail)
                .frame(minWidth: 110, maxWidth: 150, alignment: .leading)
            Text(ConnLogic.speed(r.speed)).font(appNum(13)).foregroundColor(r.speed > 0 ? t.ink : t.ink3).lineLimit(1)
                .frame(width: Col.speed, alignment: .leading)
            Text(r.started.map { ConnLogic.age(Date().timeIntervalSince($0)) } ?? "—")
                .font(appNum(13)).foregroundColor(t.ink2).lineLimit(1)
                .frame(width: Col.age, alignment: .leading)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(t.line).frame(height: 1) }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Оборвать") { conns.drop(r) }
            Divider()
            Button("Этот сайт — всегда напрямую") { conns.ruleForSite(r, .direct) }
            Button("Этот сайт — всегда через VPS") { conns.ruleForSite(r, .proxy) }
            Divider()
            Button("Это приложение — напрямую") { conns.ruleForApp(r, .direct) }
                .disabled(r.app == "—")
            Button("Это приложение — через VPS") { conns.ruleForApp(r, .proxy) }
                .disabled(r.app == "—")
        }
    }
}
