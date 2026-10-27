import Foundation

func tmpDir() -> String {
    let d = NSTemporaryDirectory() + "vpnrules-\(getpid())-\(Int.random(in: 0..<1_000_000))"
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

func put(_ dir: String, _ name: String, _ text: String, mode: Int = 0o644) {
    FileManager.default.createFile(atPath: "\(dir)/\(name)", contents: Data(text.utf8), attributes: [.posixPermissions: mode])
}

func slurp(_ dir: String, _ name: String) -> String {
    String(data: FileManager.default.contents(atPath: "\(dir)/\(name)") ?? Data(), encoding: .utf8) ?? ""
}

func mode(_ dir: String, _ name: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: "\(dir)/\(name)"))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

func runRoutingTests() {
    let directOrig = "{\"version\": 2, \"rules\": [{\"domain_suffix\": [\"example.gov\", \"example.com\"]}]}\n"
    let placeOrig = "{\"version\": 2, \"rules\": [{\"domain\": [\"placeholder.invalid\"]}]}\n"

    let d = tmpDir()
    put(d, "direct.json", directOrig, mode: 0o600)
    put(d, "proxy.json", placeOrig)
    put(d, "block.json", placeOrig)
    put(d, "always-vps.json", "{\"version\": 2, \"rules\": [{\"domain_suffix\": [\"example.net\", \"example.org\"]}]}\n")
    let f = RuleFiles(dir: d)

    check((try? f.add("ifconfig.me", kind: .domainSuffix, target: .direct)) == true, "add returns changed")
    check(slurp(d, "direct.json") == "{\"version\": 2, \"rules\": [{\"domain_suffix\": [\"example.gov\", \"example.com\", \"ifconfig.me\"]}]}\n", "add merges into existing domain_suffix object, python-style format")
    check(mode(d, "direct.json") == 0o600, "file mode preserved on rewrite")
    check((try? f.add("ifconfig.me", kind: .domainSuffix, target: .direct)) == false, "duplicate add changes nothing")
    try? f.remove(UserRule(target: .direct, kind: .domainSuffix, value: "ifconfig.me"))
    check(slurp(d, "direct.json") == directOrig, "add+remove domain is byte-identical")

    _ = try? f.add("curl", kind: .processName, target: .direct)
    check(slurp(d, "direct.json") == "{\"version\": 2, \"rules\": [{\"domain_suffix\": [\"example.gov\", \"example.com\"]}, {\"process_name\": [\"curl\"]}]}\n", "process rule is a separate OR-ed rule object")
    _ = try? f.add("10.1.0.0/16", kind: .ipCidr, target: .direct)
    let txt = slurp(d, "direct.json")
    check(txt.contains("{\"ip_cidr\": [\"10.1.0.0/16\"]}") && txt.contains("\\/") == false, "cidr slash is not escaped")
    try? f.remove(UserRule(target: .direct, kind: .processName, value: "curl"))
    try? f.remove(UserRule(target: .direct, kind: .ipCidr, value: "10.1.0.0/16"))
    check(slurp(d, "direct.json") == directOrig, "add+remove process and cidr is byte-identical")

    _ = try? f.add("example.org", kind: .domainSuffix, target: .proxy)
    check(slurp(d, "proxy.json") == "{\"version\": 2, \"rules\": [{\"domain_suffix\": [\"example.org\"]}]}\n", "placeholder dropped when real rule added")
    try? f.remove(UserRule(target: .proxy, kind: .domainSuffix, value: "example.org"))
    check(slurp(d, "proxy.json") == placeOrig, "placeholder restored when last rule removed")

    _ = try? f.add("moved.example", kind: .domainSuffix, target: .direct)
    _ = try? f.add("moved.example", kind: .domainSuffix, target: .proxy)
    check(f.find(.domainSuffix, "moved.example") == .proxy, "adding to another target moves the rule")
    check(!slurp(d, "direct.json").contains("moved.example"), "moved rule removed from the old file")
    try? f.remove(UserRule(target: .proxy, kind: .domainSuffix, value: "moved.example"))
    check(slurp(d, "direct.json") == directOrig && slurp(d, "proxy.json") == placeOrig, "move round trip restores both files")

    let loaded = f.load()
    check(loaded.count == 2 && loaded.allSatisfy { $0.target == .direct }, "load hides placeholders, lists user entries")
    check(f.alwaysVps() == ["example.net", "example.org"], "always-vps read")

    put(d, "block.json", "{\"version\": 2, \"rules\": [{\"domain\": [\"placeholder.invalid\"]}, {\"domain_suffix\": [\"bad.example\"], \"port\": [80]}]}\n")
    _ = try? f.add("x.example", kind: .domainSuffix, target: .block)
    check(slurp(d, "block.json").contains("\"port\": [80]") && slurp(d, "block.json").contains("bad.example"), "compound rule object preserved untouched")

    put(d, "proxy.json", "not json")
    check((try? f.add("a.example", kind: .domainSuffix, target: .proxy)) == nil, "corrupt file is not overwritten")
    check(slurp(d, "proxy.json") == "not json", "corrupt file content intact")
    try? FileManager.default.removeItem(atPath: d)

    func kind(_ s: String) -> String { RuleDetect.parse(s).map { "\($0.kind.rawValue):\($0.value)" } ?? "nil" }
    check(kind("ifconfig.me") == "domain_suffix:ifconfig.me", "detect: domain")
    check(kind("1.2.3.4") == "ip_cidr:1.2.3.4/32", "detect: ipv4 gets /32")
    check(kind("10.0.0.0/8") == "ip_cidr:10.0.0.0/8", "detect: cidr")
    check(kind("2001:db8::1") == "ip_cidr:2001:db8::1/128", "detect: ipv6")
    check(kind("curl") == "process_name:curl", "detect: bare word is process")
    check(kind("Google Chrome") == "process_name:Google Chrome", "detect: name with space is process")
    check(kind("https://www.Example.org/x?y=1") == "domain_suffix:example.org", "detect: url gives host without www")
    check(kind("*.example.org") == "domain_suffix:example.org", "detect: wildcard prefix stripped")
    check(kind("999.1.1.1") == "domain_suffix:999.1.1.1", "detect: bad octet is not an ip")
    check(kind("1.2.3.4/33") == "process_name:1.2.3.4/33" || kind("1.2.3.4/33") == "process_name:33", "detect: bad prefix is not cidr")
    check(kind("   ") == "nil", "detect: blank is nil")
    check(kind("Claude.app") == "domain_suffix:claude.app", "detect: dotted word is domain per spec")
    check(RuleDetect.hostFromURL("https://example.gov/epz/main") == "example.gov", "host from url")
    check(RuleDetect.hostFromURL("https://example.org/x") == "example.org", "host from url: example.org")
    check(RuleDetect.hostFromURL("about:blank") == nil, "host from url: about:blank has none")
    check(RuleDetect.hostFromURL("favorites://") == nil, "host from url: favorites has none")

    check(ConnLogic.processName("/Users/user/.vscode/extensions/x/native-binary/claude (user)") == "claude", "process name from path with user")
    check(ConnLogic.processName("/Applications/Telegram.app/Contents/MacOS/Telegram (user)") == "Telegram", "process name: Telegram")
    check(ConnLogic.processName("/System/Library/PrivateFrameworks/ApplePushService.framework/apsd (root)") == "apsd", "process name: apsd")
    check(ConnLogic.processName("") == "", "process name: empty")
    check(ConnLogic.processName("/Applications/Google Chrome.app/Contents/Frameworks/X/Google Chrome Helper (Renderer) (user)") == "Google Chrome Helper (Renderer)", "process name keeps inner parentheses")

    let h = ConnLogic.humanRule
    check(h("rule_set=user-direct => route(direct)") == "Мои: напрямую", "rule name: user-direct")
    check(h("rule_set=user-proxy => route(vps)") == "Мои: через VPS", "rule name: user-proxy")
    check(h("rule_set=user-block => reject") == "Мои: блок", "rule name: user-block")
    check(h("rule_set=user-always-vps => route(vps)") == "Закреплённые: всегда VPS", "rule name: always-vps")
    check(h("final") == "Всё остальное", "rule name: final")
    check(h("rule_set=geoip-local => route(direct)") == "Локальные сайты", "rule name: geoip-local")
    check(h("ip_cidr=17.0.0.0/8 => route(direct)") == "Apple", "rule name: Apple")
    check(h("ip_cidr=203.0.113.10/32 => route(direct)") == "Сам сервер", "rule name: server")
    check(h("ip_is_private=true => route(direct)") == "Локальная сеть", "rule name: private")
    check(h("clash_mode=Direct => route(direct)") == "Режим «напрямую»", "rule name: mode direct")
    check(h("port=[993 995 465 587] => route(direct)") == "Почтовые порты", "rule name: mail ports")
    check(h("something=odd => route(vps)") == "something=odd", "rule name: unknown falls back to raw condition")

    let r = ConnLogic.route
    check(r(["vps"], "final", "1.1.1.1") == .vps, "chip: final via vps")
    check(r(["direct"], "rule_set=geoip-local => route(direct)", "198.51.100.5") == .direct, "chip: geoip direct")
    check(r(["direct"], "ip_is_private=true => route(direct)", "192.168.1.20") == .local, "chip: private rule is local")
    check(r(["direct"], "final", "10.1.2.3") == .local, "chip: private ip is local")
    check(r([], "rule_set=user-block => reject", "1.1.1.1") == .block, "chip: reject is block")
    check(r([], "rule_set=user-direct => route(direct)", "1.1.1.1") == .direct, "chip: no chains falls back to action")
    check(r(["vps"], "rule_set=user-always-vps => route(vps)", "198.51.100.10") == .vps, "chip: always-vps")
    check(ConnLogic.isPrivateIP("172.20.10.1") && !ConnLogic.isPrivateIP("172.32.0.1") && !ConnLogic.isPrivateIP("8.8.8.8"), "private ip ranges")
    check(ConnLogic.parseDate("2026-10-03T01:20:28.804898+03:00") != nil, "parse date with microseconds")
    check(ConnLogic.speed(0) == "0" && ConnLogic.speed(120_000) == "0,1 МБ/с" && ConnLogic.speed(45_000) == "45 КБ/с" && ConnLogic.speed(500) == "500 Б/с", "speed format")
    check(ConnLogic.age(40) == "40 с" && ConnLogic.age(14 * 60) == "14 мин" && ConnLogic.age(3 * 3600) == "3 ч", "age format")

    func verdict(_ i: RouteInput) -> VerdictKind { RouteAnalysis.analyze(i).verdict.kind }
    var ok = RouteInput(netName: "Ethernet", routerMs: 1, providerMs: 2, providerAddr: "198.51.100.1", vpsMs: 36, siteMs: 70, gstaticMs: 66)
    check(verdict(ok) == .ok, "verdict: home network is ok")
    check(RouteAnalysis.analyze(ok).verdict.title == "Всё в норме", "verdict title: ok")
    check(RouteAnalysis.analyze(ok).hops.allSatisfy { $0.status != .warn }, "hops: all green at home")
    var slowProv = RouteInput(netName: "Wi-Fi", mobile: true, routerMs: 10, providerMs: 95, providerAddr: "100.64.0.1", vpsMs: 112, siteMs: 140, gstaticMs: 118)
    check(verdict(slowProv) == .provider, "verdict: provider delta 85 > 60")
    check(RouteAnalysis.analyze(slowProv).verdict.title == "Тормозит сеть до провайдера, не VPN", "verdict title: provider")
    check(RouteAnalysis.analyze(slowProv).hops[2].status == .warn && RouteAnalysis.analyze(slowProv).hops[3].status == .ok, "hops: provider warn, vps ok")
    check(RouteAnalysis.analyze(slowProv).hops[2].delta == 85, "hops: provider delta computed from router")
    let ksOk = RouteInput(netName: "Ethernet", routerMs: 1, providerMs: 55, providerAddr: "example.org", providerViaHTTPS: true, vpsMs: 8, siteMs: 68, gstaticMs: 69)
    check(verdict(ksOk) == .ok, "kill switch fallback: local site 55 ms https is ok")
    check(RouteAnalysis.analyze(ksOk).hops[2].delta == nil && RouteAnalysis.analyze(ksOk).hops[3].delta == 7, "kill switch fallback: vps delta from router, provider no delta")
    let ksSlow = RouteInput(netName: "Wi-Fi", mobile: true, routerMs: 12, providerMs: 420, providerAddr: "example.org", providerViaHTTPS: true, vpsMs: 60, siteMs: 200, gstaticMs: 190)
    check(verdict(ksSlow) == .provider, "kill switch fallback: local site 420 ms https flags provider")
    slowProv.routerMs = 38; slowProv.providerMs = 50
    check(verdict(slowProv) == .router, "verdict: router 38 > 30")
    let srv = RouteInput(netName: "Ethernet", routerMs: 1, providerMs: 3, vpsMs: 120, siteMs: 180)
    check(verdict(srv) == .server && RouteAnalysis.analyze(srv).verdict.title == "Тормозит сервер", "verdict: server delta 117 > 80")
    check(verdict(RouteInput(netName: "E", routerMs: 1, providerMs: 3, vpsMs: nil)) == .serverDown, "verdict: vps unreachable")
    check(verdict(RouteInput(netName: "E", routerMs: nil, providerMs: nil, vpsMs: nil)) == .routerDown, "verdict: nothing answers")
    let borderline = RouteInput(netName: "E", routerMs: 30, providerMs: 90, vpsMs: 170, siteMs: 250)
    check(verdict(borderline) == .ok, "verdict: exactly at limits is ok")
    let both = RouteInput(netName: "E", routerMs: 5, providerMs: 100, vpsMs: 400, siteMs: 450)
    check(verdict(both) == .server, "verdict: worst ratio wins (server +300 vs provider +95)")
    let off = RouteInput(netName: "E", routerMs: 1, providerMs: 3, vpsMs: 36, siteMs: nil, gstaticMs: nil, tunnelUp: false)
    check(verdict(off) == .ok && RouteAnalysis.analyze(off).hops[4].sub == "VPN выключен", "verdict: vpn off still measures the physical path")
    let noProv = RouteInput(netName: "E", routerMs: 1, providerMs: nil, vpsMs: 36, siteMs: 70)
    check(RouteAnalysis.analyze(noProv).hops[2].status == .unknown && RouteAnalysis.analyze(noProv).hops[3].delta == 35, "hops: unknown provider skipped, vps delta from router")
    ok.siteMs = nil; ok.gstaticMs = 60
    check(RouteAnalysis.analyze(ok).hops[4].sub.contains("не отвечает"), "hops: site silent while 204 works")

    let ns = "Destination        Gateway            Flags               Netif Expire\ndefault            192.168.1.1        UGScg                en12\ndefault            192.168.1.1        UGScIg                en0\n1                  172.19.0.1         UGSc                utun7\n"
    check(NetParse.physicalDefault(ns)?.iface == "en12" && NetParse.physicalDefault(ns)?.gateway == "192.168.1.1", "netstat: physical default skips utun")
    check(NetParse.physicalDefault("default 172.19.0.1 UGSc utun7\n") == nil, "netstat: only utun default gives nil")
    let tr = "traceroute to 1.1.1.1 (1.1.1.1), 5 hops max\n 1  192.168.1.1  1.2 ms\n 2  *\n 3  172.29.1.1  1.4 ms\n 4  198.51.100.77  1.4 ms\n"
    check(NetParse.firstPublicHop(tr, gateway: "192.168.1.1") == "198.51.100.77", "traceroute: first public hop skips gateway, stars, private")
    check(NetParse.firstPublicHop(" 1  192.168.1.1  1 ms\n 2  *\n", gateway: "192.168.1.1") == nil, "traceroute: none found")
    check(NetParse.pingMedian("64 bytes from x: time=1.5 ms\n64 bytes from x: time=9.0 ms\n64 bytes from x: time=2.0 ms\n") == 2.0, "ping median of 3")
    check(NetParse.pingMedian("Request timeout\n") == nil, "ping median: no replies")
    check(NetParse.ssid("  SSID : <redacted>\n") == nil && NetParse.ssid("  SSID : Home\n") == "Home", "ssid redacted vs real")
    check(NetParse.portNames("Hardware Port: Wi-Fi\nDevice: en0\n\nHardware Port: USB LAN\nDevice: en12\n")["en12"] == "USB LAN", "hardware ports parsed")
}
