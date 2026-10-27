import Foundation

struct RouteInput {
    var netName = "сеть"
    var netNote = ""
    var mobile = false
    var gateway: String?
    var routerMs: Int?
    var providerMs: Int?
    var providerAddr: String?
    var providerViaHTTPS = false
    var vpsMs: Int?
    var siteMs: Int?
    var gstaticMs: Int?
    var tunnelUp = true
    var siteHost = AppConfig.shared.traceHost
    var exitTag: String?

    var exit: ExitInfo { exitTag.map(ExitCatalog.info) ?? ExitCatalog.fallback }
}

enum HopStatus { case ok, warn, unknown }

struct Hop: Identifiable {
    let id: String
    let name: String
    let sub: String
    let ms: Int?
    let delta: Int?
    let status: HopStatus
}

enum VerdictKind: Equatable {
    case ok, router, provider, server, site, serverDown, routerDown
}

struct RouteVerdict {
    let kind: VerdictKind
    let title: String
    let detail: String

    var isProblem: Bool { kind != .ok }
}

enum RouteLimits {
    static let router = 30
    static let provider = 60
    static let providerHTTPS = 250
    static let server = 80
    static let site = 300
}

enum RouteAnalysis {
    static func analyze(_ m: RouteInput) -> (hops: [Hop], verdict: RouteVerdict) {
        var hops: [Hop] = []
        hops.append(Hop(id: "mac", name: "Мак", sub: "этот компьютер", ms: 0, delta: nil, status: .ok))
        var prev = 0

        func step(_ ms: Int?) -> Int? {
            guard let ms = ms else { return nil }
            let d = max(0, ms - prev)
            prev = max(prev, ms)
            return d
        }

        let routerDelta = step(m.routerMs)
        let routerWarn = (m.routerMs ?? 0) > RouteLimits.router
        hops.append(Hop(id: "router", name: "Роутер", sub: m.netName, ms: m.routerMs, delta: routerDelta,
                        status: m.routerMs == nil ? .unknown : (routerWarn ? .warn : .ok)))

        let provDelta = m.providerViaHTTPS ? nil : step(m.providerMs)
        let provWarn = m.providerViaHTTPS
            ? (m.providerMs ?? 0) > RouteLimits.providerHTTPS
            : (provDelta ?? 0) > RouteLimits.provider
        let provSub: String = {
            if m.providerViaHTTPS, m.providerAddr != nil { return "до локального сайта напрямую" }
            let base = m.mobile ? "мобильная сеть" : "первый узел"
            if let a = m.providerAddr { return "\(base) · \(a)" }
            return m.mobile ? base : "не определён"
        }()
        hops.append(Hop(id: "provider", name: "Провайдер", sub: provSub, ms: m.providerMs, delta: provDelta,
                        status: m.providerMs == nil ? .unknown : (provWarn ? .warn : .ok)))

        let vpsDelta = step(m.vpsMs)
        let vpsWarn = (vpsDelta ?? 0) > RouteLimits.server
        let exitHop = exitNames(m.exit)
        hops.append(Hop(id: "vps", name: exitHop.name, sub: exitHop.sub, ms: m.vpsMs, delta: vpsDelta,
                        status: m.vpsMs == nil ? .unknown : (vpsWarn ? .warn : .ok)))

        let siteDelta = step(m.siteMs)
        let siteWarn = (siteDelta ?? 0) > RouteLimits.site
        var siteSub = "\(m.siteHost) через туннель"
        if !m.tunnelUp { siteSub = "VPN выключен" }
        else if m.siteMs == nil && m.gstaticMs != nil { siteSub = "\(m.siteHost) не отвечает" }
        else if let g = m.gstaticMs { siteSub += " · \(g) мс до generate_204" }
        hops.append(Hop(id: "site", name: "Сайт", sub: siteSub, ms: m.siteMs, delta: siteDelta,
                        status: m.siteMs == nil ? .unknown : (siteWarn ? .warn : .ok)))

        return (hops, verdict(m, routerDelta: routerDelta, provDelta: provDelta, vpsDelta: vpsDelta, siteDelta: siteDelta))
    }

    static func exitNames(_ e: ExitInfo) -> (name: String, sub: String) {
        (e.own ? "Твой VPS" : "Внешний сервер", "\(e.short), \(e.own ? "xray" : "внешний")")
    }

    private static func verdict(_ m: RouteInput, routerDelta: Int?, provDelta: Int?, vpsDelta: Int?, siteDelta: Int?) -> RouteVerdict {
        if m.routerMs == nil && m.vpsMs == nil && m.providerMs == nil {
            return RouteVerdict(kind: .routerDown, title: "Нет связи с сетью",
                                detail: "Ни роутер, ни сервер не отвечают. Проверь Wi‑Fi или кабель.")
        }
        if m.vpsMs == nil && (m.routerMs != nil || m.providerMs != nil) {
            return RouteVerdict(kind: .serverDown, title: "Сервер не отвечает",
                                detail: "Сеть до провайдера работает, а до сервера \(m.exit.host) соединение не открывается.")
        }
        var cands: [(VerdictKind, Double)] = []
        if let r = m.routerMs, r > RouteLimits.router { cands.append((.router, Double(r) / Double(RouteLimits.router))) }
        if let d = provDelta, d > RouteLimits.provider { cands.append((.provider, Double(d) / Double(RouteLimits.provider))) }
        if m.providerViaHTTPS, let p = m.providerMs, p > RouteLimits.providerHTTPS { cands.append((.provider, Double(p) / Double(RouteLimits.providerHTTPS))) }
        if let d = vpsDelta, d > RouteLimits.server { cands.append((.server, Double(d) / Double(RouteLimits.server))) }
        if let d = siteDelta, d > RouteLimits.site { cands.append((.site, Double(d) / Double(RouteLimits.site))) }
        guard let worst = cands.max(by: { $0.1 < $1.1 }) else {
            var parts: [String] = []
            if let r = m.routerMs { parts.append("роутер \(r) мс") }
            if let d = provDelta { parts.append("провайдер +\(d)") }
            if m.providerViaHTTPS, let p = m.providerMs { parts.append("локальный сайт напрямую \(p) мс") }
            if let d = vpsDelta { parts.append("сервер +\(d)") }
            return RouteVerdict(kind: .ok, title: "Всё в норме", detail: "Каждый участок в пределах нормы: " + parts.joined(separator: ", ") + ".")
        }
        let tail = " Значок не краснеет, пока сайты открываются."
        switch worst.0 {
        case .router:
            return RouteVerdict(kind: .router, title: "Тормозит сеть до роутера, не VPN",
                                detail: "Уже до роутера \(m.routerMs ?? 0) мс: \(m.netName). Дальше задержка растёт нормально." + tail)
        case .provider:
            let src = m.mobile ? "мобильная сеть" : m.netName
            let srv = vpsDelta.map { " Сервер добавляет \($0) мс — \($0 > RouteLimits.server ? "много" : "норма")." } ?? ""
            return RouteVerdict(kind: .provider, title: "Тормозит сеть до провайдера, не VPN",
                                detail: "Задержка набирается до провайдера (+\(provDelta ?? m.providerMs ?? 0) мс): \(src).\(srv)" + tail)
        case .server:
            return RouteVerdict(kind: .server, title: "Тормозит сервер",
                                detail: "Сеть до провайдера в порядке, но до сервера добавляется +\(vpsDelta ?? 0) мс. Нагрузка на VPS или канал до него.")
        default:
            return RouteVerdict(kind: .site, title: "Тормозит сайт, не VPN",
                                detail: "До сервера быстро, а от сервера до \(m.siteHost) +\(siteDelta ?? 0) мс.")
        }
    }
}

enum RouteConst {
    static var vps: String { AppConfig.shared.serverIP }
}
