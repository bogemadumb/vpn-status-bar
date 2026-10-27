import SwiftUI

enum Smooth {
    static func values(_ v: [Double]) -> [Double] {
        guard v.count > 2 else { return v }
        var out = v
        for i in 1..<(v.count - 1) { out[i] = (v[i - 1] + 2 * v[i] + v[i + 1]) / 4 }
        return out
    }
}

struct SparkShape: Shape {
    let values: [Double]
    let maxValue: Double
    let closed: Bool

    func path(in r: CGRect) -> Path {
        var p = Path()
        let n = values.count
        let step = r.width / CGFloat(VPNModel.historyLimit - 1)
        let top = r.minY + 5, bottom = r.maxY - 3
        func y(_ v: Double) -> CGFloat {
            let k = min(1, max(0, v / maxValue))
            return bottom - CGFloat(k) * (bottom - top)
        }
        guard n > 1 else {
            p.move(to: CGPoint(x: r.minX, y: bottom))
            p.addLine(to: CGPoint(x: r.maxX, y: bottom))
            if closed { p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath() }
            return p
        }
        let x0 = r.maxX - CGFloat(n - 1) * step
        let pts = (0..<n).map { CGPoint(x: x0 + CGFloat($0) * step, y: y(values[$0])) }
        p.move(to: pts[0])
        for i in 0..<(n - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, n - 1)]
            let lo = min(p1.y, p2.y), hi = max(p1.y, p2.y)
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: min(hi, max(lo, p1.y + (p2.y - p0.y) / 6)))
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: min(hi, max(lo, p2.y - (p3.y - p1.y) / 6)))
            p.addCurve(to: p2, control1: c1, control2: c2)
        }
        if closed {
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: x0, y: r.maxY))
            p.closeSubpath()
        }
        return p
    }
}

struct Sparkline: View {
    @Environment(\.theme) private var t
    let down: [Double]
    let up: [Double]
    let color: Color
    let upColor: Color

    static let floorBps = 100_000.0

    private var axisMax: Double {
        max(down.max() ?? 0, up.max() ?? 0, Self.floorBps)
    }

    var body: some View {
        let m = axisMax
        ZStack(alignment: .topLeading) {
            SparkShape(values: Smooth.values(down), maxValue: m, closed: true).fill(color.opacity(0.14))
            SparkShape(values: Smooth.values(down), maxValue: m, closed: false)
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            SparkShape(values: Smooth.values(up), maxValue: m, closed: false)
                .stroke(upColor, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            Text("макс \(Format.axis(m))")
                .font(appNum(10))
                .foregroundColor(t.ink2)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(t.bg.opacity(0.6)))
                .padding(4)
        }
    }
}

struct ConfirmOff: View {
    @EnvironmentObject private var model: VPNModel
    @Environment(\.theme) private var t
    var compact = false

    private var question: some View {
        Text("Выключить? Все активные соединения оборвутся")
            .font(appFont(13, .semibold))
            .foregroundColor(t.ink)
            .multilineTextAlignment(compact ? .leading : .center)
            .lineLimit(2)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button { model.confirmOff() } label: {
                Text("Выключить")
                    .font(appFont(13, .semibold))
                    .foregroundColor(t.btnFg)
                    .padding(.horizontal, compact ? 16 : 0)
                    .frame(maxWidth: compact ? nil : .infinity)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(t.alarm))
            }
            Button { model.cancelOff() } label: {
                Text("Отмена")
                    .font(appFont(13))
                    .foregroundColor(t.ink)
                    .padding(.horizontal, compact ? 16 : 0)
                    .frame(maxWidth: compact ? nil : .infinity)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(t.tile))
            }
        }
        .buttonStyle(PressStyle())
    }

    var body: some View {
        if compact {
            HStack(spacing: 16) {
                question
                Spacer(minLength: 8)
                buttons
            }
        } else {
            VStack(spacing: 8) {
                question
                buttons
            }
        }
    }
}

struct ModeSegments: View {
    @EnvironmentObject private var model: VPNModel
    @Environment(\.theme) private var t
    var windowStyle = false
    private let names = ["Раздельный", "Всё через VPS", "Напрямую"]
    private let modes = ["Rule", "Global", "Direct"]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                let selected = model.modeIndex == i
                Button { model.setMode(modes[i]) } label: {
                    Text(names[i])
                        .font(appFont(13, selected ? .semibold : .regular))
                        .foregroundColor(selected ? t.ink : t.ink3)
                        .lineLimit(1)
                        .padding(.horizontal, windowStyle ? 14 : 0)
                        .frame(maxWidth: windowStyle ? nil : .infinity)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selected ? (windowStyle ? t.card : t.tileSelected) : Color.clear)
                                .shadow(color: selected ? t.shadow : .clear,
                                        radius: t.isDark ? 6 : 4, x: 0, y: t.isDark ? 3 : 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(windowStyle ? t.bg2 : t.tile))
        .opacity(model.apiOK ? 1 : 0.55)
        .allowsHitTesting(model.apiOK)
        .animation(.easeOut(duration: 0.35), value: model.modeIndex)
        .help(model.apiOK ? "Раздельная маршрутизация: локальные сайты напрямую, остальное через VPS. Всё через VPS: весь трафик в туннель. Напрямую: мимо туннеля, закреплённые домены всё равно через VPS." : "Ядро не отвечает")
    }
}
