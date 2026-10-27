import SwiftUI
import AppKit
import Carbon.HIToolbox

enum MainWindow {
    static let notification = Notification.Name("dev.vpnstatusbar.openmain")

    private static func find() -> NSWindow? {
        NSApp.windows.first { $0.title == "VPN" && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
    }

    @MainActor static func show(open: @escaping () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        if let w = find() {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
            return
        }
        open()
        func front(_ tries: Int) {
            if let w = find() {
                w.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else if tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { front(tries - 1) }
            }
        }
        DispatchQueue.main.async { front(30) }
    }
}

enum HotKey {
    nonisolated(unsafe) static var registered = false
    nonisolated(unsafe) static var status: OSStatus = -1
    nonisolated(unsafe) private static var action: (() -> Void)?
    nonisolated(unsafe) private static var ref: EventHotKeyRef?
    nonisolated(unsafe) private static var handler: EventHandlerRef?

    static let text = "⌥⌘V"

    static func install(_ act: @escaping () -> Void) {
        action = act
        guard ref == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x56504E6D), id: 1)
        status = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
        registered = status == noErr
        StateLog.write("hotkey \(text) register status=\(status)")
    }
}

struct ShieldLabel: View {
    @ObservedObject var model: VPNModel
    var body: some View { HotkeyHost(image: ShieldIcon.image(for: model.state)) }
}

struct HotkeyHost: View {
    @Environment(\.openWindow) private var openWindow
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .onAppear {
                let open = { openWindow(id: "main") }
                HotKey.install { MainActor.assumeIsolated { MainWindow.show(open: open) } }
                DistributedNotificationCenter.default().addObserver(forName: MainWindow.notification, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { MainWindow.show(open: open) }
                }
            }
    }
}
