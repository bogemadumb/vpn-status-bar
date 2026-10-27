import SwiftUI

extension Theme {
    func pingColor(_ p: ExitPing) -> Color {
        switch p {
        case .ms(let v): return v > 400 ? warn : ink2
        case .down: return alarm
        case .unknown: return ink3
        }
    }

    func exitDot(_ p: ExitPing) -> Color {
        switch p {
        case .ms(let v): return v > 400 ? warn : ok
        case .down: return alarm
        case .unknown: return ink3
        }
    }
}

struct ExitMarker: View {
    @Environment(\.theme) private var t
    let auto: Bool

    var body: some View {
        let c = auto ? t.ok : t.accent
        Text(auto ? "авто" : "закреплён")
            .font(appFont(11))
            .foregroundColor(c)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(Capsule().fill(c.opacity(0.14)))
    }
}

struct ExitStrip: View {
    @EnvironmentObject private var exits: ExitModel
    @EnvironmentObject private var model: VPNModel
    @Environment(\.theme) private var t

    private func selected(_ tag: String) -> Bool {
        tag == ExitCatalog.autoTag ? exits.active?.auto == true : exits.active?.selection == tag
    }

    private func cell(_ tag: String) -> some View {
        let isAuto = tag == ExitCatalog.autoTag
        let on = selected(tag)
        let inUse = !isAuto && exits.active?.tag == tag
        let p = isAuto ? ExitPing.unknown : exits.ping(tag)
        return Button { exits.select(tag, client: model.client) } label: {
            VStack(spacing: 2) {
                if isAuto {
                    Text("Авто").font(appFont(13, on ? .semibold : .regular)).foregroundColor(on ? t.ink : t.ink2)
                } else {
                    Text(ExitCatalog.info(tag).flag).font(.system(size: 16))
                }
                Text(isAuto ? (exits.info.map { exits.active?.auto == true ? $0.flag : " " } ?? " ") : ExitLogic.pingText(p).replacingOccurrences(of: " мс", with: ""))
                    .font(appNum(10))
                    .foregroundColor(isAuto ? t.ink2 : t.pingColor(p))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(on ? t.tileSelected : Color.clear)
                    .shadow(color: on ? t.shadow : .clear, radius: t.isDark ? 6 : 4, x: 0, y: t.isDark ? 3 : 1))
            .overlay(alignment: .topTrailing) {
                if inUse && exits.active?.auto == true {
                    Circle().fill(t.ok).frame(width: 5, height: 5).padding(5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isAuto ? "Автовыбор: ядро берёт самый быстрый выход" : "\(ExitCatalog.info(tag).label) · \(ExitLogic.pingText(p)) · закрепить")
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                cell(ExitCatalog.autoTag)
                ForEach(ExitCatalog.list, id: \.tag) { cell($0.tag) }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.tile))
            .opacity(exits.available && model.apiOK ? 1 : 0.55)
            .allowsHitTesting(exits.available && model.apiOK && exits.switching == nil)
            Text(exits.note ?? " ").font(appFont(11)).foregroundColor(t.alarm).frame(height: 13)
        }
        .animation(.easeOut(duration: 0.35), value: exits.active)
    }
}

struct ExitCard: View {
    @EnvironmentObject private var exits: ExitModel
    @EnvironmentObject private var model: VPNModel
    @Environment(\.theme) private var t

    private func selected(_ tag: String) -> Bool {
        tag == ExitCatalog.autoTag ? exits.active?.auto == true : exits.active?.selection == tag
    }

    private func row(_ tag: String) -> some View {
        let isAuto = tag == ExitCatalog.autoTag
        let info = ExitCatalog.info(tag)
        let on = selected(tag)
        let inUse = exits.active?.tag == tag
        let p = isAuto ? ExitPing.unknown : exits.ping(tag)
        return Button { exits.select(tag, client: model.client) } label: {
            HStack(spacing: 12) {
                Circle().fill(isAuto ? (exits.available ? t.ok : t.ink3) : t.exitDot(p)).frame(width: 8, height: 8)
                if isAuto {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 13, weight: .medium)).frame(width: 22)
                    Text("Авто").font(appFont(14, .semibold))
                    if exits.active?.auto == true, let cur = exits.info {
                        Text("сейчас \(cur.short)").font(appFont(12)).foregroundColor(t.ink2)
                    }
                } else {
                    Text(info.flag).font(.system(size: 16)).frame(width: 22)
                    Text(info.country).font(appFont(14, .semibold))
                    Text(info.owner).font(appFont(11)).foregroundColor(t.ink2)
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Capsule().fill(t.ink2.opacity(0.14)))
                    if inUse { Text("выход сейчас").font(appFont(12)).foregroundColor(t.ink2) }
                }
                Spacer(minLength: 8)
                if !isAuto { Text(ExitLogic.pingText(p)).font(appNum(13)).foregroundColor(t.pingColor(p)) }
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundColor(on ? t.accent : t.ink3)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Выход").font(appFont(16, .semibold))
                if let a = exits.active { ExitMarker(auto: a.auto) }
                Spacer()
                Text(ExitLogic.switchesText(exits.switches)).font(appFont(12)).foregroundColor(t.ink2)
            }
            VStack(spacing: 0) {
                row(ExitCatalog.autoTag)
                ForEach(ExitCatalog.list, id: \.tag) { e in
                    Rectangle().fill(t.line).frame(height: 1)
                    row(e.tag)
                }
            }
            .opacity(exits.available && model.apiOK ? 1 : 0.55)
            .allowsHitTesting(exits.available && model.apiOK && exits.switching == nil)
            Text(exits.note ?? "«Авто» выбирает самый быстрый сервер раз в 30 секунд. Клик по серверу закрепляет его.")
                .font(appFont(11)).foregroundColor(exits.note == nil ? t.ink2 : t.alarm)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }
}
