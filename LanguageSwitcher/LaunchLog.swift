import Darwin
import Foundation
import os

/// Append-only launch log in places easy to find (TCC is not required for the user’s own home).
enum LaunchLog {
    private static let subdir = "LanguageSwitcher"
    private static let fileName = "launch.log"
    private static let homeHintName = "LanguageSwitcher-launch.log"
    /// Создаётся в начале запуска (ещё до `NSApplication`); удобно, если TTY/stderr «молчит».
    private static let bootFilePath = "/tmp/LanguageSwitcher-boot.log"

    private static let unilog: Logger = {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.languageswitcher.app", category: "launch")
    }()

    /// В **Debug** сборке: stderr всегда, пока не задано `LANGUAGESWITCHER_LOG_STDERR=0` (и т. п.).
    /// В **Release**: как раньше — TTY, или `LANGUAGESWITCHER_LOG_STDERR=1`, выкл. через `=0`.
    private static var alsoLogToStderr: Bool {
        #if DEBUG
        if let e = ProcessInfo.processInfo.environment["LANGUAGESWITCHER_LOG_STDERR"]?.lowercased() {
            if e == "0" || e == "false" || e == "no" { return false }
        }
        return true
        #else
        if let e = ProcessInfo.processInfo.environment["LANGUAGESWITCHER_LOG_STDERR"]?.lowercased() {
            if e == "0" || e == "false" || e == "no" { return false }
            if e == "1" || e == "true" || e == "yes" { return true }
        }
        return isatty(STDERR_FILENO) != 0
        #endif
    }

    /// `/tmp` — append POSIX; `~/` и App Support — тот же `appendLine`, что `append()` (создаёт `LanguageSwitcher/` и пишет атомарно). Ранний `open(…, O_CREAT)` без существующего каталога давал `ENOENT` — `launch.log` в App Support не появлялся.
    static func markProcessStart() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let ts = ISO8601DateFormatter().string(from: Date())
        let oneLine = "\(ts) [LanguageSwitcher] markProcessStart pid=\(pid)"
        if let d = (oneLine + "\n").data(using: .utf8) { appendDataFile(d, path: bootFilePath) }
        for target in [homeFileURL(), appSupportFileURL()] { appendLine(oneLine, to: target) }
        if alsoLogToStderr, let d2 = (oneLine + "\n").data(using: .utf8) {
            d2.withUnsafeBytes { raw in
                guard let p = raw.baseAddress, raw.count > 0 else { return }
                _ = write(STDERR_FILENO, p, raw.count)
            }
        }
        NSLog("%@", oneLine)
    }

    private static func writeStderrLine(_ s: String) {
        guard let b = s.data(using: .utf8) else { return }
        b.withUnsafeBytes { raw in
            guard let p = raw.baseAddress, raw.count > 0 else { return }
            _ = write(STDERR_FILENO, p, raw.count)
        }
    }

    /// Не использовать `FileHandle(forWritingTo:)` для append — в ряде версий **обнуляет** существующий файл.
    private static func appendDataFile(_ data: Data, path: String) {
        data.withUnsafeBytes { raw in
            guard let p0 = raw.baseAddress, !data.isEmpty else { return }
            path.withCString { c in
                let fd = open(c, O_WRONLY | O_APPEND | O_CREAT, 0o600)
                guard fd >= 0 else {
                    let e = errno
                    writeStderrLine("LaunchLog: open failed errno=\(e) path=\(path)\n")
                    return
                }
                defer { close(fd) }
                _ = write(fd, p0, data.count)
            }
        }
    }

    /// Shown in the diagnostics window; first path is the easiest in Finder.
    static var humanReadablePaths: String {
        let a = appSupportFileURL().path
        let h = homeFileURL().path
        return "Лог (текст):\n• C: ctor-home, launch, App Support/launch.c-marker\n• Swift mark+append: \(h) и \(a) (один механизм appendLine)\n• \(bootFilePath) (POSIX)\n"
    }

    private static func homeFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(homeHintName, isDirectory: false)
    }

    private static func appSupportFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent(subdir, isDirectory: true).appendingPathComponent(fileName, isDirectory: false)
    }

    static func append(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)"
        for url in [homeFileURL(), appSupportFileURL()] {
            appendLine(line, to: url)
        }
        if alsoLogToStderr, let d = (line + "\n").data(using: .utf8) {
            d.withUnsafeBytes { raw in
                guard let p = raw.baseAddress, raw.count > 0 else { return }
                _ = write(STDERR_FILENO, p, d.count)
            }
        }
        unilog.info("\(line, privacy: .public)")
        #if DEBUG
        NSLog("%@", line as NSString)
        #endif
    }

    private static func appendLine(_ line: String, to file: URL) {
        let dir = file.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += line + "\n"
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            unilog.error("write failed: \(file.path, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
        }
    }
}
