#if !CLIENT_EDITION
import SwiftUI
import AppKit

struct QRItem: Identifiable {
    let id = UUID()
    let name: String
    let link: String
}

struct KeysContent: View {
    @EnvironmentObject private var server: ServerModel
    @Environment(\.theme) private var t
    @State private var qr: QRItem?
    @State private var revoking: KeyRow?
    @State private var linkError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ключи").font(appFont(22, .semibold))
                    Text("У каждого устройства свой ключ — отзываешь одного, остальные работают")
                        .font(appFont(12)).foregroundColor(t.ink2)
                }
                Spacer(minLength: 12)
                refreshButton
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 14) {
                    if let e = server.notice { notice(e, color: t.warn) }
                    if let e = linkError { notice(e, color: t.alarm) }
                    if let e = server.keysError { notice(e, color: server.keys.isEmpty ? t.alarm : t.warn) }
                    if server.keys.isEmpty && server.keysError == nil {
                        Text(server.loadingKeys ? "Опрашиваю сервер…" : "Ключей нет")
                            .font(appFont(13)).foregroundColor(t.ink2)
                            .frame(maxWidth: .infinity).padding(.vertical, 40).card()
                    }
                    ForEach(server.keys) { k in
                        KeyCard(row: k, busy: server.busyName == k.name,
                                onQR: { showQR(k) }, onRevoke: { revoking = k })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                NewKeyForm(onCreated: { qr = $0 })
                    .frame(width: 270)
            }
        }
        .animation(.easeOut(duration: 0.25), value: server.keys)
        .task { await server.refreshKeys() }
        .sheet(item: $qr) { item in
            ThemedRoot { QRSheet(name: item.name, link: item.link, onClose: { qr = nil }) }
        }
        .confirmationDialog(revoking.map { "Отозвать ключ «\($0.label)»?" } ?? "", isPresented: Binding(
            get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
            Button("Отозвать", role: .destructive) {
                if let k = revoking { Task { server.notice = await server.revoke(k.name) } }
                revoking = nil
            }
            Button("Отмена", role: .cancel) { revoking = nil }
        } message: {
            Text("Устройство с этим ключом сразу потеряет доступ. Остальные ключи не заденет.")
        }
    }

    private var refreshButton: some View {
        Button { Task { await server.refreshKeys(force: true) } } label: {
            HStack(spacing: 7) {
                if server.loadingKeys {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium))
                }
                Text(server.keysAt.map { "Обновлено \(Fmt.time($0))" } ?? "Обновить").font(appNum(13))
            }
            .foregroundColor(t.navInk)
            .padding(.horizontal, 14).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.tile))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(t.line, lineWidth: 1))
        }
        .buttonStyle(PressStyle())
        .disabled(server.loadingKeys)
        .help("Запросить users и stats с сервера")
    }

    private func notice(_ text: String, color: Color) -> some View {
        Text(text).font(appFont(12.5)).foregroundColor(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.12)))
    }

    private func showQR(_ k: KeyRow) {
        linkError = nil
        Task {
            switch await server.link(k.name) {
            case .success(let l): qr = QRItem(name: k.label, link: l)
            case .failure(let e): linkError = e.text
            }
        }
    }
}

struct KeyCard: View {
    @Environment(\.theme) private var t
    let row: KeyRow
    let busy: Bool
    let onQR: () -> Void
    let onRevoke: () -> Void

    private func col(_ label: String, _ value: String, bold: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(appFont(12)).foregroundColor(t.ink2)
            Text(value).font(appNum(13.5, bold ? .semibold : .regular)).lineLimit(1)
        }
    }

    private func button(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(appFont(13)).foregroundColor(enabled ? t.navInk : t.ink3)
                .padding(.horizontal, 12).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.tile))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(t.line, lineWidth: 1))
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled || busy)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Circle().fill(row.online ? t.ok : t.ink3.opacity(0.7)).frame(width: 10, height: 10).padding(.top, 5)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.label).font(appFont(15, .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Text(row.hint).font(appFont(12)).foregroundColor(t.ink2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if busy { ProgressView().controlSize(.small).scaleEffect(0.7) }
                    button("QR", onQR)
                    button("Отозвать", enabled: row.name != "mac", onRevoke)
                        .help(row.name == "mac" ? "это твой Мак" : "Отозвать ключ")
                }
                FlowLayout(spacing: 22) {
                    col("за месяц", "↓ \(Format.bytes(row.down))  ↑ \(Format.bytes(row.up))", bold: true)
                    col("в сети", ServerLogic.relative(row.lastSeen, now: Date()))
                    col("ограничения", ServerLogic.limits(row))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct NewKeyForm: View {
    @EnvironmentObject private var server: ServerModel
    @Environment(\.theme) private var t
    @State private var name = ""
    @State private var device = 0
    @State private var noTorrent = true
    @State private var error: String?
    let onCreated: (QRItem) -> Void

    private let devices = ["iPhone / Android — QR", "Компьютер — ссылка в клиент"]

    private var problem: String? { ServerLogic.nameError(name, existing: server.keys.map { $0.name }) }
    private var canCreate: Bool { !name.isEmpty && problem == nil && !server.creating && server.live }

    private func create() {
        guard canCreate else { return }
        let n = name
        error = nil
        Task {
            switch await server.add(n, noTorrent: noTorrent) {
            case .ok(let link, let restart):
                name = ""
                server.notice = restart ? "Ключ создан, но правило торрентов применится только после перезапуска xray на сервере" : nil
                onCreated(QRItem(name: n, link: link))
            case .createdNoLink(let m):
                name = ""
                error = m
            case .failed(let m):
                error = m
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Новый ключ").font(appFont(18, .bold))
            VStack(alignment: .leading, spacing: 4) {
                Text("Имя (латиницей)").font(appFont(12)).foregroundColor(t.ink2)
                TextField("например, friend-iphone", text: $name)
                    .textFieldStyle(.plain).font(appFont(13))
                    .padding(.horizontal, 12).frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(t.bg))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(problem == nil ? t.line : t.alarm.opacity(0.8), lineWidth: 1))
                    .onSubmit(create)
                if let p = problem { Text(p).font(appFont(11.5)).foregroundColor(t.alarm).fixedSize(horizontal: false, vertical: true) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Устройство").font(appFont(12)).foregroundColor(t.ink2)
                Picker("", selection: $device) {
                    ForEach(0..<devices.count, id: \.self) { Text(devices[$0]).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu)
                Text(device == 0 ? "Откроется QR: наведи камеру в клиенте VLESS (Streisand, V2Box, Hiddify, v2rayNG)."
                                 : "Скопируй ссылку из окна QR и вставь в клиент VLESS.")
                    .font(appFont(11.5)).foregroundColor(t.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Блокировать торренты", isOn: $noTorrent)
                .toggleStyle(.checkbox).font(appFont(13)).tint(t.accent)
            if let e = error { Text(e).font(appFont(12)).foregroundColor(t.alarm).fixedSize(horizontal: false, vertical: true) }
            Button(action: create) {
                HStack(spacing: 8) {
                    if server.creating { ProgressView().controlSize(.small).scaleEffect(0.7) }
                    Text(server.creating ? "Создаю…" : "Создать ключ").font(appFont(14, .semibold))
                }
                .foregroundColor(.white).frame(maxWidth: .infinity).frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(t.accent.opacity(canCreate ? 1 : 0.45)))
            }
            .buttonStyle(PressStyle())
            .disabled(!canCreate)
            Text("Сервер добавляет ключ на лету, соединения других устройств не рвутся.")
                .font(appFont(11.5)).foregroundColor(t.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct QRSheet: View {
    @Environment(\.theme) private var t
    let name: String
    let link: String
    let onClose: () -> Void
    @State private var copied = false

    private var image: CGImage? { QRCode.cgImage(link) }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(link, forType: .string)
        let stamp = pb.changeCount
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if NSPasteboard.general.changeCount == stamp { NSPasteboard.general.clearContents() }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Ключ «\(name)»").font(appFont(18, .bold))
            if let img = image {
                Image(decorative: img, scale: 2)
                    .interpolation(.none).resizable()
                    .frame(width: CGFloat(img.width) / 2, height: CGFloat(img.height) / 2)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Text("Не удалось нарисовать QR").foregroundColor(t.alarm)
            }
            Button(action: copy) {
                Text(copied ? "Скопировано (сотрётся из буфера через минуту)" : "Скопировать ссылку")
                    .font(appFont(13, .semibold)).foregroundColor(t.btnFg)
                    .padding(.horizontal, 16).frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(t.btnBg))
            }
            .buttonStyle(PressStyle())
            Text("Ссылка — это доступ, не пересылай в открытом виде.")
                .font(appFont(12)).foregroundColor(t.ink2).multilineTextAlignment(.center)
            Button(action: onClose) {
                Text("Закрыть").font(appFont(13)).foregroundColor(t.navInk)
                    .padding(.horizontal, 16).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(t.tile))
            }
            .buttonStyle(PressStyle())
            .keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .frame(minWidth: 400)
        .background(t.bg)
        .foregroundColor(t.ink)
    }
}
#endif
