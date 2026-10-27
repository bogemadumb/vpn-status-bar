import SwiftUI

struct RuleItem: Identifiable {
    let id: String
    let what: String
    let note: String
    let route: ConnRoute
    let user: UserRule?
}

enum RuleList {
    static func items(user: [UserRule], alwaysVps: [String]) -> [RuleItem] {
        func fixed(_ id: String, _ what: String, _ note: String, _ route: ConnRoute) -> RuleItem {
            RuleItem(id: id, what: what, note: note, route: route, user: nil)
        }
        #if CLIENT_EDITION
        var out: [RuleItem] = [
            fixed("server", "Сам сервер", "\(AppConfig.shared.serverIP) — иначе петля", .direct),
            fixed("lan", "Локальная сеть", "192.168.0.0/16 и др.", .local),
            fixed("torrent", "Торренты", "на сервере закрыты — идут напрямую", .direct),
            fixed("mode-direct", "Режим «Напрямую»", "весь трафик мимо туннеля", .direct),
            fixed("mode-global", "Режим «Всё через VPS»", "весь трафик в туннель", .vps),
        ]
        #else
        var out: [RuleItem] = [
            fixed("mail", "Почтовые порты", "993, 995, 465, 587", .direct),
            fixed("server", "Сам сервер", "\(AppConfig.shared.serverIP) — иначе петля", .direct),
            fixed("lan", "Локальная сеть", "192.168.0.0/16 и др.", .local),
            fixed("apple", "Apple", "17.0.0.0/8 — iCloud", .direct),
            fixed("pinned", "Закреплённые домены", alwaysVps.isEmpty ? "всегда через VPS, выше режимов" : alwaysVps.joined(separator: ", "), .vps),
            fixed("mode-direct", "Режим «Напрямую»", "весь трафик мимо туннеля", .direct),
            fixed("mode-global", "Режим «Всё через VPS»", "весь трафик в туннель", .vps),
        ]
        #endif
        let mine = user.filter { $0.target == .block } + user.filter { $0.target == .direct } + user.filter { $0.target == .proxy }
        if mine.isEmpty {
            out.append(fixed("mine-empty", "Мои правила", "добавь справа сайт, адрес или приложение", .vps))
        }
        for u in mine {
            let route: ConnRoute = u.target == .direct ? .direct : (u.target == .proxy ? .vps : .block)
            out.append(RuleItem(id: u.id, what: u.value, note: "мои · \(u.kind.label)", route: route, user: u))
        }
        #if CLIENT_EDITION
        out.append(fixed("local-domains", "Локальные домены", "всегда напрямую", .direct))
        #endif
        out.append(fixed("local", "Локальные сайты", "набор geoip-local", .direct))
        out.append(fixed("final", "Всё остальное", "по умолчанию", .vps))
        return out
    }
}

struct RulesContent: View {
    @EnvironmentObject private var model: VPNModel
    var body: some View { RulesBody(rules: model.rules) }
}

struct RulesBody: View {
    @Environment(\.theme) private var t
    @ObservedObject var rules: RulesModel
    @State private var text = ""
    @State private var target: RuleTarget = .direct

    private var parsed: (kind: RuleKind, value: String)? { RuleDetect.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Правила").font(appFont(22, .semibold))
                Spacer(minLength: 12)
                Text("применяется без перезапуска")
                    .font(appFont(12)).foregroundColor(t.ok)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(t.ok.opacity(0.13)))
            }
            Text("Сверху вниз, срабатывает первое подходящее")
                .font(appFont(12)).foregroundColor(t.ink2).padding(.top, -8)
            HStack(alignment: .top, spacing: 20) {
                list
                form.frame(width: 290)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) { ToastBar(rules: rules).padding(.bottom, 4) }
        .animation(.easeOut(duration: 0.2), value: rules.toast)
        .onAppear { rules.reload() }
    }

    private var list: some View {
        let items = RuleList.items(user: rules.user, alwaysVps: rules.alwaysVps)
        return VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                HStack(spacing: 10) {
                    Text("\(i + 1)").font(appNum(12)).foregroundColor(t.ink3).frame(width: 18, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(it.what).font(appFont(13, .semibold)).lineLimit(1).truncationMode(.middle)
                        Text(it.note).font(appFont(12)).foregroundColor(t.ink2).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    RouteChip(route: it.route)
                    if let u = it.user {
                        Button { rules.remove(u) } label: {
                            Image(systemName: "trash").font(.system(size: 12, weight: .medium))
                                .foregroundColor(t.ink2).frame(width: 28, height: 28)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(t.tile))
                        }
                        .buttonStyle(PressStyle()).help("Удалить правило")
                    } else {
                        Image(systemName: "lock.fill").font(.system(size: 10)).foregroundColor(t.ink3.opacity(0.7))
                            .frame(width: 28, height: 28).help("Встроенное правило, не редактируется")
                    }
                }
                .padding(.vertical, 9)
                .overlay(alignment: .top) { if i > 0 { Rectangle().fill(t.line).frame(height: 1) } }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.card)
            .shadow(color: t.shadow, radius: t.isDark ? 15 : 8, x: 0, y: t.isDark ? 10 : 2))
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Новое правило").font(appFont(14, .semibold))
            VStack(alignment: .leading, spacing: 5) {
                Text("Сайт, адрес или приложение").font(appFont(12)).foregroundColor(t.ink2)
                PlainField(placeholder: "example.com", text: $text)
                    .onSubmit { submit() }
                Text(parsed.map { "\($0.kind.label): \($0.value)" } ?? " ")
                    .font(appFont(12)).foregroundColor(t.ink2).lineLimit(1).truncationMode(.middle)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Куда пускать").font(appFont(12)).foregroundColor(t.ink2)
                HStack(spacing: 4) {
                    ForEach(RuleTarget.allCases, id: \.self) { tg in
                        let on = target == tg
                        Button { target = tg } label: {
                            Text(tg == .direct ? "Напрямую" : (tg == .proxy ? "Через VPS" : "Блок"))
                                .font(appFont(13, on ? .semibold : .regular))
                                .foregroundColor(on ? t.ink : t.ink3)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity).frame(height: 30)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(on ? t.card : Color.clear)
                                    .shadow(color: on ? t.shadow : .clear, radius: t.isDark ? 6 : 3, x: 0, y: t.isDark ? 3 : 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(t.bg2))
            }
            Button { submit() } label: {
                Text("Добавить, без перезапуска")
                    .font(appFont(13, .semibold)).foregroundColor(Color.white)
                    .frame(maxWidth: .infinity).frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(t.accent))
            }
            .buttonStyle(PressStyle())
            .disabled(parsed == nil)
            .opacity(parsed == nil ? 0.5 : 1)
        }
        .card()
    }

    private func submit() {
        guard let p = parsed else { return }
        if rules.add(kind: p.kind, value: p.value, target: target) {
            rules.say("\(p.value) — \(target.label)")
            text = ""
        }
    }
}
