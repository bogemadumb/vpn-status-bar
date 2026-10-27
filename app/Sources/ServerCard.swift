#if !CLIENT_EDITION
import SwiftUI

extension Theme {
    func levelColor(_ l: Level) -> Color {
        switch l {
        case .ok: return ok
        case .warn: return warn
        case .alarm: return alarm
        }
    }
}

struct ServerCard: View {
    @EnvironmentObject private var server: ServerModel
    @Environment(\.theme) private var t

    private let cols = [GridItem(.flexible(), spacing: 14, alignment: .topLeading),
                        GridItem(.flexible(), spacing: 14, alignment: .topLeading),
                        GridItem(.flexible(), spacing: 14, alignment: .topLeading)]

    private func cell(_ label: String, _ value: String, _ sub: String, _ level: Level = .ok) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(appFont(12)).foregroundColor(t.ink2)
            Text(value).font(appNum(18, .semibold)).foregroundColor(level == .ok ? t.ink : t.levelColor(level))
                .lineLimit(1).minimumScaleFactor(0.8).numeric(value)
            Text(sub).font(appNum(12)).foregroundColor(level == .ok ? t.ink2 : t.levelColor(level))
                .lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.tile))
    }

    private func service(_ name: String, _ on: Bool, _ level: Level) -> some View {
        HStack(spacing: 7) {
            Circle().fill(t.levelColor(level)).frame(width: 8, height: 8)
            Text(name).font(appFont(13, .semibold))
            Text(on ? "работает" : "не работает").font(appFont(12)).foregroundColor(on ? t.ink2 : t.alarm)
        }
    }

    private func fmt(_ v: Double) -> String { String(format: "%.2f", v).replacingOccurrences(of: ".", with: ",") }

    @ViewBuilder private func grid(_ h: ServerHealth) -> some View {
        let now = Date()
        let lv = ServerLogic.levels(h, now: now)
        let days = ServerLogic.certDays(h, now: now)
        LazyVGrid(columns: cols, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Службы").font(appFont(12)).foregroundColor(t.ink2)
                service("xray", h.xray, lv.xray)
                service("nginx", h.nginx, lv.nginx)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.tile))
            cell("Процессор", "\(Int(h.cpuPercent.rounded())) %",
                 "нагрузка \(h.load.prefix(3).map(fmt).joined(separator: " · ")) на \(h.cpus) яд.",
                 max(lv.cpu, lv.load))
            cell("Память", "\(Format.bytes(h.ramUsed)) из \(Format.bytes(h.ramTotal))",
                 "занято \(Int((h.ramUsed / max(1, h.ramTotal) * 100).rounded())) %", lv.ram)
            cell("Диск", "\(Format.bytes(h.diskFree)) свободно", "из \(Format.bytes(h.diskTotal))", lv.disk)
            cell("Без перезагрузки", ServerLogic.uptimeText(h.uptime), "с последнего запуска")
            cell("Сертификат", days.map { "ещё \($0) дн" } ?? "—",
                 h.certNotAfter.map { "до \(Fmt.dayMonth($0)).\(Calendar.current.component(.year, from: $0))" } ?? "срок неизвестен", lv.cert)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Сервер").font(appFont(16, .semibold))
                Text("\(ExitCatalog.fallback.country) · \(AppConfig.shared.serverIP)").font(appNum(12)).foregroundColor(t.ink2)
                Spacer(minLength: 8)
                if let at = server.healthAt {
                    Text("обновлено \(Fmt.time(at))").font(appNum(12)).foregroundColor(t.ink2)
                }
                Button { Task { await server.refreshHealth(force: true) } } label: {
                    Group {
                        if server.loadingHealth { ProgressView().controlSize(.small).scaleEffect(0.7) }
                        else { Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium)) }
                    }
                    .frame(width: 28, height: 28)
                    .foregroundColor(t.navInk)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.tile))
                }
                .buttonStyle(PressStyle())
                .disabled(server.loadingHealth)
                .help("Опросить сервер сейчас")
            }
            if let h = server.health {
                grid(h)
                if let e = server.healthError {
                    Text("Нет свежих данных: \(e)").font(appFont(12)).foregroundColor(t.warn)
                }
            } else if let e = server.healthError {
                Text(e).font(appFont(13)).foregroundColor(t.alarm).padding(.vertical, 12)
            } else {
                Text("Опрашиваю сервер…").font(appFont(13)).foregroundColor(t.ink2).padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
        .animation(.easeOut(duration: 0.35), value: server.health)
    }
}
#endif
