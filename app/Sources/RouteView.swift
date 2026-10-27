import SwiftUI

struct RouteFace: View {
    @EnvironmentObject private var model: VPNModel
    @Environment(\.theme) private var t
    let openWindow: () -> Void

    var body: some View {
        RouteFaceBody(route: model.route, openWindow: openWindow)
    }
}

struct RouteFaceBody: View {
    @EnvironmentObject private var model: VPNModel
    @Environment(\.theme) private var t
    @ObservedObject var route: RouteModel
    let openWindow: () -> Void

    private func color(_ s: HopStatus) -> Color {
        switch s {
        case .ok: return t.ok
        case .warn: return t.warn
        case .unknown: return t.ink3
        }
    }

    private func verdictColor(_ v: RouteVerdict) -> Color {
        switch v.kind {
        case .ok: return t.ok
        case .serverDown, .routerDown: return t.alarm
        default: return t.warn
        }
    }

    var body: some View {
        let a = route.analysis
        VStack(spacing: 14) {
            topRow
            verdictHeader(a?.verdict)
            hopsCard(a?.hops)
            detailBox(a?.verdict)
            Spacer(minLength: 0)
            footer
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
    }

    private var topRow: some View {
        HStack {
            Button { model.hideRoute() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text("Назад").font(appFont(13))
                }
                .foregroundColor(t.ink)
                .padding(.horizontal, 12).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.tile))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(t.line, lineWidth: 1))
            }
            .buttonStyle(PressStyle())
            Spacer()
            Text("Где тормозит?").font(appFont(13, .semibold)).tracking(0.26)
        }
    }

    private func verdictHeader(_ v: RouteVerdict?) -> some View {
        let c = v.map(verdictColor) ?? t.ink2
        let icon = v == nil ? "dot.radiowaves.left.and.right" : (v!.isProblem ? "exclamationmark.shield" : "checkmark.shield")
        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium))
                .foregroundColor(c)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(v?.title ?? "Замеряю…")
                    .font(appFont(16, .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                subtitle
            }
            Spacer(minLength: 0)
        }
        .opacity(route.measuring && v != nil ? 0.55 : 1)
    }

    @ViewBuilder private var subtitle: some View {
        if route.measuring {
            Text("несколько секунд").font(appFont(12)).foregroundColor(t.ink2)
        } else if let at = route.measuredAt {
            TimelineView(.periodic(from: Date(), by: 1)) { ctx in
                Text("замер \(Self.ago(ctx.date.timeIntervalSince(at)))").font(appFont(12)).foregroundColor(t.ink2)
            }
        } else {
            Text(" ").font(appFont(12))
        }
    }

    static func ago(_ sec: TimeInterval) -> String {
        let s = max(0, Int(sec))
        if s < 5 { return "только что" }
        if s < 60 { return "\(s) с назад" }
        return "\(s / 60) мин назад"
    }

    private var skeleton: [Hop] {
        let e = RouteAnalysis.exitNames(model.exits.info ?? ExitCatalog.fallback)
        return [
            Hop(id: "mac", name: "Мак", sub: "этот компьютер", ms: 0, delta: nil, status: .ok),
            Hop(id: "router", name: "Роутер", sub: "…", ms: nil, delta: nil, status: .unknown),
            Hop(id: "provider", name: "Провайдер", sub: "…", ms: nil, delta: nil, status: .unknown),
            Hop(id: "vps", name: e.name, sub: e.sub, ms: nil, delta: nil, status: .unknown),
            Hop(id: "site", name: "Сайт", sub: "\(AppConfig.shared.traceHost) через туннель", ms: nil, delta: nil, status: .unknown),
        ]
    }

    private func hopsCard(_ hops: [Hop]?) -> some View {
        let list = hops ?? skeleton
        return VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, h in
                hopRow(h, last: i == list.count - 1)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 14, bottom: 6, trailing: 14))
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.card))
        .opacity(route.measuring && hops != nil ? 0.55 : 1)
        .animation(.easeOut(duration: 0.25), value: route.measuring)
    }

    private func hopRow(_ h: Hop, last: Bool) -> some View {
        let c = color(h.status)
        return HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle().fill(c).frame(width: 12, height: 12)
                    .background(Circle().fill(c.opacity(0.18)).frame(width: 18, height: 18))
                    .padding(.top, 3)
                Rectangle().fill(last ? Color.clear : c.opacity(0.35)).frame(width: 2)
                    .frame(maxHeight: .infinity).frame(minHeight: 22).padding(.vertical, 4)
            }
            .frame(width: 18)
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(h.name).font(appFont(14, .semibold)).lineLimit(1)
                    Text(h.sub).font(appFont(12)).foregroundColor(t.ink2).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(h.ms.map { "\($0) мс" } ?? "—").font(appNum(14, .semibold)).foregroundColor(c).lineLimit(1)
                    Text(h.delta.map { "+\($0)" } ?? " ").font(appNum(11)).foregroundColor(t.ink2)
                }
            }
            .padding(.bottom, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func detailBox(_ v: RouteVerdict?) -> some View {
        let c = v.map(verdictColor) ?? t.ink2
        Text(v?.detail ?? "Проверяю роутер, провайдера, сервер и сайт — не дольше шести секунд.")
            .font(appFont(13))
            .foregroundColor(t.navInk)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.opacity(0.09)))
            .opacity(route.measuring && v != nil ? 0.55 : 1)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Rectangle().fill(t.line).frame(height: 1)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("VPN · \(model.modeName)").font(appFont(13, .semibold)).lineLimit(1)
                    Text(footSub).font(appNum(12)).foregroundColor(t.ink2).lineLimit(1)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button { openWindow() } label: { label("Открыть окно") }
                Button { model.measureRoute() } label: { label(route.measuring ? "Замеряю…" : "Замерить ещё раз") }
                    .disabled(route.measuring)
                    .opacity(route.measuring ? 0.6 : 1)
            }
            .buttonStyle(PressStyle())
        }
    }

    private var footSub: String {
        var s = (model.exits.info ?? ExitCatalog.fallback).host
        if let c = model.connectedSince, model.state == .ok || model.state == .slow {
            s += " · \(Format.duration(model.now.timeIntervalSince(c)))"
        }
        return s
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(appFont(13)).foregroundColor(t.ink).lineLimit(1)
            .frame(maxWidth: .infinity).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.tile))
    }
}
