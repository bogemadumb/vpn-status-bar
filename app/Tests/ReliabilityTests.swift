import Foundation

func runReliabilityTests() {
    let t0 = Date(timeIntervalSince1970: 2_000_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    var w = Watchdog()
    check(w.evaluate(intentOn: true, daemonRunning: true, apiOK: true, at: at(0)) == .none, "watchdog: healthy does nothing")
    check(w.evaluate(intentOn: true, daemonRunning: true, apiOK: false, at: at(1)) == .none, "watchdog: api down just started waits")
    check(w.evaluate(intentOn: true, daemonRunning: true, apiOK: false, at: at(59)) == .none, "watchdog: api down 58 s waits")
    check(w.evaluate(intentOn: true, daemonRunning: true, apiOK: false, at: at(61)) == .restart, "watchdog: api down 60 s restarts")
    check(w.attemptsInWindow(at: at(61)) == 1, "watchdog: attempt counted")
    check(w.evaluate(intentOn: true, daemonRunning: true, apiOK: false, at: at(70)) == .none, "watchdog: after restart waits again")

    w = Watchdog()
    _ = w.evaluate(intentOn: true, daemonRunning: true, apiOK: false, at: at(0))
    _ = w.evaluate(intentOn: true, daemonRunning: true, apiOK: true, at: at(30))
    check(w.evaluate(intentOn: true, daemonRunning: true, apiOK: false, at: at(61)) == .none, "watchdog: api recovery resets the 60 s clock")

    w = Watchdog()
    check(w.evaluate(intentOn: true, daemonRunning: false, apiOK: false, at: at(0)) == .none, "watchdog: core not running, grace first")
    check(w.evaluate(intentOn: true, daemonRunning: false, apiOK: false, at: at(11)) == .start, "watchdog: core not running with intent on starts")

    w = Watchdog()
    check(w.evaluate(intentOn: false, daemonRunning: false, apiOK: false, at: at(0)) == .none
          && w.evaluate(intentOn: false, daemonRunning: false, apiOK: false, at: at(500)) == .none, "watchdog: intent off never acts (core stopped)")
    check(w.evaluate(intentOn: false, daemonRunning: true, apiOK: false, at: at(1000)) == .none
          && w.evaluate(intentOn: false, daemonRunning: true, apiOK: false, at: at(2000)) == .none, "watchdog: intent off never acts (api down)")

    w = Watchdog()
    var acts: [WatchdogAction] = []
    for i in 0..<14 {
        acts.append(w.evaluate(intentOn: true, daemonRunning: true, apiOK: false, at: at(Double(i) * 40)))
    }
    check(acts.filter { $0 == .restart }.count == 3, "watchdog: at most 3 restarts in 10 minutes")
    check(acts.filter { $0 == .giveUp }.count == 1, "watchdog: gives up exactly once, then only notifies")
    let later = w.evaluate(intentOn: true, daemonRunning: true, apiOK: false, at: at(14 * 40 + 700))
    check(later == .none || later == .restart, "watchdog: window expires")
    check(w.attemptsInWindow(at: at(14 * 40 + 700)) <= 1, "watchdog: old attempts leave the window")

    w = Watchdog()
    var spaced = 0
    for i in 0..<20 where w.evaluate(intentOn: true, daemonRunning: false, apiOK: false, at: at(Double(i) * 3)) == .start { spaced += 1 }
    check(spaced <= 2, "watchdog: failed starts are spaced by 30 s")

    check(IntentSync.initial(stored: nil, daemonRunning: true), "intent: default on when core runs at first launch")
    check(!IntentSync.initial(stored: nil, daemonRunning: false), "intent: default off when core is stopped at first launch")
    check(!IntentSync.initial(stored: false, daemonRunning: true), "intent: stored value wins")
    check(IntentSync.next(current: false, daemonRunning: true, daemonDisabled: false, busy: false), "intent: external vpn on turns intent on")
    check(!IntentSync.next(current: false, daemonRunning: true, daemonDisabled: false, busy: true), "intent: busy keeps value")
    check(!IntentSync.next(current: true, daemonRunning: false, daemonDisabled: true, busy: false), "intent: disabled daemon means deliberate off")
    check(IntentSync.next(current: true, daemonRunning: false, daemonDisabled: false, busy: false), "intent: crashed core keeps intent on")
    check(IntentSync.isDisabled("disabled services = {\n\t\"dev.vpnstatusbar.singbox\" => disabled\n\t\"x\" => enabled\n}"), "print-disabled: disabled parsed")
    check(!IntentSync.isDisabled("\t\"dev.vpnstatusbar.singbox\" => enabled\n"), "print-disabled: enabled parsed")
    check(!IntentSync.isDisabled("\t\"other\" => disabled\n"), "print-disabled: other label ignored")

    var rl = RateLimiter()
    check(rl.allow("down", at: at(0)), "rate limit: first allowed")
    check(!rl.allow("down", at: at(599)), "rate limit: same kind within 10 min blocked")
    check(rl.allow("leak", at: at(10)), "rate limit: other kind independent")
    check(rl.allow("down", at: at(601)), "rate limit: allowed after 10 min")

    var dt = DropTracker()
    check(dt.update(isDrop: false, recovered: true, startHint: nil, at: at(0)) == nil, "drops: nothing when healthy")
    check(dt.update(isDrop: true, recovered: false, startHint: at(-30), at: at(0)) == .opened(start: at(-30)), "drops: opens with start hint")
    check(dt.update(isDrop: true, recovered: false, startHint: at(-30), at: at(5)) == nil, "drops: no double open")
    check(dt.update(isDrop: false, recovered: false, startHint: nil, at: at(10)) == nil, "drops: stays open until recovered")
    check(dt.update(isDrop: false, recovered: true, startHint: nil, at: at(90)) == .closed(start: at(-30), end: at(90)), "drops: closes with duration")
    check(DropReason.classify(daemonRunning: false, apiOK: false, netChangedRecently: true).kind == "core", "drop reason: core stopped")
    check(DropReason.classify(daemonRunning: true, apiOK: false, netChangedRecently: false).kind == "core", "drop reason: api silent")
    check(DropReason.classify(daemonRunning: true, apiOK: true, netChangedRecently: true).kind == "net", "drop reason: network change")
    check(DropReason.classify(daemonRunning: true, apiOK: true, netChangedRecently: false).kind == "server", "drop reason: server")

    let tr = "fl=29f\nh=example.org\nip=203.0.113.10\nts=1.2\nloc=FI\ncolo=HEL\n"
    check(LeakLogic.parseTrace(tr)["loc"] == "FI" && LeakLogic.parseTrace(tr)["ip"] == "203.0.113.10", "trace parser: loc and ip")
    check(LeakLogic.parseTrace("garbage\n\n=x\nloc = RU \r\n")["loc"] == "RU", "trace parser: tolerates junk and spaces")
    check(LeakLogic.geo(.response(status: 200, body: tr)).status == .ok, "geo: FI and VPS ip is ok")
    check(LeakLogic.geo(.response(status: 200, body: "ip=198.51.100.68\nloc=RU\n")).status == .fail, "geo: RU is a leak")
    check(LeakLogic.geo(.response(status: 200, body: "ip=9.9.9.9\nloc=FI\n")).status == .warn, "geo: FI with foreign ip is a warning")
    check(LeakLogic.geo(.failed("timeout")).status == .warn, "geo: no answer is a warning, not a leak")
    check(LeakLogic.geo(.response(status: 403, body: "")).status == .warn, "geo: 403 is not a leak")
    check(LeakLogic.ipv6(.failed("no route")).status == .ok, "ipv6: unreachable is ok")
    check(LeakLogic.ipv6(.response(status: 200, body: "ip=2a00::1\nloc=FI\n")).status == .ok, "ipv6: FI is ok")
    check(LeakLogic.ipv6(.response(status: 200, body: "ip=2a00::1\nloc=RU\n")).status == .fail, "ipv6: artificial leak (RU) is caught")
    check(LeakLogic.dns(.response(status: 200, body: tr)).status == .ok, "dns: FI via tunnel ok")
    check(LeakLogic.dns(.response(status: 200, body: "loc=RU\n")).status == .fail, "dns: RU is a leak")
    check(LeakLogic.site(id: "local", name: "x", .response(status: 302, body: "")).status == .ok, "site: 302 opens")
    check(LeakLogic.site(id: "local", name: "x", .response(status: 503, body: "")).status == .fail, "site: 503 does not open")
    check(LeakLogic.site(id: "local", name: "x", .failed("timeout")).status == .fail, "site: timeout does not open")

    let good = LeakFetches(geo: .response(status: 200, body: tr), ipv6: .failed("x"), dns: .response(status: 200, body: tr),
                           local: .response(status: 302, body: ""), external: .response(status: 200, body: ""))
    let items = LeakLogic.evaluate(good, mode: "Rule")
    check(!LeakLogic.verdict(items).leak, "verdict: clean run has no leak")
    check(LeakLogic.chips(items) == [Chip(text: "локальные сайты открываются", status: .ok),
                                     Chip(text: "внешние сайты открываются", status: .ok),
                                     Chip(text: "утечек нет", status: .ok)], "chips: all good")
    check(LeakLogic.externalAddress(items) == "FI · 203.0.113.10", "external address from geo check")
    var bad = good
    bad.ipv6 = .response(status: 200, body: "ip=2a00::1\nloc=RU\n")
    let badItems = LeakLogic.evaluate(bad, mode: "Rule")
    check(LeakLogic.verdict(badItems).leak && LeakLogic.verdict(badItems).detail.contains("IPv6"), "verdict: ipv6 leak detected")
    check(LeakLogic.chips(badItems).last == Chip(text: "утечка", status: .fail), "chips: leak chip")
    var external = good
    external.external = .failed("timeout")
    check(LeakLogic.chips(LeakLogic.evaluate(external, mode: "Rule"))[1].status == .fail, "chips: external site down")
    var direct = good
    direct.dns = .response(status: 200, body: "loc=RU\n")
    direct.ipv6 = .response(status: 200, body: "loc=RU\n")
    check(!LeakLogic.verdict(LeakLogic.evaluate(direct, mode: "Direct")).leak, "verdict: direct mode does not flag ipv6/dns as leaks")
    check(LeakLogic.verdict(LeakLogic.evaluate(direct, mode: "Rule")).leak, "verdict: same data in smart mode is a leak")
    check(LeakLogic.chips(LeakLogic.skipped("VPN выключен")).isEmpty, "chips: hidden when VPN is off")
    check(LeakLogic.chips(LeakLogic.pending()).first?.status == .pending, "chips: pending before first run")
    check(SpeedMath.mbps(bytes: 25_000_000, seconds: 2) == 12.5 && SpeedMath.format(12.5) == "12,5", "speed math")

    guard let db = HistoryDB(path: ":memory:") else { check(false, "sqlite opens in memory"); return }
    check(true, "sqlite opens in memory")
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let base = (Int(now.timeIntervalSince1970) / 3600) * 3600
    for i in 0..<30 {
        db.insertSample(ts: Date(timeIntervalSince1970: Double(base - 1800 + i * 10)), down: 1000, up: 100, delay: 50 + i, state: "ok")
    }
    for i in 0..<6 {
        db.insertSample(ts: Date(timeIntervalSince1970: Double(base - 600 + i * 10)), down: 0, up: 0, delay: nil, state: "down")
    }
    check(db.sampleCount() == 36, "sqlite: samples inserted")
    let hour = db.series(.hour, now: Date(timeIntervalSince1970: Double(base)))
    check(hour.count == 60, "rollup: hour has 60 buckets")
    let filled = hour.compactMap { $0 }
    check(filled.count == 6, "rollup: 5 minutes of samples plus 1 drop minute fill 6 buckets (got \(filled.count))")
    check(filled.first.map { $0.down == 1000 && $0.up == 100 } ?? false, "rollup: bucket averages")
    check(filled.contains { $0.drop } && filled.contains { !$0.drop }, "rollup: drop flag only where state is down")
    check(hour.last! == nil, "rollup: empty bucket stays nil")
    let a = db.averageDelay(since: Date(timeIntervalSince1970: Double(base - 3600)))
    check(a != nil && abs(a! - 64.5) < 0.01, "rollup: average delay ignores nulls")
    check(db.series(.day, now: now).count == 96 && db.series(.month, now: now).count == 120, "rollup: day and month shapes")
    db.insertSample(ts: Date(timeIntervalSince1970: Double(base - 40 * 86400)), down: 1, up: 1, delay: 1, state: "ok")
    db.prune(now: Date(timeIntervalSince1970: Double(base)))
    check(db.sampleCount() == 36, "retention: 40-day-old sample pruned, recent kept")

    var tr1 = TrafficTracker()
    let c1 = [ConnSnap(id: "a", process: "Safari", via: "vps", down: 1000, up: 10),
              ConnSnap(id: "b", process: "curl", via: "direct", down: 500, up: 5)]
    check(tr1.update(c1).isEmpty, "tracker: first poll only sets baseline")
    let c2 = [ConnSnap(id: "a", process: "Safari", via: "vps", down: 3000, up: 30),
              ConnSnap(id: "b", process: "curl", via: "direct", down: 500, up: 5),
              ConnSnap(id: "c", process: "Safari", via: "vps", down: 700, up: 7)]
    let d2 = tr1.update(c2)
    check(d2.count == 1 && d2[0].process == "Safari" && d2[0].down == 2700 && d2[0].up == 27, "tracker: deltas, new connection counted, idle skipped")
    check(tr1.update([ConnSnap(id: "a", process: "Safari", via: "vps", down: 3500, up: 30)]).first?.down == 500, "tracker: closed connections dropped, delta for the survivor")
    check(tr1.update([ConnSnap(id: "a", process: "Safari", via: "vps", down: 100, up: 0)]).isEmpty, "tracker: counter going backwards never gives negative")

    let day = DayKey.of(now)
    db.addTraffic(day: day, [TrafficDelta(process: "Safari", via: "vps", down: 8000, up: 1000),
                             TrafficDelta(process: "Safari", via: "direct", down: 500, up: 0),
                             TrafficDelta(process: "curl", via: "direct", down: 300, up: 0),
                             TrafficDelta(process: "Telegram", via: "local", down: 9_999_999, up: 0)])
    db.addTraffic(day: day, [TrafficDelta(process: "Safari", via: "vps", down: 2000, up: 0)])
    db.addTraffic(day: "2001-01-01", [TrafficDelta(process: "Old", via: "vps", down: 77, up: 0)])
    let rowsToday = db.trafficRows(day: day, limit: 8)
    check(rowsToday.count == 2 && rowsToday[0].process == "Safari" && rowsToday[0].vps == 11000 && rowsToday[0].direct == 500, "sqlite: app_traffic upsert accumulates per via")
    check(rowsToday[1].process == "curl" && rowsToday[1].direct == 300 && rowsToday[1].vps == 0, "sqlite: ordering by total, local excluded")
    check(db.trafficRows(day: day, limit: 1).count == 1, "sqlite: limit respected")
    let tot = db.trafficTotals(day: day)
    check(tot.vps == 11000 && tot.direct == 800, "sqlite: day totals split by route")
    check(db.trafficTotals(day: "2099-01-01").vps == 0, "sqlite: empty day totals are zero")

    let id1 = db.insertEvent(start: at(0), end: nil, kind: "core", detail: "ядро не отвечало")
    check(id1 > 0 && db.events(limit: 10).first?.end == nil, "events: open event stored")
    db.closeEvent(id: id1, end: at(125))
    check(db.events(limit: 10).first?.duration == 125, "events: close sets duration")
    db.insertEvent(start: at(500), end: at(500), kind: "speed", detail: "12,5 МБ/с")
    db.insertEvent(start: at(900), end: nil, kind: "server", detail: "x")
    check(db.events(limit: 10).map { $0.kind } == ["server", "speed", "core"], "events: newest first")
    check(db.events(limit: 10, excluding: ["speed"]).map { $0.kind } == ["server", "core"], "events: kind filter")
    check(db.events(limit: 1).count == 1, "events: limit")
    db.closeStaleDrops(at: at(1000))
    check(db.events(limit: 10).first?.end != nil && db.events(limit: 10).first!.detail.contains("перезапущено"), "events: stale open drop closed on start")
    check(ChartRange.hour.start(now: now) % 60 == 0 && ChartRange.month.start(now: now) % 21600 == 0, "ranges: starts are step aligned")
}
