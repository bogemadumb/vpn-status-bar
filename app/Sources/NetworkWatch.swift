import Foundation
import Network

final class NetworkWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "vpnmonitor.netwatch")
    private let order: [NWInterface.InterfaceType] = [.wiredEthernet, .wifi, .cellular]
    private var monitors: [NWPathMonitor] = []
    private var flags: [NWInterface.InterfaceType: (up: Bool, expensive: Bool)] = [:]
    private let onChange: @Sendable (Bool, String) -> Void

    init(onChange: @escaping @Sendable (Bool, String) -> Void) {
        self.onChange = onChange
    }

    func start() {
        for type in order {
            let m = NWPathMonitor(requiredInterfaceType: type)
            m.pathUpdateHandler = { [weak self] path in self?.update(type, path) }
            m.start(queue: queue)
            monitors.append(m)
        }
    }

    private func update(_ type: NWInterface.InterfaceType, _ path: NWPath) {
        flags[type] = (path.status == .satisfied, path.isExpensive || path.isConstrained)
        let active = order.first { flags[$0]?.up == true }
        let label: String
        switch active {
        case .some(.wiredEthernet): label = "ethernet"
        case .some(.wifi): label = "wifi"
        case .some(.cellular): label = "cellular"
        default: label = "none"
        }
        onChange(active.flatMap { flags[$0]?.expensive } ?? false, label)
    }
}

enum StateLog {
    static let dir = NSHomeDirectory() + "/Library/Logs/VPNMonitor"
    static let path = dir + "/state.log"
    private static let limit = 1_000_000
    nonisolated(unsafe) static var enabled = true
    nonisolated(unsafe) private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f
    }()

    static func write(_ line: String) {
        guard enabled else { return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size >= limit {
            try? fm.removeItem(atPath: path + ".1")
            try? fm.moveItem(atPath: path, toPath: path + ".1")
        }
        let data = Data("\(stamp.string(from: Date())) \(line)\n".utf8)
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            fm.createFile(atPath: path, contents: data)
        }
    }
}
