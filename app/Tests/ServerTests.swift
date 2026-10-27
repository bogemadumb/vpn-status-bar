import Foundation

func runServerTests() {
    let healthJSON = Data("""
    {"xray": true, "nginx": true, "cpu_percent": 42.3, "load": [1.4091796875, 1.609375, 1.80615234375], "cpus": 2, "ram_used": 1968607232, "ram_total": 4106096640, "disk_free": 8722026496, "disk_total": 31615700992, "uptime_s": 5213620, "cert_not_after": "2026-12-12T18:59:20+00:00", "vnstat_month": {"iface": "eth0", "rx": 7310336811, "tx": 4764197011}}
    """.utf8)
    let now = ServerParse.date("2026-10-03T02:30:00+03:00")!
    guard case .success(let h) = ServerParse.health(healthJSON) else { check(false, "server: health parses"); return }
    check(h.xray && h.nginx && h.cpus == 2 && h.cpuPercent == 42.3 && h.load.count == 3, "server: health basic fields")
    check(h.ramUsed == 1968607232 && h.diskFree == 8722026496 && h.uptime == 5213620, "server: health big numbers survive")
    check(h.vnstat == VnstatMonth(iface: "eth0", rx: 7310336811, tx: 4764197011), "server: health vnstat month")
    check(ServerLogic.monthTotal(h) == 12074533822, "server: month total is rx+tx")
    check(ServerLogic.certDays(h, now: now) == 70, "server: cert days left")
    check(h.xrayVersion == nil, "server: xray version absent is nil")

    let noVn = Data(#"{"xray": false, "nginx": true, "cpu_percent": 99, "load": [3, 3, 3], "cpus": 2, "ram_used": 1, "ram_total": 2, "disk_free": 1, "disk_total": 100, "uptime_s": 5, "cert_not_after": null, "vnstat_month": null}"#.utf8)
    if case .success(let h2) = ServerParse.health(noVn) {
        check(h2.vnstat == nil && h2.certNotAfter == nil && !h2.xray, "server: health with nulls")
        let lv = ServerLogic.levels(h2, now: now)
        check(lv.xray == .alarm && lv.load == .warn && lv.cpu == .warn && lv.disk == .warn && lv.cert == .ok, "server: levels for bad health")
    } else { check(false, "server: health with nulls parses") }
    let lv = ServerLogic.levels(h, now: now)
    check(lv.xray == .ok && lv.load == .ok && lv.cpu == .ok && lv.ram == .ok && lv.disk == .ok && lv.cert == .ok, "server: levels for good health")
    var busy = h
    busy.load = [2.4, 2.0, 1.9]
    check(ServerLogic.levels(busy, now: now).load == .warn, "server: amber when load per core above 1")
    busy.load = [2.0, 2.0, 2.0]
    check(ServerLogic.levels(busy, now: now).load == .ok, "server: load per core exactly 1 is ok")
    let soon = ServerParse.date("2026-10-20T00:00:00+00:00")!
    var certH = h
    certH.certNotAfter = soon
    check(ServerLogic.levels(certH, now: now).cert == .warn, "server: cert amber under 21 days")
    certH.certNotAfter = ServerParse.date("2026-10-05T00:00:00+00:00")
    check(ServerLogic.levels(certH, now: now).cert == .alarm, "server: cert red under 7 days")
    check(ServerLogic.uptimeText(5213620) == "60 д 8 ч" && ServerLogic.uptimeText(3700) == "1 ч 1 мин", "server: uptime text")

    check({ if case .failure(.remote("command not allowed")) = ServerParse.health(Data(#"{"error": "command not allowed"}"#.utf8)) { return true }; return false }(), "server: remote error surfaces")
    check({ if case .failure(.badOutput) = ServerParse.health(Data("garbage".utf8)) { return true }; return false }(), "server: garbage is badOutput")
    check({ if case .failure(.badOutput) = ServerParse.health(Data(#"{"xray": true}"#.utf8)) { return true }; return false }(), "server: missing fields is badOutput")

    let statsJSON = Data(#"{"month": "2026-10", "users": [{"email": "home", "up": 51693, "down": 109123, "last_seen": "2026-10-03T02:16:42+03:00"}, {"email": "mac", "up": 770388277, "down": 2210965496, "last_seen": "2026-10-03T02:29:00+03:00"}, {"email": "test-del", "up": 589, "down": 3066, "last_seen": null}]}"#.utf8)
    let usersJSON = Data(#"{"users": [{"email": "home", "level": 0, "notorrent": false, "created": null}, {"email": "mac", "level": 0, "notorrent": false, "created": null}, {"email": "kaban", "level": 0, "notorrent": true, "created": "2026-10-03"}]}"#.utf8)
    guard case .success(let st) = ServerParse.stats(statsJSON), case .success(let us) = ServerParse.users(usersJSON) else { check(false, "server: stats/users parse"); return }
    check(st.month == "2026-10" && st.users.count == 3 && st.users["mac"]?.down == 2210965496, "server: stats parse")
    check(st.users["test-del"]?.lastSeen == nil && st.users["home"]?.lastSeen != nil, "server: stats null last_seen")
    check(us.count == 3 && us[2].notorrent && us[2].created == "2026-10-03" && us[0].created == nil, "server: users parse")
    let rows = ServerLogic.rows(users: us, stats: st, now: now)
    check(rows.map { $0.name } == ["home", "mac", "kaban"], "server: rows follow users, not stats (revoked test-del hidden)")
    check(rows[0].label == "Домашний сервер (Acer)" && rows[1].label == "Этот Мак" && rows[2].label == "Кабан", "server: rows labels")
    check(rows[1].online && !rows[0].online && !rows[2].online, "server: online only if seen under 5 minutes")
    check(rows[2].up == 0 && rows[2].down == 0 && rows[2].lastSeen == nil, "server: user without stats gets zeros")
    check(ServerLogic.limits(rows[2]) == "без торрентов" && ServerLogic.limits(rows[0]) == "нет", "server: limits text")
    let nostats = ServerLogic.rows(users: us, stats: nil, now: now)
    check(nostats.count == 3 && nostats.allSatisfy { !$0.online }, "server: rows without stats")

    check(ServerLogic.label("mac") == "Этот Мак" && ServerLogic.label("home") == "Домашний сервер (Acer)" && ServerLogic.label("phone") == "Телефон" && ServerLogic.label("kaban") == "Кабан", "labels: known names")
    check(ServerLogic.label("friend-1") == "friend-1", "labels: unknown name stays raw")
    check(ServerLogic.hint("friend-1", created: "2026-10-03") == "friend-1 · создан 2026-10-03" && ServerLogic.hint("friend-1", created: nil) == "friend-1", "labels: hint for new key")

    check(ServerLogic.validName("a") && ServerLogic.validName("test-ui") && ServerLogic.validName("a_b-9") && ServerLogic.validName("0abc"), "name: valid")
    check(ServerLogic.validName(String(repeating: "a", count: 32)) && !ServerLogic.validName(String(repeating: "a", count: 33)), "name: length 32 max")
    check(!ServerLogic.validName("") && !ServerLogic.validName("-a") && !ServerLogic.validName("_a"), "name: empty and bad first char")
    check(!ServerLogic.validName("Abc") && !ServerLogic.validName("a b") && !ServerLogic.validName("имя") && !ServerLogic.validName("a.b"), "name: uppercase, space, cyrillic, dot rejected")
    check(!ServerLogic.validName("abc\n") && !ServerLogic.validName("a;rm"), "name: newline and shell chars rejected")
    check(ServerLogic.nameError("", existing: []) == nil && ServerLogic.nameError("ok-name", existing: ["mac"]) == nil, "name: no error when fine or empty")
    check(ServerLogic.nameError("Bad", existing: []) != nil && ServerLogic.nameError("mac", existing: ["mac"]) == "Такой ключ уже есть", "name: errors for bad and duplicate")
    check(ServerLogic.args(add: "x", noTorrent: true) == ["add", "x", "--no-torrent"] && ServerLogic.args(add: "x", noTorrent: false) == ["add", "x"], "args: add command")

    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
    let n = ServerParse.date("2026-10-03T15:00:00+03:00")!
    func rel(_ iso: String?) -> String { ServerLogic.relative(iso.flatMap { ServerParse.date($0) }, now: n, calendar: cal) }
    check(rel(nil) == "не подключался", "relative: nil")
    check(rel("2026-10-03T14:58:00+03:00") == "сейчас" && rel("2026-10-03T15:00:30+03:00") == "сейчас", "relative: under 5 minutes is now")
    check(rel("2026-10-03T14:30:00+03:00") == "30 мин назад", "relative: minutes")
    check(rel("2026-10-03T12:00:00+03:00") == "3 ч назад", "relative: hours same day")
    check(rel("2026-10-02T22:10:00+03:00") == "вчера, 22:10", "relative: yesterday")
    check(rel("2026-10-02T23:30:00+03:00") == "вчера, 23:30", "relative: under 24h but previous day is yesterday")
    check(rel("2026-09-28T09:05:00+03:00") == "28.09, 09:05", "relative: older date")
    check(ServerLogic.isOnline(n.addingTimeInterval(-299), now: n) && !ServerLogic.isOnline(n.addingTimeInterval(-300), now: n) && !ServerLogic.isOnline(nil, now: n), "online: five minute window")

    check(ServerLogic.vnstatNote(now: ServerParse.date("2026-10-15T10:00:00+03:00")!, calendar: cal) == "с 03.10", "vnstat note: this month")
    check(ServerLogic.vnstatNote(now: ServerParse.date("2026-11-02T10:00:00+03:00")!, calendar: cal) == nil, "vnstat note: gone next month")

    check({ if case .success(let l) = ServerParse.link(Data(#"{"name": "x", "link": "vless://abc@h:443?x=1#x"}"#.utf8)) { return l.hasPrefix("vless://") }; return false }(), "server: link parse")
    check({ if case .failure(.remote("no such user")) = ServerParse.link(Data(#"{"error": "no such user"}"#.utf8)) { return true }; return false }(), "server: link error")
    check({ if case .failure(.badOutput) = ServerParse.link(Data(#"{"link": "http://x"}"#.utf8)) { return true }; return false }(), "server: non-vless link rejected")
    check({ if case .success(false) = ServerParse.ok(Data(#"{"ok": true, "restart_needed": false}"#.utf8)) { return true }; return false }(), "server: add ok parse")
    check({ if case .success(true) = ServerParse.ok(Data(#"{"ok": true, "restart_needed": true}"#.utf8)) { return true }; return false }(), "server: restart flag parse")
    check(ServerError.remote("user exists").text == "Такой ключ уже есть", "server: error text mapping")

    let samples = ["vless://example", "vless://11111111-2222-3333-4444-555555555555@vpn.example.org:443?encryption=none&security=tls&sni=vpn.example.org&type=ws&host=vpn.example.org&path=%2Fwsx#test"]
    for s in samples {
        if let img = QRCode.cgImage(s), let png = QRCode.pngData(img), let back = QRCode.image(fromPNG: png) {
            check(QRCode.decode(img) == s, "qr: in-memory round trip len \(s.count)")
            check(QRCode.decode(back) == s, "qr: png round trip len \(s.count)")
            check(img.width == img.height && img.width % 8 == 0, "qr: square, whole pixels per module")
        } else { check(false, "qr: render len \(s.count)") }
    }
}
