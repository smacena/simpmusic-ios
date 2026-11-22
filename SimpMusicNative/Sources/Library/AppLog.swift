import Foundation
import UIKit

/// The on-disk app log, after core/common's Logger.kt: Info and above go to `app.log` (rolls at
/// 1 MB, 3 files), Error alone to `error.log` (512 KB, 2 files). Same line shape as Kermit's
/// RollingFileLogWriter + LogLineFormatter: `2026-10-06T07:02:31.802Z I/Tag: message`, with a
/// stack trace (if any) on the lines after. Debug goes to the console only.
enum AppLog {
    static let appLog = "app"
    static let errorLog = "error"
    private static let appFiles = 3
    private static let errorFiles = 2

    static let directory: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/app", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let queue = DispatchQueue(label: "simpmusic.applog")
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// The files behind [name], oldest first: `<name>-N.log` the older ones, `<name>.log` the live one.
    static func files(_ name: String) -> [URL] {
        let count = name == errorLog ? errorFiles : appFiles
        return (0 ..< count).reversed().map { i in
            directory.appendingPathComponent(i == 0 ? "\(name).log" : "\(name)-\(i).log")
        }
    }

    static func d(_ tag: String, _ message: String) { NSLog("D/\(tag): \(message)") }
    static func i(_ tag: String, _ message: String) { write("I", tag, message, nil) }
    static func w(_ tag: String, _ message: String) { write("W", tag, message, nil) }
    static func e(_ tag: String, _ message: String, _ error: Error? = nil) {
        var detail: String?
        if let error { detail = "\(type(of: error)): \(error)" }
        write("E", tag, message, detail)
    }

    /// Writes synchronously: used from the crash handler, where the process is about to end.
    static func assert(_ tag: String, _ message: String, trace: [String]) {
        queue.sync { append("A", tag, message, trace.joined(separator: "\n")) }
    }

    private static func write(_ level: Character, _ tag: String, _ message: String, _ detail: String?) {
        NSLog("\(level)/\(tag): \(message)")
        queue.async { append(level, tag, message, detail) }
    }

    private static func append(_ level: Character, _ tag: String, _ message: String, _ detail: String?) {
        var line = "\(stamp.string(from: Date())) \(level)/\(tag): \(message.replacingOccurrences(of: "\n", with: " "))\n"
        if let detail, !detail.isEmpty { line += detail + "\n" }
        guard let data = line.data(using: .utf8) else { return }
        appendTo(appLog, data, rollOnSize: 1_000_000)
        if level == "E" || level == "A" { appendTo(errorLog, data, rollOnSize: 512_000) }
    }

    private static func appendTo(_ name: String, _ data: Data, rollOnSize: Int) {
        let all = files(name)
        let live = all.last!
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: live.path)[.size] as? Int) ?? 0
        if size + data.count > rollOnSize {
            // Shift: name-(n-2) → name-(n-1) … name.log → name-1.log; the oldest falls off.
            for i in 0 ..< all.count - 1 {
                let target = all[i], source = all[i + 1]
                try? fm.removeItem(at: target)
                try? fm.moveItem(at: source, to: target)
            }
        }
        if !fm.fileExists(atPath: live.path) { fm.createFile(atPath: live.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: live) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// Uncaught Objective-C exceptions land in error.log with their call stack.
    static func installCrashHandler() {
        NSSetUncaughtExceptionHandler { exception in
            AppLog.assert("Crash", "\(exception.name.rawValue): \(exception.reason ?? "")", trace: exception.callStackSymbols)
        }
        i("App", "SimpMusic Native \(version) · iOS \(UIDevice.current.systemVersion) started")
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    // MARK: Export

    /// Cookies, tokens and auth headers never leave the device in an export (AppLogFiles.kt SECRETS).
    private static let secrets: [(NSRegularExpression, String)] = [
        (#"(?i)\b(authorization|cookie|set-cookie)(\s*[:=]\s*)[^\r\n]+"#, "$1$2[redacted]"),
        (#"\b(SAPISID|APISID|HSID|SSID|SID|SIDCC|LOGIN_INFO|sp_dc|sp_key|__Secure-[\w-]+)=[^;\s&"']+"#, "$1=[redacted]"),
        (#"(?i)([?&](?:key|token|access_token|refresh_token|api_key|sig|signature)=)[^&\s"']+"#, "$1[redacted]"),
        (#"(?i)\b(bearer\s+)[\w.~+/=-]+"#, "$1[redacted]"),
        (#"\bsk-[\w-]{16,}"#, "sk-[redacted]"),
        (#"((?:TRUE|FALSE)\t\d+\t[^\t\r\n]+\t)[^\t\r\n]+"#, "$1[redacted]"),
        (#"(?i)([?&/]ip[=/])[0-9a-f:.]+"#, "$1[redacted]"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func redact(_ text: String) -> String {
        secrets.reduce(text) { acc, pair in
            pair.0.stringByReplacingMatches(in: acc, range: NSRange(acc.startIndex..., in: acc), withTemplate: pair.1)
        }
    }

    /// Every log file, oldest first, redacted, as one text file ready to share.
    static func export() -> URL? {
        var text = "SimpMusic Native \(version) · iOS \(UIDevice.current.systemVersion)\n"
        for name in [appLog, errorLog] {
            text += "\n===== \(name).log =====\n"
            for file in files(name) { if let s = try? String(contentsOf: file, encoding: .utf8) { text += s } }
        }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("simpmusic-log-\(f.string(from: Date())).txt")
        do { try redact(text).write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
        return url
    }
}

// MARK: Reading back (AppLogFiles.kt)

struct LogLine: Identifiable, Equatable {
    let id: Int
    let date: Date
    let level: Character
    let tag: String
    let message: String
    var detail: String

    var isError: Bool { level == "E" || level == "A" }
    func matches(_ q: String) -> Bool {
        q.isEmpty || tag.localizedCaseInsensitiveContains(q) || message.localizedCaseInsensitiveContains(q)
    }
    func render() -> String { "\(LogLine.clock(date)) \(level)/\(tag): \(message)" + (detail.isEmpty ? "" : "\n\(detail)") }

    static func rank(_ level: Character) -> Int { Array("VDIWEA").firstIndex(of: level) ?? 0 }

    /// `HH:mm:ss.SSS` for today, the date in front for anything older.
    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm:ss.SSS" : "dd/MM HH:mm:ss.SSS"
        return f.string(from: date)
    }
}

/// Follows one rolling log the way `tail -f` does: the first poll reads every file, later ones
/// only what was appended to the live file since.
final class LogTail {
    private let name: String
    private let keep: Int
    private var liveOffset: UInt64 = 0
    private var started = false
    private var nextId = 0
    private(set) var lines: [LogLine] = []

    init(_ name: String, keep: Int) { self.name = name; self.keep = keep }

    func reset() { started = false; liveOffset = 0; lines = [] }

    /// True when `lines` changed.
    func poll() -> Bool {
        let files = AppLog.files(name)
        let live = files.last!
        let size = (try? FileManager.default.attributesOfItem(atPath: live.path)[.size] as? UInt64) ?? 0
        if !started || size < liveOffset {
            started = true
            nextId = 0
            lines = []
            var text = ""
            for f in files.dropLast() { if let s = try? String(contentsOf: f, encoding: .utf8) { text += s } }
            let (liveText, end) = Self.readComplete(live, from: 0)
            liveOffset = end
            append(text + liveText)
            return true
        }
        if size == liveOffset { return false }
        let (text, end) = Self.readComplete(live, from: liveOffset)
        liveOffset = end
        if text.isEmpty { return false }
        append(text)
        return true
    }

    private func append(_ text: String) {
        let (leading, parsed) = Self.parse(text, firstId: nextId)
        nextId += parsed.count
        if !leading.isEmpty, var last = lines.popLast() {
            last.detail = [last.detail, leading].filter { !$0.isEmpty }.joined(separator: "\n")
            lines.append(last)
        }
        lines += parsed
        if lines.count > keep { lines.removeFirst(lines.count - keep) }
    }

    private static func readComplete(_ file: URL, from: UInt64) -> (String, UInt64) {
        guard let h = try? FileHandle(forReadingFrom: file) else { return ("", 0) }
        defer { try? h.close() }
        try? h.seek(toOffset: from)
        guard let data = try? h.readToEnd(), let nl = data.lastIndex(of: 0x0A) else { return ("", from) }
        let slice = data[data.startIndex ... nl]
        return (String(decoding: slice, as: UTF8.self), from + UInt64(slice.count))
    }

    private static let head = try! NSRegularExpression(pattern: #"^(\S+) ([VDIWEA])/([^:]*): (.*)$"#)
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parse(_ text: String, firstId: Int) -> (String, [LogLine]) {
        var leading: [String] = []
        var out: [LogLine] = []
        var current: LogLine?
        var detail: [String] = []
        func close() {
            guard var c = current else { return }
            c.detail = detail.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(c)
            detail = []
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(raw)
            let ns = s as NSString
            if let m = head.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
               let date = iso.date(from: ns.substring(with: m.range(at: 1))) {
                close()
                current = LogLine(id: firstId + out.count, date: date, level: Character(ns.substring(with: m.range(at: 2))),
                                  tag: ns.substring(with: m.range(at: 3)), message: ns.substring(with: m.range(at: 4)), detail: "")
            } else if !s.trimmingCharacters(in: .whitespaces).isEmpty {
                if current == nil { leading.append(s) } else { detail.append(s) }
            }
        }
        close()
        return (leading.joined(separator: "\n"), out)
    }
}
