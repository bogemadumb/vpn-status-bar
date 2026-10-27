import Foundation

func runExitTests() {
    let fin = ExitCatalog.info("fin")
    check(fin.flag == "\u{1F1EB}\u{1F1EE}" && fin.country == "Финляндия" && fin.owner == "свой" && fin.own, "exit map: fin")
    check(fin.label == "Финляндия (свой)" && fin.short == "\u{1F1EB}\u{1F1EE} Финляндия" && fin.noun == "VPS", "exit map: fin labels")
    let nl = ExitCatalog.info("ext-nl"), lt = ExitCatalog.info("ext-lt"), se = ExitCatalog.info("ext-se")
    check(nl.country == "Нидерланды" && lt.country == "Литва" && se.country == "Швеция", "exit map: ext countries")
    check(nl.flag == "\u{1F1F3}\u{1F1F1}" && lt.flag == "\u{1F1F1}\u{1F1F9}" && se.flag == "\u{1F1F8}\u{1F1EA}", "exit map: ext flags")
    check(!nl.own && nl.owner == "внешний" && nl.label == "Нидерланды (внешний)" && se.adjective == "Шведский", "exit map: ext owner and labels")
    check(ExitCatalog.list.map { $0.tag } == ["fin", "ext-nl", "ext-lt", "ext-se"], "exit map: catalog order")
    check(ExitCatalog.list.allSatisfy { !$0.host.isEmpty && $0.port == 443 }, "exit map: hosts for route probe")
    let unk = ExitCatalog.info("zzz")
    check(unk.country == "zzz" && unk.label == "zzz" && !unk.own && unk.owner.isEmpty, "exit map: unknown tag degrades to tag")

    check(ExitLogic.resolve(vpsNow: "auto", autoNow: "fin") == ActiveExit(tag: "fin", auto: true), "exit resolve: auto -> urltest pick")
    check(ExitLogic.resolve(vpsNow: "auto", autoNow: "ext-se") == ActiveExit(tag: "ext-se", auto: true), "exit resolve: auto -> ext")
    check(ExitLogic.resolve(vpsNow: "ext-lt", autoNow: "fin") == ActiveExit(tag: "ext-lt", auto: false), "exit resolve: pinned ignores auto")
    check(ExitLogic.resolve(vpsNow: "auto", autoNow: nil) == nil, "exit resolve: auto without pick is unknown")
    check(ExitLogic.resolve(vpsNow: "auto", autoNow: "auto") == nil, "exit resolve: auto loop is unknown")
    check(ExitLogic.resolve(vpsNow: nil, autoNow: "fin") == nil && ExitLogic.resolve(vpsNow: "", autoNow: "fin") == nil, "exit resolve: no selector state")

    check(ExitLogic.chainExit(["ext-se", "auto", "vps"]) == "ext-se", "exit chain: auto path")
    check(ExitLogic.chainExit(["fin", "vps"]) == "fin", "exit chain: pinned path")
    check(ExitLogic.chainExit(["direct"]) == nil && ExitLogic.chainExit([]) == nil, "exit chain: direct has no exit")
    check(ExitLogic.chainExit(["auto", "vps"]) == nil && ExitLogic.chainExit(["vps"]) == nil, "exit chain: no concrete server")
    check(ConnLogic.route(chains: ["ext-se", "auto", "vps"], rule: "final", destIP: "1.1.1.1") == .vps, "exit chain: still routes as vps")

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func ts(_ ago: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: now.addingTimeInterval(-ago))
    }
    func proxy(_ delay: Int, _ ago: Double) -> [String: Any] { ["history": [["time": ts(ago), "delay": delay]]] }
    let body: [String: Any] = ["proxies": [
        "vps": ["type": "Selector", "now": "auto", "all": ["auto", "fin"]],
        "auto": ["type": "URLTest", "now": "ext-se"],
        "fin": proxy(0, 10),
        "ext-nl": proxy(103, 10),
        "ext-lt": proxy(132, 500),
        "ext-se": proxy(51, 5),
    ]]
    let snap = ExitLogic.snapshot(body, now: now)
    check(snap.hasSelector && snap.active == ActiveExit(tag: "ext-se", auto: true), "exit snapshot: active via auto")
    check(snap.pings["ext-se"] == .ms(51) && snap.pings["ext-nl"] == .ms(103), "exit snapshot: fresh pings")
    check(snap.pings["fin"] == .down, "exit snapshot: zero delay is down")
    check(snap.pings["ext-lt"] == .unknown, "exit snapshot: stale history is unknown")
    var noHist = body
    var px = noHist["proxies"] as! [String: Any]
    px["ext-nl"] = ["name": "ext-nl"]
    px["vps"] = ["type": "Selector", "now": "fin"]
    noHist["proxies"] = px
    let s2 = ExitLogic.snapshot(noHist, now: now)
    check(s2.pings["ext-nl"] == .unknown && s2.active == ActiveExit(tag: "fin", auto: false), "exit snapshot: no history and pinned")
    let plain = ExitLogic.snapshot(["proxies": ["vps": ["type": "VLESS"]]], now: now)
    check(!plain.hasSelector && plain.active == nil && plain.pings.isEmpty, "exit snapshot: plain outbound is not a selector")
    check(!ExitLogic.snapshot([:], now: now).hasSelector, "exit snapshot: empty body")

    let merged = ExitLogic.merge(passive: ["fin": .unknown, "ext-nl": .ms(100)],
                                 probed: ["fin": (.ms(90), now.addingTimeInterval(-5)), "ext-nl": (.down, now.addingTimeInterval(-60))], now: now)
    check(merged["fin"] == .ms(90) && merged["ext-nl"] == .ms(100), "exit merge: fresh probe wins, old probe ignored")

    let a = ActiveExit(tag: "fin", auto: true), b = ActiveExit(tag: "ext-se", auto: true)
    check(ExitLogic.change(prev: nil, next: b) == nil && ExitLogic.change(prev: a, next: nil) == nil, "exit change: nothing without both sides")
    check(ExitLogic.change(prev: a, next: a) == nil, "exit change: same exit is no change")
    let ch = ExitLogic.change(prev: a, next: b)
    check(ch?.tagChanged == true, "exit change: server switch")
    let pin = ExitLogic.change(prev: a, next: ActiveExit(tag: "fin", auto: false))
    check(pin != nil && pin?.tagChanged == false, "exit change: pin on same server is mode-only")

    let n1 = ExitLogic.notification(ch!, fromDown: true)
    check(n1.body == "Финский VPS не отвечает → Швеция (внешний)" && n1.title == "VPN: выход переключён", "exit notice: failover text")
    check(ExitLogic.notification(ch!, fromDown: false).body == "Финляндия (свой) → Швеция (внешний)", "exit notice: slow switch text")
    let back = ExitLogic.notification(ExitLogic.change(prev: b, next: a)!, fromDown: false)
    check(back.title == "VPN: выход снова свой" && back.body == "Выход вернулся: Швеция (внешний) → Финляндия (свой)", "exit notice: back to own")
    let bb = ExitLogic.notification(ExitLogic.change(prev: ActiveExit(tag: "ext-nl", auto: true), next: b)!, fromDown: true)
    check(bb.body == "Нидерландский сервер не отвечает → Швеция (внешний)", "exit notice: ext to ext")
    check(ExitLogic.detail(ch!, byUser: false) == "Финляндия (свой) → Швеция (внешний) · автоматически", "exit detail: auto switch")
    check(ExitLogic.detail(ExitLogic.change(prev: a, next: ActiveExit(tag: "ext-lt", auto: false))!, byUser: true) == "Финляндия (свой) → Литва (внешний) · закреплён вручную", "exit detail: manual pin")
    check(ExitLogic.detail(pin!, byUser: true) == "закреплён: Финляндия (свой)", "exit detail: pin same server")
    check(ExitLogic.detail(ExitLogic.change(prev: ActiveExit(tag: "fin", auto: false), next: a)!, byUser: true) == "автовыбор: Финляндия (свой)", "exit detail: back to auto")

    check(ExitLogic.direction("fin") == "exit-own" && ExitLogic.direction("ext-nl") == "exit-ext", "exit direction keys")
    var gate = RateLimiter()
    let t0 = Date(timeIntervalSince1970: 1000)
    check(gate.allow("exit-ext", at: t0, interval: 60), "exit debounce: first notice goes out")
    check(!gate.allow("exit-ext", at: t0.addingTimeInterval(30), interval: 60), "exit debounce: second within a minute is held")
    check(gate.allow("exit-own", at: t0.addingTimeInterval(31), interval: 60), "exit debounce: other direction is independent")
    check(gate.allow("exit-ext", at: t0.addingTimeInterval(61), interval: 60), "exit debounce: allowed after a minute")
    check(!gate.allow("exit-own", at: t0.addingTimeInterval(80), interval: 60), "exit debounce: own held 49 s after its last notice")
    var dflt = RateLimiter()
    check(dflt.allow("leak", at: t0) && !dflt.allow("leak", at: t0.addingTimeInterval(300)) && dflt.allow("leak", at: t0.addingTimeInterval(601)), "exit debounce: default 10 min limiter unchanged")

    check(ExitLogic.pingText(.ms(95)) == "95 мс" && ExitLogic.pingText(.down) == "не отвечает" && ExitLogic.pingText(nil) == "—", "exit ping text")
    let plural = [0, 1, 3, 5, 11, 22].map(ExitLogic.switchesText)
    check(plural == ["0 переключений за сутки", "1 переключение за сутки", "3 переключения за сутки", "5 переключений за сутки",
                     "11 переключений за сутки", "22 переключения за сутки"], "exit switches plural")

    var ri = RouteInput()
    check(ri.exit.tag == "fin", "route: no exit tag falls back to own")
    ri.exitTag = "ext-se"
    let h = RouteAnalysis.analyze(ri).hops.first { $0.id == "vps" }
    check(h?.name == "Внешний сервер" && h?.sub == "\u{1F1F8}\u{1F1EA} Швеция, внешний", "route: hop shows real exit")
    let h0 = RouteAnalysis.analyze(RouteInput()).hops.first { $0.id == "vps" }
    check(h0?.name == "Твой VPS" && h0?.sub == "\u{1F1EB}\u{1F1EE} Финляндия, xray", "route: own exit hop")
    var down = RouteInput(routerMs: 5, exitTag: "ext-nl")
    down.vpsMs = nil
    check(RouteAnalysis.analyze(down).verdict.detail.contains("nl.example.net"), "route: server-down verdict names real host")
}
