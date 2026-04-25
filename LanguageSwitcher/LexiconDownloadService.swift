import Foundation

/// Downloads `{ "en": "https://...", "ru": "..." }` lexicon manifest into Application Support cache.
final class LexiconDownloadService {
    static let shared = LexiconDownloadService()

    private let queue = DispatchQueue(label: "LanguageSwitcher.LexiconDownload", qos: .utility)
    private var session: URLSession!

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 120
        session = URLSession(configuration: cfg)
    }

    static var appSupportLexiconDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("LanguageSwitcher", isDirectory: true)
            .appendingPathComponent("Lexicon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cacheFileURL(for lang: String) -> URL? {
        let l = EnabledKeyboardSourcesRegistry.normalizeLangTag(lang)
        guard !l.isEmpty else { return nil }
        return appSupportLexiconDir.appendingPathComponent("\(l).txt")
    }

    /// Lang tags that already have a `.txt` file in cache (any size).
    static func cachedLangFiles() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(at: appSupportLexiconDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return names.compactMap { u -> String? in
            guard u.pathExtension == "txt" else { return nil }
            return u.deletingPathExtension().lastPathComponent
        }
    }

    /// Parse manifest JSON and download each listed language (HTTPS only).
    func refreshManifestDownloadsIfNeeded(enabledLangs: [String]) {
        guard let manifestURLString = AppSettings.shared.lexiconManifestURL,
              let manifestURL = URL(string: manifestURLString),
              manifestURL.scheme?.lowercased() == "https"
        else { return }
        queue.async { [weak self] in
            self?.runManifestDownload(manifestURL: manifestURL, enabledLangs: enabledLangs)
        }
    }

    private func runManifestDownload(manifestURL: URL, enabledLangs: [String]) {
        let sem = DispatchSemaphore(value: 0)
        var manifestData: Data?
        let task = session.dataTask(with: manifestURL) { data, _, _ in
            manifestData = data
            sem.signal()
        }
        task.resume()
        sem.wait()
        guard let data = manifestData,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            LaunchLog.append("LexiconDownload: manifest parse failed")
            return
        }
        let want = Set(enabledLangs.map { EnabledKeyboardSourcesRegistry.normalizeLangTag($0) }.filter { !$0.isEmpty })
        for (key, val) in obj {
            let lang = EnabledKeyboardSourcesRegistry.normalizeLangTag(key)
            guard want.contains(lang), let urlStr = val as? String, let fileURL = URL(string: urlStr), fileURL.scheme?.lowercased() == "https" else { continue }
            downloadOne(lang: lang, from: fileURL)
        }
        DispatchQueue.main.async {
            LexiconStore.shared.reloadFromBundleAndCache()
            NotificationCenter.default.post(name: .lexiconStoreDidReload, object: nil)
        }
    }

    private func downloadOne(lang: String, from url: URL) {
        let sem = DispatchSemaphore(value: 0)
        var outData: Data?
        session.dataTask(with: url) { data, _, _ in
            outData = data
            sem.signal()
        }.resume()
        sem.wait()
        guard let raw = outData, let text = String(data: raw, encoding: .utf8), !text.isEmpty else {
            LaunchLog.append("LexiconDownload: empty \(lang) from \(url)")
            return
        }
        guard let dest = Self.cacheFileURL(for: lang) else { return }
        let tmp = dest.appendingPathExtension("tmp")
        do {
            try text.write(to: tmp, atomically: true, encoding: .utf8)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tmp, to: dest)
            LaunchLog.append("LexiconDownload: saved \(lang) → \(dest.path)")
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            LaunchLog.append("LexiconDownload: write failed \(lang): \(error)")
        }
    }
}

extension Notification.Name {
    static let lexiconStoreDidReload = Notification.Name("LanguageSwitcher.lexiconStoreDidReload")
}
