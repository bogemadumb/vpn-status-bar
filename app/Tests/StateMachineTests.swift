import Foundation

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0

func check(_ cond: Bool, _ name: String) {
    if cond { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
}

let t0 = Date(timeIntervalSince1970: 1_000_000)
func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

struct Rig {
    var m = StateMachine()
    var clock = 0.0
    mutating func feed(_ delay: Int?, daemon: Bool = true, api: Bool = true, exp: Bool = false, dt: Double = 15) {
        clock += dt
        m.tick(daemonRunning: daemon, apiOK: api, delayMs: delay, at: at(clock), isExpensive: exp)
    }
    var state: VPNState { m.state }
    static func healthy() -> Rig {
        var r = Rig()
        r.feed(70)
        return r
    }
}

@main
enum Tests {
    static func main() {
        var r = Rig()
        check(r.state == .connecting, "initial state is connecting")
        r.feed(70, api: false)
        check(r.state == .connecting, "api not answering yet stays connecting")
        r.feed(70)
        check(r.state == .ok, "first good sample from connecting gives ok")

        r = Rig.healthy()
        r.feed(nil)
        check(r.state == .ok, "single timeout does not change ok")
        r.feed(70)
        check(r.state == .ok && r.m.failStreak == 0, "success after single timeout resets streak")

        r = Rig.healthy()
        r.feed(nil, dt: 15); r.feed(nil, dt: 15); r.feed(nil, dt: 15)
        check(r.state == .ok, "3 failures spanning 30 s do not degrade")
        r.feed(nil, dt: 15)
        check(r.state == .ok, "4 failures spanning 45 s do not degrade")
        r.feed(nil, dt: 15)
        check(r.state == .degraded, "5 failures spanning 60 s degrade")

        r = Rig.healthy()
        r.feed(nil, dt: 30); r.feed(nil, dt: 30); r.feed(nil, dt: 30)
        check(r.state == .degraded, "3 failures over 60 s degrade")

        r = Rig.healthy()
        r.feed(nil, dt: 10)
        for _ in 0..<5 { r.feed(nil, dt: 10) }
        check(r.state == .ok, "6 failures over 50 s do not degrade")

        r = Rig.healthy()
        for _ in 0..<5 { r.feed(nil, dt: 30) }
        check(r.state == .down, "5 failures over 120 s give down")

        r = Rig.healthy()
        for _ in 0..<5 { r.feed(nil, dt: 20) }
        check(r.state == .degraded, "5 failures over 80 s are degraded, not down")
        for _ in 0..<3 { r.feed(nil, dt: 20) }
        check(r.state == .down, "failures reaching 120 s span give down")

        r = Rig.healthy()
        for _ in 0..<3 { r.feed(nil, dt: 30) }
        r.feed(70)
        check(r.state == .degraded, "one success does not leave degraded")
        r.feed(70)
        check(r.state == .ok, "2 successes recover degraded to ok")

        r = Rig.healthy()
        for _ in 0..<5 { r.feed(nil, dt: 30) }
        r.feed(70)
        check(r.state == .down, "one success does not leave down")
        r.feed(nil, dt: 5)
        r.feed(70)
        check(r.state == .down, "success, failure, success: still down")
        r.feed(70)
        check(r.state == .ok, "2 consecutive successes recover down to ok")
        check(r.m.outageSince == nil, "outage cleared after recovery")

        r = Rig.healthy()
        r.feed(600)
        check(r.state == .ok, "one slow sample does not enter slow")
        r.feed(600)
        check(r.state == .slow, "2 slow samples enter slow")
        r.feed(100)
        check(r.state == .slow, "one good sample does not leave slow")
        r.feed(600)
        r.feed(100)
        check(r.state == .slow, "good, slow, good keeps slow")
        r.feed(100)
        check(r.state == .ok, "2 good samples leave slow")

        r = Rig.healthy()
        r.feed(600); r.feed(100); r.feed(600); r.feed(100)
        check(r.state == .ok, "alternating slow and good stays ok")

        r = Rig.healthy()
        r.feed(400); r.feed(400)
        check(r.state == .ok, "delay equal to threshold is not slow")

        r = Rig.healthy()
        r.feed(600, exp: true); r.feed(600, exp: true)
        check(r.state == .ok, "expensive network: 600 ms is not slow (threshold 800)")
        r.feed(900, exp: true); r.feed(900, exp: true)
        check(r.state == .slow, "expensive network: 900 ms enters slow")
        check(StateMachine.threshold(expensive: true) == 800 && StateMachine.threshold(expensive: false) == 400,
              "threshold doubles on expensive network")

        r = Rig.healthy()
        r.feed(70, daemon: false)
        check(r.state == .off, "daemon off gives off immediately")
        r.feed(nil, api: false)
        check(r.state == .connecting, "daemon back, api silent: connecting")
        r.feed(70)
        check(r.state == .ok, "off then recovered reaches ok")

        r = Rig.healthy()
        for _ in 0..<5 { r.feed(nil, dt: 30) }
        r.feed(nil, daemon: false)
        check(r.state == .off && r.m.failStreak == 0 && r.m.outageSince == nil, "daemon off clears all counters")

        r = Rig.healthy()
        for i in 0..<40 {
            r.feed(i % 2 == 0 ? nil : 70, dt: 15)
            if r.state != .ok { break }
        }
        check(r.state == .ok, "flapping fail, ok, fail, ok never leaves ok")

        r = Rig.healthy()
        var left = false
        for i in 0..<60 {
            r.feed(i % 3 == 2 ? 70 : nil, dt: 20)
            if r.state != .ok { left = true }
        }
        check(!left, "two failures then a success repeating never leaves ok")

        r = Rig.healthy()
        r.feed(70, api: false, dt: 20)
        r.feed(70, api: false, dt: 20)
        check(r.state == .ok, "api silent for 20-40 s keeps ok")
        r.feed(70, dt: 20)
        check(r.state == .ok && r.m.outageSince == nil, "api back before 60 s keeps ok")

        r = Rig.healthy()
        r.feed(nil, api: false, dt: 1)
        r.feed(nil, api: false, dt: 58)
        check(r.state == .ok, "api unreachable 58 s is not down")
        r.feed(nil, api: false, dt: 2)
        check(r.state == .down, "api unreachable 60 s gives down")
        r.feed(70)
        check(r.state == .down, "api back, one success: still down")
        r.feed(70)
        check(r.state == .ok, "api back, 2 successes: ok")

        r = Rig.healthy()
        check(!r.m.wantsFastProbe, "ok with no failures probes at normal cadence")
        r.feed(nil)
        check(r.m.wantsFastProbe, "first failure switches to fast cadence")
        r.feed(70)
        check(!r.m.wantsFastProbe, "success returns to normal cadence")
        r.feed(600); r.feed(600)
        check(r.m.wantsFastProbe, "slow state probes fast")

        r = Rig.healthy()
        r.feed(nil, dt: 30)
        check(r.m.outageSince == at(r.clock), "outage start recorded at first failure")

        runRoutingTests()
        runReliabilityTests()
        runServerTests()
        runExitTests()
        print("RESULT passed=\(passed) failed=\(failed)")
        exit(failed == 0 ? 0 : 1)
    }
}
