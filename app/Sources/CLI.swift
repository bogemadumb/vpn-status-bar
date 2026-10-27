import Foundation
import UserNotifications

enum CLI {
    static func probeRoute() {
        StateLog.enabled = false
        let client = CoreClient()
        Task {
            let up = (try? await client.version()) != nil
            for round in 1...2 {
                let t0 = Date()
                let r = await RouteProbe.measure(client: client, tunnelUp: up, mobile: false)
                print("round \(round): total \(String(format: "%.2f", Date().timeIntervalSince(t0))) s, tunnel_api=\(up)")
                let a = RouteAnalysis.analyze(r)
                for h in a.hops {
                    print("  \(h.name) | \(h.sub) | ms=\(h.ms.map(String.init) ?? "-") delta=\(h.delta.map(String.init) ?? "-") \(h.status)")
                }
                print("  verdict: \(a.verdict.title) | \(a.verdict.detail)")
            }
            exit(0)
        }
        dispatchMain()
    }

    static func probeConns() {
        StateLog.enabled = false
        let client = CoreClient()
        Task {
            do {
                for c in try await client.connections() {
                    let route = ConnLogic.route(chains: c.chains, rule: c.rule, destIP: c.destIP)
                    let app = ConnLogic.processName(c.processPath)
                    let host = ConnLogic.hostName(host: c.host, ip: c.destIP, port: c.destPort)
                    print("\(app.isEmpty ? "-" : app) | \(host) | \(route.label) | \(ConnLogic.humanRule(c.rule)) | raw=\(c.rule)")
                }
            } catch { print("error \(error)") }
            exit(0)
        }
        dispatchMain()
    }

    static func addDirect(_ url: String) {
        guard let host = RuleDetect.hostFromURL(url), let rule = SiteRule.forHost(host) else {
            print("no host in \(url)"); exit(1)
        }
        do {
            let changed = try RuleFiles().add(rule.value, kind: rule.kind, target: .direct)
            print("url=\(url) host=\(host) rule=\(rule.kind.rawValue):\(rule.value) target=direct changed=\(changed)")
        } catch { print("error \(error)"); exit(1) }
        exit(0)
    }

    static func rule(add: Bool, _ value: String, _ target: String) {
        guard let t = RuleTarget(rawValue: target), let p = RuleDetect.parse(value) else {
            print("bad input"); exit(1)
        }
        do {
            if add {
                let changed = try RuleFiles().add(p.value, kind: p.kind, target: t)
                print("added \(p.kind.rawValue):\(p.value) -> \(t.rawValue) changed=\(changed)")
            } else {
                try RuleFiles().remove(UserRule(target: t, kind: p.kind, value: p.value))
                print("removed \(p.kind.rawValue):\(p.value) from \(t.rawValue)")
            }
        } catch { print("error \(error)"); exit(1) }
        exit(0)
    }

    static func mode(_ m: String) {
        let client = CoreClient()
        Task {
            do {
                try await client.setMode(m)
                let c = try await client.configs()
                print("mode now \(c.mode)")
            } catch { print("error \(error)") }
            exit(0)
        }
        dispatchMain()
    }

    static func probeLeaks() {
        StateLog.enabled = false
        let client = CoreClient()
        Task {
            let mode = (try? await client.configs().mode) ?? "Rule"
            let t0 = Date()
            let items = await LeakProbe.run(mode: mode)
            print("mode=\(mode) took \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
            for i in items { print("\(i.id) | \(i.name) | \(i.status.rawValue) | \(i.text)") }
            let v = LeakLogic.verdict(items)
            print("leak=\(v.leak) \(v.detail)")
            print("chips: " + LeakLogic.chips(items).map { "\($0.text) [\($0.status.rawValue)]" }.joined(separator: ", "))
            exit(0)
        }
        dispatchMain()
    }

    static func speedTest() {
        StateLog.enabled = false
        let tester = SpeedTester()
        Task {
            let r = await tester.run { b, s in
                print("progress \(Int(b / 1_000_000)) MB \(SpeedMath.format(SpeedMath.mbps(bytes: b, seconds: s))) MB/s")
            }
            if let r = r {
                print("RESULT \(SpeedMath.format(SpeedMath.mbps(bytes: r.bytes, seconds: r.seconds))) MB/s, \(Int(r.bytes)) bytes in \(String(format: "%.2f", r.seconds)) s")
            } else { print("RESULT failed") }
            exit(0)
        }
        dispatchMain()
    }

    static func notifyStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            print("authorizationStatus=\(s.authorizationStatus.rawValue) (0 notDetermined, 1 denied, 2 authorized, 3 provisional) alert=\(s.alertSetting.rawValue)")
            exit(0)
        }
        dispatchMain()
    }

    #if !CLIENT_EDITION
    static func testKeys() {
        StateLog.enabled = false
        let client = ServerClient()
        Task {
            async let u = client.call(["users"])
            async let st = client.call(["stats"])
            async let h = client.call(["health"])
            let (ur, sr, hr) = await (u, st, h)
            let users = try? ur.flatMap { ServerParse.users($0) }.get()
            let stats = try? sr.flatMap { ServerParse.stats($0) }.get()
            let now = Date()
            if let users = users {
                print("users=\(users.count) stats_month=\(stats?.month ?? "n/a") stats_users=\(stats?.users.count ?? 0)")
                for r in ServerLogic.rows(users: users, stats: stats, now: now) {
                    print("\(r.name) | \(r.label) | down=\(Format.bytes(r.down)) up=\(Format.bytes(r.up)) | seen=\(ServerLogic.relative(r.lastSeen, now: now)) | online=\(r.online) | limits=\(ServerLogic.limits(r))")
                }
            } else { print("users failed: \(ur.flatMap { ServerParse.users($0) }.failureText)") }
            switch hr.flatMap({ ServerParse.health($0) }) {
            case .success(let x):
                let lv = ServerLogic.levels(x, now: now)
                print("health: xray=\(x.xray) nginx=\(x.nginx) cpu=\(x.cpuPercent)% load=\(x.load.map { String(format: "%.2f", $0) }) cpus=\(x.cpus) ram=\(Format.bytes(x.ramUsed))/\(Format.bytes(x.ramTotal)) disk_free=\(Format.bytes(x.diskFree)) uptime=\(ServerLogic.uptimeText(x.uptime)) cert_days=\(ServerLogic.certDays(x, now: now).map(String.init) ?? "nil") month=\(ServerLogic.monthTotal(x).map { Format.bytes($0) } ?? "nil") levels(cpu=\(lv.cpu) load=\(lv.load) cert=\(lv.cert))")
            case .failure(let e): print("health failed: \(e.text)")
            }
            exit(0)
        }
        dispatchMain()
    }

    static func testKeyCycle(_ name: String) {
        StateLog.enabled = false
        guard ServerLogic.validName(name), !ServerLogic.protectedNames.contains(name) else { print("refused: name not allowed"); exit(1) }
        let client = ServerClient()
        Task {
            func names() async -> String {
                switch await client.call(["users"]).flatMap({ ServerParse.users($0) }) {
                case .success(let u): return u.map { $0.name }.joined(separator: ", ")
                case .failure(let e): return "error: \(e.text)"
                }
            }
            print("users before: \(await names())")
            switch await client.call(ServerLogic.args(add: name, noTorrent: true), timeout: 40).flatMap({ ServerParse.ok($0) }) {
            case .failure(let e): print("add failed: \(e.text)"); exit(1)
            case .success(let restart): print("add ok restart_needed=\(restart)")
            }
            switch await client.call(["link", name]).flatMap({ ServerParse.link($0) }) {
            case .success(let link):
                print("link ok len=\(link.count) fragment_ok=\(link.hasSuffix("#" + name))")
                if let img = QRCode.cgImage(link), let png = QRCode.pngData(img) {
                    let path = NSTemporaryDirectory() + "vpn-qr-\(name).png"
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("qr png \(img.width)x\(img.height) px, \(png.count) bytes")
                    let back = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { QRCode.image(fromPNG: $0) }.flatMap { QRCode.decode($0) }
                    print("decoded=\(back != nil) match=\(back == link)")
                    try? FileManager.default.removeItem(atPath: path)
                    print("tmp removed=\(!FileManager.default.fileExists(atPath: path))")
                } else { print("qr render failed") }
            case .failure(let e): print("link failed: \(e.text)")
            }
            switch await client.call(["revoke", name], timeout: 40).flatMap({ ServerParse.ok($0) }) {
            case .failure(let e): print("revoke failed: \(e.text)")
            case .success(let restart): print("revoke ok restart_needed=\(restart)")
            }
            print("users after: \(await names())")
            exit(0)
        }
        dispatchMain()
    }
    #endif
}

extension Result where Failure == ServerError {
    var failureText: String {
        if case .failure(let e) = self { return e.text }
        return ""
    }
}
