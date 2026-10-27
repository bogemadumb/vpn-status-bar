import SwiftUI
import AppKit

struct JournalContent: View {
    @EnvironmentObject private var obs: ObsModel
    @Environment(\.theme) private var t

    private var groups: [(day: Date, items: [EventRow])] {
        let cal = Calendar.current
        var out: [(Date, [EventRow])] = []
        for e in obs.events {
            let d = cal.startOfDay(for: e.start)
            if let i = out.firstIndex(where: { $0.0 == d }) { out[i].1.append(e) } else { out.append((d, [e])) }
        }
        return out.map { (day: $0.0, items: $0.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Журнал").font(appFont(22, .semibold))
            if obs.events.isEmpty {
                VStack(spacing: 8) {
                    Text("Обрывов не было").font(appFont(16, .semibold))
                    Text("Здесь появятся обрывы туннеля с длительностью и причиной, перезапуски ядра сторожем, утечки и тесты скорости.")
                        .font(appFont(13)).foregroundColor(t.ink2).multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 64)
                .card()
            }
            ForEach(groups, id: \.day) { g in
                VStack(alignment: .leading, spacing: 12) {
                    Text(Fmt.dayHeader(g.day)).font(appFont(14, .semibold)).foregroundColor(t.ink2)
                    ForEach(Array(g.items.enumerated()), id: \.element.id) { i, e in
                        HStack(alignment: .top, spacing: 14) {
                            Text(Fmt.time(e.start)).font(appNum(13)).foregroundColor(t.ink2).frame(width: 44, alignment: .leading)
                            EventLine(e: e, showWhen: false)
                        }
                        if i < g.items.count - 1 { Rectangle().fill(t.line).frame(height: 1) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .card()
            }
        }
    }
}

struct SettingsContent: View {
    @EnvironmentObject private var model: VPNModel
    @EnvironmentObject private var guardian: Guardian
    @EnvironmentObject private var obs: ObsModel
    #if !CLIENT_EDITION
    @EnvironmentObject private var server: ServerModel
    #endif
    @ObservedObject private var notifier = Notifier.shared
    @Environment(\.theme) private var t

    private func row(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).font(appFont(13))
            Spacer(minLength: 12)
            Text(value).font(appFont(13)).foregroundColor(t.ink2).multilineTextAlignment(.trailing).lineLimit(2)
        }
    }

    private var killState: String {
        if guardian.killSwitchActive { return "сейчас включён" }
        if !guardian.killSwitchEnabled { return "сейчас выключен" }
        if !guardian.intentOn { return "включится вместе с VPN" }
        return "ждёт включения"
    }

    private var watchdogState: String {
        guardian.intentOn ? "следит за туннелем" : "VPN выключен вами, не вмешивается"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Настройки").font(appFont(22, .semibold))
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Kill switch — не выпускать трафик мимо туннеля").font(appFont(15, .semibold))
                        Text("Пока VPN включён и туннель лежит, наружу идут только локальная сеть, адрес сервера и сам sing-box. Выключение VPN из приложения снимает защиту.")
                            .font(appFont(12)).foregroundColor(t.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: Binding(get: { guardian.killSwitchEnabled }, set: { guardian.setKillSwitch($0) }))
                        .toggleStyle(.switch).labelsHidden().tint(t.accent)
                }
                Text(killState).font(appFont(12)).foregroundColor(guardian.killSwitchActive ? t.ok : t.ink2)
            }
            .card()
            VStack(alignment: .leading, spacing: 12) {
                Text("Сторож").font(appFont(16, .semibold))
                row("Состояние", watchdogState)
                row("Перезапусков за 10 минут", "\(guardian.attemptsUsed) из \(Watchdog.maxAttempts)")
                row("Последнее действие", guardian.lastAction ?? "не было")
                Text("Ядро молчит 60 секунд — перезапуск. Не больше 3 попыток за 10 минут, дальше только уведомление.")
                    .font(appFont(11)).foregroundColor(t.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            VStack(alignment: .leading, spacing: 12) {
                Text("Уведомления и история").font(appFont(16, .semibold))
                row("Уведомления", notifier.authText)
                row("История", "30 дней, раз в 10 секунд")
                row("Файл", (HistoryDB.defaultPath as NSString).abbreviatingWithTildeInPath)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            launchCard
            versionsCard
        }
        .onAppear { notifier.refreshAuth() }
    }

    private var loginText: String {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/LaunchAgents/\(Edition.agentLabel).plist")
            ? "включено — запускается агентом при входе в систему" : "не настроено (нет LaunchAgent)"
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        return "VPN \(v)"
    }

    private var hotkeyText: String {
        HotKey.registered ? "\(HotKey.text) — открыть или вывести окно" : "\(HotKey.text) не зарегистрирована (занята другой программой?)"
    }

    private func openLog() {
        let url = URL(fileURLWithPath: StateLog.path)
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open([url], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
    }

    private var launchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Окно и запуск").font(appFont(16, .semibold))
            row("Горячая клавиша", hotkeyText)
            row("Открывать при входе", loginText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var versionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Версии и лог").font(appFont(16, .semibold))
            row("Приложение", appVersion)
            row("Ядро (sing-box)", model.singboxVersion ?? "ядро не отвечает")
            #if !CLIENT_EDITION
            row("Сервер (xray)", server.health?.xrayVersion ?? "сервер версию не сообщает")
            #endif
            HStack {
                Text("state.log").font(appFont(13))
                Spacer(minLength: 12)
                Button(action: openLog) {
                    Text("Открыть лог").font(appFont(13)).foregroundColor(t.navInk)
                        .padding(.horizontal, 14).frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.tile))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(t.line, lineWidth: 1))
                }
                .buttonStyle(PressStyle())
                .help((StateLog.path as NSString).abbreviatingWithTildeInPath)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
