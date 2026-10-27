import Foundation
import SwiftUI

@MainActor
final class ExitModel: ObservableObject {
    @Published private(set) var active: ActiveExit?
    @Published private(set) var pings: [String: ExitPing] = [:]
    @Published private(set) var available = false
    @Published private(set) var supported = false
    @Published private(set) var switching: String?
    @Published private(set) var switches = 0
    @Published private(set) var note: String?
    var db: HistoryDB?

    private var passive: [String: ExitPing] = [:]
    private var probed: [String: (ping: ExitPing, at: Date)] = [:]
    private var userUntil = Date.distantPast
    private var lastProbe = Date.distantPast
    private var lastCount = Date.distantPast

    var info: ExitInfo? { active.map { ExitCatalog.info($0.tag) } }

    func ping(_ tag: String) -> ExitPing { pings[tag] ?? .unknown }

    func reset() {
        if active != nil { active = nil }
        if available { available = false }
        if !pings.isEmpty { pings = [:] }
        passive = [:]
        probed = [:]
    }

    func refresh(client: CoreClient, visible: Bool) async {
        guard let snap = try? await client.exits() else { return }
        apply(snap)
        if available && visible && Date().timeIntervalSince(lastProbe) >= 10 {
            lastProbe = Date()
            await probeAll(client)
        }
        if available && visible && Date().timeIntervalSince(lastCount) >= 60 { await recount() }
    }

    func apply(_ snap: ExitSnapshot, now: Date = Date()) {
        if available != snap.hasSelector { available = snap.hasSelector }
        if snap.hasSelector && !supported { supported = true }
        passive = snap.pings
        if let next = snap.active {
            if let c = ExitLogic.change(prev: active, next: next) { record(c, now: now) }
            if active != next { active = next }
        }
        publishPings(now: now)
    }

    private func publishPings(now: Date = Date()) {
        let m = ExitLogic.merge(passive: passive, probed: probed, now: now)
        if m != pings { pings = m }
    }

    private func probeAll(_ client: CoreClient) async {
        let results = await withTaskGroup(of: (String, ExitPing?).self) { g -> [(String, ExitPing?)] in
            for e in ExitCatalog.list {
                g.addTask {
                    do { return (e.tag, .ms(try await client.delay(timeoutMs: 4000, proxy: e.tag))) }
                    catch CoreError.http { return (e.tag, .down) }
                    catch { return (e.tag, nil) }
                }
            }
            var out: [(String, ExitPing?)] = []
            for await r in g { out.append(r) }
            return out
        }
        let now = Date()
        for (tag, p) in results { if let p = p { probed[tag] = (p, now) } }
        publishPings(now: now)
    }

    private func record(_ c: ExitChange, now: Date) {
        let byUser = now < userUntil
        let detail = ExitLogic.detail(c, byUser: byUser)
        StateLog.write("exit change from=\(c.from.tag) to=\(c.to.tag) auto=\(c.to.auto ? 1 : 0) user=\(byUser ? 1 : 0)")
        db?.insertEvent(start: now, end: now, kind: "exit", detail: detail)
        switches += 1
        guard c.tagChanged, !byUser else { return }
        var fromDown = true
        if case .ms = ExitLogic.merge(passive: passive, probed: probed, now: now)[c.from.tag] ?? .unknown { fromDown = false }
        let n = ExitLogic.notification(c, fromDown: fromDown)
        Notifier.shared.post(kind: ExitLogic.direction(c.to.tag), title: n.title, body: n.body, interval: 60)
    }

    private func recount() async {
        guard let db = db else { return }
        lastCount = Date()
        let since = Date().addingTimeInterval(-86400)
        let n = await Task.detached { db.eventCount(kind: "exit", since: since) }.value
        if switches != n { switches = n }
    }

    func select(_ tag: String, client: CoreClient) {
        guard available, switching == nil else { return }
        guard active?.selection != tag else { return }
        switching = tag
        note = nil
        userUntil = Date().addingTimeInterval(20)
        Task { [weak self] in
            do {
                try await client.selectExit(tag)
                if let snap = try? await client.exits() { self?.apply(snap) }
            } catch {
                self?.userUntil = .distantPast
                self?.note = "не удалось переключить"
            }
            self?.switching = nil
        }
    }

    func preview(active: ActiveExit, pings: [String: ExitPing], switches: Int = 0) {
        self.active = active
        self.pings = pings
        self.available = true
        self.supported = true
        self.switches = switches
    }
}

extension ActiveExit {
    var selection: String { auto ? ExitCatalog.autoTag : tag }
}
