import Foundation
import SQLite3

struct EventRow: Identifiable, Equatable {
    let id: Int64
    let start: Date
    let end: Date?
    let kind: String
    let detail: String
    var duration: TimeInterval? { end.map { max(0, $0.timeIntervalSince(start)) } }
}

struct Bucket: Equatable {
    let ts: Double
    let down: Double
    let up: Double
    let delay: Double?
    let drop: Bool
}

struct AppRow: Identifiable, Equatable {
    var id: String { process }
    let process: String
    let vps: Double
    let direct: Double
    var total: Double { vps + direct }
}

struct TrafficDelta: Equatable {
    let process: String
    let via: String
    let down: Double
    let up: Double
}

struct ConnSnap {
    let id: String
    let process: String
    let via: String
    let down: Double
    let up: Double
}

struct TrafficTracker {
    private var seen: [String: (down: Double, up: Double)] = [:]
    private var primed = false

    mutating func update(_ conns: [ConnSnap]) -> [TrafficDelta] {
        var acc: [String: (process: String, via: String, down: Double, up: Double)] = [:]
        var next: [String: (down: Double, up: Double)] = [:]
        for c in conns {
            next[c.id] = (c.down, c.up)
            var dd = 0.0, du = 0.0
            if let p = seen[c.id] {
                dd = max(0, c.down - p.down)
                du = max(0, c.up - p.up)
            } else if primed {
                dd = c.down
                du = c.up
            }
            guard dd > 0 || du > 0 else { continue }
            let key = c.process + "\u{1}" + c.via
            var a = acc[key] ?? (c.process, c.via, 0, 0)
            a.down += dd
            a.up += du
            acc[key] = a
        }
        seen = next
        primed = true
        return acc.values.map { TrafficDelta(process: $0.process, via: $0.via, down: $0.down, up: $0.up) }
            .sorted { ($0.process, $0.via) < ($1.process, $1.via) }
    }
}

enum ChartRange: String, CaseIterable, Identifiable {
    case hour, day, month
    var id: String { rawValue }

    var title: String {
        switch self {
        case .hour: return "Час"
        case .day: return "Сутки"
        case .month: return "30 дней"
        }
    }

    var step: Int {
        switch self {
        case .hour: return 60
        case .day: return 900
        case .month: return 21600
        }
    }

    var count: Int {
        switch self {
        case .hour: return 60
        case .day: return 96
        case .month: return 120
        }
    }

    func start(now: Date) -> Int {
        let n = Int(now.timeIntervalSince1970)
        return (n / step) * step - (count - 1) * step
    }

    var heading: String {
        switch self {
        case .hour: return "Скорость за час"
        case .day: return "Скорость за сутки"
        case .month: return "Скорость за 30 дней"
        }
    }
}

enum DayKey {
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func of(_ d: Date) -> String { fmt.string(from: d) }
}

enum Bind {
    case int(Int64), real(Double), text(String), null
}

final class HistoryDB: @unchecked Sendable {
    static let sampleRetentionDays = 30
    static let trafficRetentionDays = 90
    static let eventRetentionDays = 365

    private var db: OpaquePointer?
    private let q = DispatchQueue(label: "vpnmonitor.history")
    let path: String

    init?(path: String) {
        self.path = path
        if path != ":memory:" {
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 3000)
        let ok = q.sync { () -> Bool in
            exec("PRAGMA journal_mode=WAL")
            exec("PRAGMA synchronous=NORMAL")
            return exec("""
            CREATE TABLE IF NOT EXISTS samples(ts INTEGER NOT NULL, down_bps REAL, up_bps REAL, delay_ms INTEGER, state TEXT);
            CREATE INDEX IF NOT EXISTS samples_ts ON samples(ts);
            CREATE TABLE IF NOT EXISTS app_traffic(day TEXT NOT NULL, process TEXT NOT NULL, via TEXT NOT NULL,
              bytes_down INTEGER NOT NULL DEFAULT 0, bytes_up INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(day, process, via));
            CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY AUTOINCREMENT, ts_start INTEGER NOT NULL,
              ts_end INTEGER, kind TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '');
            CREATE INDEX IF NOT EXISTS events_ts ON events(ts_start);
            """)
        }
        if !ok { sqlite3_close(db); return nil }
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func run(_ sql: String, _ binds: [Bind] = []) -> Bool {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(st) }
        bind(st, binds)
        return sqlite3_step(st) == SQLITE_DONE
    }

    private func bind(_ st: OpaquePointer?, _ binds: [Bind]) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, b) in binds.enumerated() {
            let n = Int32(i + 1)
            switch b {
            case .int(let v): sqlite3_bind_int64(st, n, v)
            case .real(let v): sqlite3_bind_double(st, n, v)
            case .text(let v): sqlite3_bind_text(st, n, v, -1, transient)
            case .null: sqlite3_bind_null(st, n)
            }
        }
    }

    private func rows<T>(_ sql: String, _ binds: [Bind] = [], _ map: (OpaquePointer) -> T) -> [T] {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let s = st else { return [] }
        defer { sqlite3_finalize(s) }
        bind(s, binds)
        var out: [T] = []
        while sqlite3_step(s) == SQLITE_ROW { out.append(map(s)) }
        return out
    }

    private func str(_ s: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
    }

    private func optReal(_ s: OpaquePointer, _ i: Int32) -> Double? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_double(s, i)
    }

    func insertSample(ts: Date, down: Double, up: Double, delay: Int?, state: String) {
        q.sync {
            _ = run("INSERT INTO samples(ts, down_bps, up_bps, delay_ms, state) VALUES(?,?,?,?,?)",
                    [.int(Int64(ts.timeIntervalSince1970)), .real(down), .real(up),
                     delay.map { .int(Int64($0)) } ?? .null, .text(state)])
        }
    }

    func addTraffic(day: String, _ deltas: [TrafficDelta]) {
        guard !deltas.isEmpty else { return }
        q.sync {
            exec("BEGIN")
            for d in deltas {
                _ = run("""
                INSERT INTO app_traffic(day, process, via, bytes_down, bytes_up) VALUES(?,?,?,?,?)
                ON CONFLICT(day, process, via) DO UPDATE SET bytes_down = bytes_down + excluded.bytes_down,
                  bytes_up = bytes_up + excluded.bytes_up
                """, [.text(day), .text(d.process), .text(d.via), .int(Int64(d.down)), .int(Int64(d.up))])
            }
            exec("COMMIT")
        }
    }

    @discardableResult
    func insertEvent(start: Date, end: Date?, kind: String, detail: String) -> Int64 {
        q.sync {
            let ok = run("INSERT INTO events(ts_start, ts_end, kind, detail) VALUES(?,?,?,?)",
                         [.int(Int64(start.timeIntervalSince1970)),
                          end.map { .int(Int64($0.timeIntervalSince1970)) } ?? .null, .text(kind), .text(detail)])
            return ok ? sqlite3_last_insert_rowid(db) : 0
        }
    }

    func closeEvent(id: Int64, end: Date) {
        q.sync { _ = run("UPDATE events SET ts_end = ? WHERE id = ?", [.int(Int64(end.timeIntervalSince1970)), .int(id)]) }
    }

    func closeStaleDrops(at now: Date) {
        q.sync {
            _ = run("UPDATE events SET ts_end = ?, detail = detail || ' (приложение перезапущено)' WHERE ts_end IS NULL AND kind IN ('net','core','server')",
                    [.int(Int64(now.timeIntervalSince1970))])
        }
    }

    func eventCount(kind: String, since: Date) -> Int {
        q.sync {
            rows("SELECT COUNT(*) FROM events WHERE kind = ? AND ts_start >= ?",
                 [.text(kind), .int(Int64(since.timeIntervalSince1970))]) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
        }
    }

    func events(limit: Int, excluding: [String] = []) -> [EventRow] {
        q.sync {
            let ph = excluding.isEmpty ? "" : "WHERE kind NOT IN (\(excluding.map { _ in "?" }.joined(separator: ",")))"
            return rows("SELECT id, ts_start, ts_end, kind, detail FROM events \(ph) ORDER BY ts_start DESC, id DESC LIMIT ?",
                        excluding.map { .text($0) } + [.int(Int64(limit))]) { s in
                EventRow(id: sqlite3_column_int64(s, 0),
                         start: Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, 1))),
                         end: sqlite3_column_type(s, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, 2))),
                         kind: str(s, 3), detail: str(s, 4))
            }
        }
    }

    func series(_ range: ChartRange, now: Date) -> [Bucket?] {
        let start = range.start(now: now)
        let step = range.step
        let raw: [(Int, Bucket)] = q.sync {
            rows("""
            SELECT (ts / ?1) * ?1 AS b, AVG(down_bps), AVG(up_bps), AVG(delay_ms),
                   MAX(CASE WHEN state = 'down' THEN 1 ELSE 0 END)
            FROM samples WHERE ts >= ?2 GROUP BY b ORDER BY b
            """, [.int(Int64(step)), .int(Int64(start))]) { s in
                let ts = Int(sqlite3_column_int64(s, 0))
                return (ts, Bucket(ts: Double(ts), down: sqlite3_column_double(s, 1), up: sqlite3_column_double(s, 2),
                                   delay: optReal(s, 3), drop: sqlite3_column_int(s, 4) == 1))
            }
        }
        var out = [Bucket?](repeating: nil, count: range.count)
        for (ts, b) in raw {
            let i = (ts - start) / step
            if i >= 0 && i < range.count { out[i] = b }
        }
        return out
    }

    func averageDelay(since: Date) -> Double? {
        q.sync {
            rows("SELECT AVG(delay_ms) FROM samples WHERE ts >= ? AND delay_ms IS NOT NULL",
                 [.int(Int64(since.timeIntervalSince1970))]) { optReal($0, 0) }.first ?? nil
        }
    }

    func sampleCount() -> Int {
        q.sync { rows("SELECT COUNT(*) FROM samples") { Int(sqlite3_column_int64($0, 0)) }.first ?? 0 }
    }

    func trafficRows(day: String, limit: Int) -> [AppRow] {
        q.sync {
            rows("""
            SELECT process,
              SUM(CASE WHEN via = 'vps' THEN bytes_down + bytes_up ELSE 0 END),
              SUM(CASE WHEN via = 'direct' THEN bytes_down + bytes_up ELSE 0 END)
            FROM app_traffic WHERE day = ? AND via IN ('vps', 'direct')
            GROUP BY process ORDER BY SUM(bytes_down + bytes_up) DESC, process LIMIT ?
            """, [.text(day), .int(Int64(limit))]) { s in
                AppRow(process: str(s, 0), vps: sqlite3_column_double(s, 1), direct: sqlite3_column_double(s, 2))
            }
        }
    }

    func trafficTotals(day: String) -> (vps: Double, direct: Double) {
        q.sync {
            rows("""
            SELECT SUM(CASE WHEN via = 'vps' THEN bytes_down + bytes_up ELSE 0 END),
                   SUM(CASE WHEN via = 'direct' THEN bytes_down + bytes_up ELSE 0 END)
            FROM app_traffic WHERE day = ?
            """, [.text(day)]) { (sqlite3_column_double($0, 0), sqlite3_column_double($0, 1)) }.first ?? (0, 0)
        }
    }

    func trafficRowCount() -> Int {
        q.sync { rows("SELECT COUNT(*) FROM app_traffic") { Int(sqlite3_column_int64($0, 0)) }.first ?? 0 }
    }

    func prune(now: Date) {
        q.sync {
            let day = 86400.0
            _ = run("DELETE FROM samples WHERE ts < ?", [.int(Int64(now.timeIntervalSince1970 - Double(Self.sampleRetentionDays) * day))])
            _ = run("DELETE FROM app_traffic WHERE day < ?", [.text(DayKey.of(now.addingTimeInterval(-Double(Self.trafficRetentionDays) * day)))])
            _ = run("DELETE FROM events WHERE ts_start < ?", [.int(Int64(now.timeIntervalSince1970 - Double(Self.eventRetentionDays) * day))])
        }
    }

    static var defaultPath: String {
        NSHomeDirectory() + "/Library/Application Support/VPNMonitor/history.sqlite"
    }
}
