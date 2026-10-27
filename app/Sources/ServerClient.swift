#if !CLIENT_EDITION
import Foundation
import SwiftUI

final class ServerClient: @unchecked Sendable {
    static var host: String { AppConfig.shared.sshTarget }
    private let keyPath = AppConfig.shared.sshKeyPath

    func call(_ args: [String], timeout: TimeInterval = 20) async -> Result<Data, ServerError> {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async { cont.resume(returning: self.callSync(args, timeout: timeout)) }
        }
    }

    func callSync(_ args: [String], timeout: TimeInterval = 20) -> Result<Data, ServerError> {
        guard FileManager.default.fileExists(atPath: keyPath) else { return .failure(.unreachable("Нет ssh-ключа: \(AppConfig.shared.sshKey)")) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-i", keyPath, "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                       "-o", "StrictHostKeyChecking=accept-new", Self.host] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .failure(.unreachable("ssh не запустился")) }
        let timedOut = TimedFlag()
        let kill = DispatchWorkItem { timedOut.set(); if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: kill)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        kill.cancel()
        if timedOut.value { return .failure(.unreachable("Сервер не ответил за \(Int(timeout)) с")) }
        if data.isEmpty { return .failure(.unreachable("Нет связи с сервером по ssh")) }
        return .success(data)
    }
}

final class TimedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

enum AddOutcome {
    case ok(link: String, restartNeeded: Bool)
    case createdNoLink(String)
    case failed(String)
}

@MainActor
final class ServerModel: ObservableObject {
    static let healthTTL: TimeInterval = 60
    static let keysTTL: TimeInterval = 300

    @Published private(set) var health: ServerHealth?
    @Published private(set) var healthAt: Date?
    @Published private(set) var healthError: String?
    @Published private(set) var loadingHealth = false
    @Published private(set) var keys: [KeyRow] = []
    @Published private(set) var keysAt: Date?
    @Published private(set) var keysError: String?
    @Published private(set) var loadingKeys = false
    @Published var busyName: String?
    @Published var creating = false
    @Published var notice: String?

    var live: Bool
    private let client = ServerClient()

    init(live: Bool = true) { self.live = live }

    func refreshHealth(force: Bool = false) async {
        guard live, !loadingHealth else { return }
        if !force, health != nil, let t = healthAt, Date().timeIntervalSince(t) < Self.healthTTL { return }
        loadingHealth = true
        defer { loadingHealth = false }
        let r = await client.call(["health"])
        switch r.flatMap({ ServerParse.health($0) }) {
        case .success(let h):
            health = h; healthAt = Date(); healthError = nil
        case .failure(let e):
            healthError = e.text
        }
    }

    func refreshKeys(force: Bool = false) async {
        guard live, !loadingKeys else { return }
        if !force, !keys.isEmpty, let t = keysAt, Date().timeIntervalSince(t) < Self.keysTTL { return }
        loadingKeys = true
        defer { loadingKeys = false }
        async let u = client.call(["users"])
        async let s = client.call(["stats"])
        let (ur, sr) = await (u, s)
        switch ur.flatMap({ ServerParse.users($0) }) {
        case .failure(let e):
            keysError = e.text
        case .success(let users):
            var stats: ServerStats?
            var err: String?
            switch sr.flatMap({ ServerParse.stats($0) }) {
            case .success(let st): stats = st
            case .failure(let e): err = "Статистика недоступна: \(e.text)"
            }
            keys = ServerLogic.rows(users: users, stats: stats, now: Date())
            keysAt = Date()
            keysError = err
        }
    }

    func link(_ name: String) async -> Result<String, ServerError> {
        guard live else { return .failure(.unreachable("Сервер не опрашивается")) }
        busyName = name
        defer { busyName = nil }
        return await client.call(["link", name]).flatMap { ServerParse.link($0) }
    }

    func add(_ name: String, noTorrent: Bool) async -> AddOutcome {
        guard live, ServerLogic.validName(name) else { return .failed("Недопустимое имя") }
        creating = true
        defer { creating = false }
        let r = await client.call(ServerLogic.args(add: name, noTorrent: noTorrent), timeout: 40).flatMap { ServerParse.ok($0) }
        switch r {
        case .failure(let e): return .failed(e.text)
        case .success(let restart):
            await refreshKeys(force: true)
            switch await client.call(["link", name]).flatMap({ ServerParse.link($0) }) {
            case .success(let l): return .ok(link: l, restartNeeded: restart)
            case .failure(let e): return .createdNoLink("Ключ создан, но ссылку получить не удалось: \(e.text). Нажми «QR» в списке.")
            }
        }
    }

    func revoke(_ name: String) async -> String? {
        guard live, name != "mac" else { return "Этот ключ не отзывается" }
        busyName = name
        defer { busyName = nil }
        let r = await client.call(["revoke", name], timeout: 40).flatMap { ServerParse.ok($0) }
        switch r {
        case .failure(let e): return e.text
        case .success(let restart):
            await refreshKeys(force: true)
            return restart ? "Ключ отозван, но правило торрентов применится только после перезапуска xray на сервере" : nil
        }
    }

    func preview(health: ServerHealth?, keys: [KeyRow]) {
        self.health = health
        self.healthAt = Date()
        self.keys = keys
        self.keysAt = Date()
    }
}
#endif
