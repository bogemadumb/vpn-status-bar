import Foundation

enum VPNState: Equatable {
    case off, connecting, ok, slow, degraded, down
}

struct StateMachine {
    static let slowMs = 400
    static let slowEnter = 2
    static let slowLeave = 2
    static let degradeCount = 3
    static let degradeSpan: TimeInterval = 60
    static let downCount = 5
    static let downSpan: TimeInterval = 120
    static let apiDownSpan: TimeInterval = 60
    static let recoverCount = 2

    private(set) var state: VPNState = .connecting
    private(set) var failStreak = 0
    private(set) var outageSince: Date?
    private var failStart: Date?
    private var apiDownSince: Date?
    private var slowStreak = 0
    private var goodStreak = 0
    private var successStreak = 0

    var wantsFastProbe: Bool { state != .ok || failStreak > 0 }

    static func threshold(expensive: Bool) -> Int { expensive ? slowMs * 2 : slowMs }

    @discardableResult
    mutating func tick(daemonRunning: Bool, apiOK: Bool, delayMs: Int?, at now: Date,
                       isExpensive: Bool) -> VPNState {
        guard daemonRunning else {
            self = StateMachine()
            state = .off
            return state
        }
        if state == .off { state = .connecting }
        guard apiOK else {
            failStreak = 0
            failStart = nil
            slowStreak = 0
            goodStreak = 0
            successStreak = 0
            if apiDownSince == nil { apiDownSince = now }
            if outageSince == nil { outageSince = now }
            if let s = apiDownSince, now.timeIntervalSince(s) >= Self.apiDownSpan { state = .down }
            return state
        }
        apiDownSince = nil
        if let d = delayMs { success(d, isExpensive) } else { failure(now) }
        return state
    }

    private mutating func success(_ d: Int, _ expensive: Bool) {
        failStreak = 0
        failStart = nil
        let slow = d > Self.threshold(expensive: expensive)
        switch state {
        case .connecting:
            state = slow ? .slow : .ok
            clearCounters()
        case .ok:
            outageSince = nil
            if slow {
                slowStreak += 1
                if slowStreak >= Self.slowEnter { state = .slow; goodStreak = 0 }
            } else {
                slowStreak = 0
            }
        case .slow:
            outageSince = nil
            if slow {
                goodStreak = 0
            } else {
                goodStreak += 1
                if goodStreak >= Self.slowLeave { state = .ok; slowStreak = 0 }
            }
        case .degraded, .down:
            successStreak += 1
            if successStreak >= Self.recoverCount {
                state = slow ? .slow : .ok
                clearCounters()
            }
        case .off:
            break
        }
    }

    private mutating func failure(_ now: Date) {
        if failStreak == 0 {
            failStart = now
            if outageSince == nil { outageSince = now }
        }
        failStreak += 1
        successStreak = 0
        slowStreak = 0
        goodStreak = 0
        let span = failStart.map { now.timeIntervalSince($0) } ?? 0
        if failStreak >= Self.downCount && span >= Self.downSpan {
            state = .down
        } else if failStreak >= Self.degradeCount && span >= Self.degradeSpan && state != .down {
            state = .degraded
        }
    }

    private mutating func clearCounters() {
        slowStreak = 0
        goodStreak = 0
        successStreak = 0
        outageSince = nil
    }
}
