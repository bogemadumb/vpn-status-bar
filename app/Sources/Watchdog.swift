import Foundation

enum WatchdogAction: Equatable {
    case none, restart, start, giveUp
}

struct Watchdog {
    static let apiDownLimit: TimeInterval = 60
    static let coreDownGrace: TimeInterval = 10
    static let minGap: TimeInterval = 30
    static let maxAttempts = 3
    static let window: TimeInterval = 600

    private(set) var apiDownSince: Date?
    private(set) var coreDownSince: Date?
    private(set) var attempts: [Date] = []
    private(set) var lastDownFor: TimeInterval = 0
    private var gaveUp = false

    func attemptsInWindow(at now: Date) -> Int {
        attempts.filter { now.timeIntervalSince($0) < Self.window }.count
    }

    mutating func evaluate(intentOn: Bool, daemonRunning: Bool, apiOK: Bool, at now: Date) -> WatchdogAction {
        guard intentOn else {
            apiDownSince = nil
            coreDownSince = nil
            gaveUp = false
            return .none
        }
        if daemonRunning && apiOK {
            apiDownSince = nil
            coreDownSince = nil
            gaveUp = false
            return .none
        }
        let action: WatchdogAction
        if daemonRunning {
            coreDownSince = nil
            if apiDownSince == nil { apiDownSince = now }
            lastDownFor = now.timeIntervalSince(apiDownSince ?? now)
            guard lastDownFor >= Self.apiDownLimit else { return .none }
            action = .restart
        } else {
            apiDownSince = nil
            if coreDownSince == nil { coreDownSince = now }
            lastDownFor = now.timeIntervalSince(coreDownSince ?? now)
            guard lastDownFor >= Self.coreDownGrace else { return .none }
            action = .start
        }
        attempts = attempts.filter { now.timeIntervalSince($0) < Self.window }
        if let last = attempts.last, now.timeIntervalSince(last) < Self.minGap { return .none }
        if attempts.count >= Self.maxAttempts {
            if gaveUp { return .none }
            gaveUp = true
            return .giveUp
        }
        attempts.append(now)
        apiDownSince = nil
        coreDownSince = nil
        return action
    }
}

enum IntentSync {
    static func initial(stored: Bool?, daemonRunning: Bool) -> Bool { stored ?? daemonRunning }

    static func next(current: Bool, daemonRunning: Bool, daemonDisabled: Bool, busy: Bool) -> Bool {
        if busy { return current }
        if daemonRunning { return true }
        if daemonDisabled { return false }
        return current
    }

    static func isDisabled(_ printDisabled: String, label: String = "dev.vpnstatusbar.singbox") -> Bool {
        for raw in printDisabled.split(separator: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("\"\(label)\"") { return l.hasSuffix("=> disabled") || l.hasSuffix("=> true") }
        }
        return false
    }
}

struct RateLimiter {
    var interval: TimeInterval = 600
    private var last: [String: Date] = [:]

    mutating func allow(_ kind: String, at now: Date, interval override: TimeInterval? = nil) -> Bool {
        if let t = last[kind], now.timeIntervalSince(t) < (override ?? interval) { return false }
        last[kind] = now
        return true
    }
}

enum DropChange: Equatable {
    case opened(start: Date)
    case closed(start: Date, end: Date)
}

struct DropTracker {
    private(set) var openSince: Date?

    mutating func update(isDrop: Bool, recovered: Bool, startHint: Date?, at now: Date) -> DropChange? {
        if let s = openSince {
            if recovered {
                openSince = nil
                return .closed(start: s, end: now)
            }
            return nil
        }
        if isDrop {
            let s = min(startHint ?? now, now)
            openSince = s
            return .opened(start: s)
        }
        return nil
    }
}

enum DropReason {
    static func classify(daemonRunning: Bool, apiOK: Bool, netChangedRecently: Bool) -> (kind: String, detail: String) {
        if !daemonRunning { return ("core", "ядро не работало") }
        if !apiOK { return ("core", "ядро не отвечало") }
        if netChangedRecently { return ("net", "сменилась сеть, туннель не удержался") }
        return ("server", "сервер недоступен: туннель не отвечает")
    }
}
