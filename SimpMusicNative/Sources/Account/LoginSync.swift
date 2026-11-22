import AVFoundation
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import Network
import SwiftUI
import UIKit

/// SimpMusic's Login Sync, wire-compatible with the Android and Desktop apps
/// (core/service/loginSync): a QR carries `simpmusic://login-sync?h=<ip>&p=<port>&k=<key>`; every
/// HTTP body is AES-256-GCM `nonce(12) | ciphertext | tag(16)` with the message kind as AAD.
/// - Receive (the iPhone hosts, like Desktop): an Android phone scans our QR and sends its sign-ins.
/// - Send (the iPhone scans, like Android): we read the computer's QR and send ours.
enum LoginSyncWire {
    static func aad(_ kind: String, reply: Bool) -> Data { Data("simpmusic-login-sync/v1/\(kind)/\(reply ? "reply" : "request")".utf8) }

    static func seal(_ plain: Data, key: SymmetricKey, kind: String, reply: Bool) throws -> Data {
        try AES.GCM.seal(plain, using: key, authenticating: aad(kind, reply: reply)).combined!
    }

    static func open(_ sealed: Data, key: SymmetricKey, kind: String, reply: Bool) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: key, authenticating: aad(kind, reply: reply))
    }

    struct Invite {
        let hosts: [String]
        let port: Int
        let key: Data

        var uri: String { "simpmusic://login-sync?h=\(hosts.joined(separator: ","))&p=\(port)&k=\(key.base64URL)" }

        static func parse(_ text: String) -> Invite? {
            guard text.hasPrefix("simpmusic://login-sync?") else { return nil }
            var params: [String: String] = [:]
            for pair in text.split(separator: "?", maxSplits: 1).last!.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                params[kv[0]] = kv.count > 1 ? kv[1] : ""
            }
            let hosts = params["h"]?.split(separator: ",").map(String.init).filter { !$0.isEmpty } ?? []
            guard !hosts.isEmpty, let port = Int(params["p"] ?? ""), (1 ... 65535).contains(port),
                  let key = Data(base64URL: params["k"] ?? ""), key.count == 32 else { return nil }
            return Invite(hosts: hosts, port: port, key: key)
        }
    }

    /// What travels inside the payload (LoginSyncPayload.kt): only sign-ins.
    static func bundle() -> Data? {
        guard let cookie = Account.currentCookie else { return nil }
        let account: [String: Any] = [
            "email": "iphone@simpmusic", "name": "YouTube (iPhone)", "thumbnailUrl": "", "pageId": NSNull(),
            "authUser": 0, "cache": NSNull(), "isUsed": true, "netscapeCookie": netscape(cookie),
        ]
        let youtube: [String: Any] = ["accounts": [account], "cookie": cookie, "pageId": NSNull(), "authUser": 0, "dataSyncId": ""]
        return try? JSONSerialization.data(withJSONObject: ["youtube": youtube])
    }

    /// The cookie header as a Netscape cookie file (what yt-dlp reads on Desktop).
    static func netscape(_ cookie: String) -> String {
        let expiry = Int(Date().addingTimeInterval(180 * 86400).timeIntervalSince1970)
        let lines = cookie.split(separator: ";").compactMap { pair -> String? in
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { return nil }
            return ".youtube.com\tTRUE\t/\tTRUE\t\(expiry)\t\(kv[0])\t\(kv[1])"
        }
        return (["# Netscape HTTP Cookie File"] + lines).joined(separator: "\n") + "\n"
    }

    /// Restores a received bundle; returns the services it carried (by their wire names).
    @MainActor static func restore(_ payload: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return [] }
        var services: [String] = []
        if let youtube = json["youtube"] as? [String: Any], let cookie = youtube["cookie"] as? String, !cookie.isEmpty {
            Account.shared.signIn(cookieHeader: cookie)
            services.append("YOUTUBE")
        }
        return services
    }
}

extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") }

    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}

// MARK: Receive (iPhone hosts)

@MainActor
final class LoginSyncHost: ObservableObject {
    enum State: Equatable { case starting, waiting(String), connected, done([String]), failed(String), noNetwork }
    @Published private(set) var state: State = .starting
    private var listener: NWListener?
    private var key = SymmetricKey(size: .bits256)
    private var delivered = false

    func start() {
        stop()
        delivered = false
        key = SymmetricKey(size: .bits256)
        guard let ip = Self.wifiAddress() else { state = .noNetwork; return }
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.serve(conn) }
            }
            listener.stateUpdateHandler = { [weak self] st in
                Task { @MainActor in
                    guard let self else { return }
                    if case .ready = st, let port = self.listener?.port?.rawValue {
                        let keyData = self.key.withUnsafeBytes { Data($0) }
                        self.state = .waiting(LoginSyncWire.Invite(hosts: [ip], port: Int(port), key: keyData).uri)
                    } else if case let .failed(error) = st {
                        self.state = .failed(error.localizedDescription)
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(conn, buffer: Data())
    }

    /// Minimal HTTP/1.1: reads the request line, headers and a Content-Length body.
    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { return }
                var buf = buffer
                if let data { buf.append(data) }
                guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                    if done || error != nil || buf.count > 64 * 1024 { conn.cancel() } else { self.receive(conn, buffer: buf) }
                    return
                }
                let head = String(decoding: buf[..<headerEnd.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = buf[headerEnd.upperBound...]
                if body.count < length, length <= 4 * 1024 * 1024, !done { self.receive(conn, buffer: buf); return }
                let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let (status, reply) = self.handle(path: path, body: Data(body.prefix(length)))
                var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/octet-stream\r\nContent-Length: \(reply.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(reply)
                conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }

    private func handle(path: String, body: Data) -> (String, Data) {
        if delivered { return ("410 Gone", Data()) }
        let kind = path.replacingOccurrences(of: "/v1/", with: "")
        guard ["hello", "logins", "cancel"].contains(kind) else { return ("404 Not Found", Data()) }
        guard let plain = LoginSyncWire.open(body, key: key, kind: kind, reply: false) else { return ("403 Forbidden", Data()) }
        let reply: Data
        switch kind {
        case "hello":
            state = .connected
            reply = (try? JSONSerialization.data(withJSONObject: ["name": UIDevice.current.name, "os": "iOS \(UIDevice.current.systemVersion)"])) ?? Data()
        case "logins":
            let services = LoginSyncWire.restore(plain)
            reply = (try? JSONSerialization.data(withJSONObject: ["services": services])) ?? Data()
            delivered = true
            state = .done(services)
        default:
            if case let .waiting(uri) = state { state = .waiting(uri) } else { start(); return ("200 OK", Data()) }
            reply = Data("{}".utf8)
        }
        guard let sealed = try? LoginSyncWire.seal(reply, key: key, kind: kind, reply: true) else { return ("500 Internal Server Error", Data()) }
        return ("200 OK", sealed)
    }

    /// The Wi-Fi IPv4 address (en0), where the Android phone almost always is.
    static func wifiAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            let name = String(cString: ifa.ifa_name)
            if name == "en0" { return ip }
            if !name.hasPrefix("pdp_ip"), !ip.hasPrefix("169.254"), fallback == nil { fallback = ip }
        }
        return fallback
    }
}

// MARK: Send (iPhone scans the computer's QR)

enum LoginSyncSender {
    struct Failure: Error { let message: String }

    static func call(_ invite: LoginSyncWire.Invite, host: String, kind: String, plain: Data) async throws -> Data {
        let key = SymmetricKey(data: invite.key)
        guard let url = URL(string: "http://\(host):\(invite.port)/v1/\(kind)") else { throw Failure(message: "endereço inválido") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = kind == "hello" ? 4 : 20
        req.httpBody = try LoginSyncWire.seal(plain, key: key, kind: kind, reply: false)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 || status == 410 { throw Failure(message: "o código expirou; gere outro no computador") }
        guard status == 200, let plainReply = LoginSyncWire.open(data, key: key, kind: kind, reply: true) else { throw Failure(message: "o computador respondeu \(status)") }
        return plainReply
    }

    /// Says hello to every address in the QR and keeps the first that answers with our key.
    static func connect(_ invite: LoginSyncWire.Invite) async throws -> (host: String, name: String) {
        try await withThrowingTaskGroup(of: (String, String)?.self) { group in
            for host in invite.hosts {
                group.addTask {
                    guard let reply = try? await call(invite, host: host, kind: "hello", plain: Data()),
                          let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return nil }
                    return (host, "\(json["name"] as? String ?? "Computador") (\(json["os"] as? String ?? ""))")
                }
            }
            for try await result in group { if let result { group.cancelAll(); return result } }
            throw Failure(message: "não achei o computador; os dois precisam estar na mesma rede")
        }
    }
}

// MARK: UI

struct LoginSyncView: View {
    enum Mode { case choose, receive, send }
    @Environment(\.dismiss) private var dismiss
    @StateObject private var host = LoginSyncHost()
    @ObservedObject private var account = Account.shared
    @State private var mode: Mode = .choose
    @State private var sendStatus: String?
    @State private var busy = false
    @State private var target: (invite: LoginSyncWire.Invite, host: String, name: String)?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                switch mode {
                case .choose: chooser
                case .receive: receiveView
                case .send: sendView
                }
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(Theme.background)
            .font(Theme.poppins(15))
            .navigationTitle("Sincronizar login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } } }
        }
        .onDisappear { host.stop() }
    }

    private var chooser: some View {
        VStack(spacing: 14) {
            Button { mode = .receive; host.start() } label: {
                Label("Receber de um Android", systemImage: "arrow.down.circle").frame(maxWidth: .infinity).padding()
            }
            .buttonStyle(.bordered)
            Text("O iPhone mostra um código; leia com o SimpMusic do Android (Ajustes → Sincronizar login).").font(Theme.bodySmall).foregroundStyle(Theme.body)
            Button { mode = .send } label: {
                Label("Enviar para o computador", systemImage: "arrow.up.circle").frame(maxWidth: .infinity).padding()
            }
            .buttonStyle(.bordered)
            .disabled(!account.isSignedIn)
            Text(account.isSignedIn ? "Leia o código que o SimpMusic do computador mostra." : "Entre na conta do YouTube primeiro para poder enviar.")
                .font(Theme.bodySmall).foregroundStyle(Theme.body)
        }
    }

    @ViewBuilder
    private var receiveView: some View {
        switch host.state {
        case .starting: ProgressView()
        case let .waiting(uri):
            if let qr = Self.qr(uri) {
                Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().frame(width: 240, height: 240)
                    .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 12))
            }
            Text("No Android: Ajustes → Sincronizar login, e leia este código. Os dois na mesma rede Wi-Fi.").multilineTextAlignment(.center)
        case .connected:
            ProgressView()
            Text("Android conectado. Escolha no Android o que enviar.").multilineTextAlignment(.center)
        case let .done(services):
            Image(icon: "checkmark").font(.system(size: 40)).foregroundStyle(.green)
            Text(services.isEmpty ? "Nada que este app use foi recebido." : "Login do YouTube recebido. Pronto!")
        case let .failed(message):
            Text("Não foi possível: \(message)")
            Button("Tentar de novo") { host.start() }
        case .noNetwork:
            Text("Conecte o iPhone ao Wi-Fi e tente de novo.")
            Button("Tentar de novo") { host.start() }
        }
    }

    @ViewBuilder
    private var sendView: some View {
        if let target {
            Text("Enviar o login do YouTube para \(target.name)?").multilineTextAlignment(.center)
            if busy { ProgressView() }
            if let sendStatus { Text(sendStatus).multilineTextAlignment(.center) }
            if sendStatus == nil {
                Button("Enviar") { Task { await send(target) } }.buttonStyle(.borderedProminent).disabled(busy)
            }
        } else {
            QRScanner { code in
                guard !busy, let invite = LoginSyncWire.Invite.parse(code) else { return }
                busy = true
                Task {
                    do {
                        let found = try await LoginSyncSender.connect(invite)
                        target = (invite, found.host, found.name)
                    } catch {
                        sendStatus = (error as? LoginSyncSender.Failure)?.message ?? error.localizedDescription
                    }
                    busy = false
                }
            }
            .frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 12))
            Text(sendStatus ?? "No computador: Ajustes → Sincronizar login. Aponte a câmera para o código.").multilineTextAlignment(.center).font(Theme.bodySmall)
            if busy { ProgressView() }
        }
    }

    private func send(_ target: (invite: LoginSyncWire.Invite, host: String, name: String)) async {
        guard let payload = LoginSyncWire.bundle() else { sendStatus = "Entre na conta do YouTube primeiro."; return }
        busy = true
        defer { busy = false }
        do {
            let reply = try await LoginSyncSender.call(target.invite, host: target.host, kind: "logins", plain: payload)
            let services = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["services"] as? [String] ?? []
            sendStatus = services.contains("YOUTUBE") ? "Enviado! O computador já está com o login do YouTube." : "O computador não aceitou."
        } catch {
            sendStatus = (error as? LoginSyncSender.Failure)?.message ?? error.localizedDescription
        }
    }

    static func qr(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Camera preview that reports every QR it reads (AVFoundation's detector).
struct QRScanner: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        let session = context.coordinator.session
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted, let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else { return }
            session.beginConfiguration()
            if session.canAddInput(input) { session.addInput(input) }
            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
                output.metadataObjectTypes = [.qr]
            }
            session.commitConfiguration()
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        DispatchQueue.global().async { coordinator.session.stopRunning() }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let session = AVCaptureSession()
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            if let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue { onCode(code) }
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
