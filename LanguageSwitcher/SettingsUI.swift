import AppKit

@objc private final class SettingsApply: NSObject {
    weak var box: SettingsBox?
    @objc func save() { box?.save() }
    @objc func relex() { LexiconStore.shared.reloadFromBundleAndCache() }
    @objc func im() { _ = PermissionsHelper.openInputMonitoringSettings() }
    @objc func ax() { _ = PermissionsHelper.openAccessibilitySettings() }
    @objc func copyRow() { box?.copyRow() }
    @objc func clear() { box?.clearLog() }
    @objc func editUserEn() { box?.openUserLexiconEditor(lang: "en") }
    @objc func editUserRu() { box?.openUserLexiconEditor(lang: "ru") }
    @objc func openLexFolder() {
        NSWorkspace.shared.open(LexiconDownloadService.appSupportLexiconDir)
    }
}

private final class LexiconEditorHost: NSObject {
    let lang: String
    weak var textView: NSTextView?
    weak var window: NSWindow?

    init(lang: String) { self.lang = lang }

    @objc func save() {
        guard let tv = textView else { return }
        do {
            try LexiconStore.shared.saveUserLexiconFromEditor(lang: lang, text: tv.string)
        } catch {
            let a = NSAlert(error: error)
            a.runModal()
        }
    }

    @objc func revealInFinder() {
        let path = LexiconStore.userLexiconURL(for: lang).path
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
        } else {
            NSWorkspace.shared.open(LexiconDownloadService.appSupportLexiconDir)
        }
    }
}

/// Programmatic settings + debug log.
final class SettingsBox: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    fileprivate var window: NSWindow!
    private let o = SettingsApply()
    private var tMin, tLog, tEn, tRu, tMan: NSTextField!
    private var cAuto, cLx, cFuzzy, cInc, cIncDbg: NSButton!
    private var tFuzzyMin, tIncMin: NSTextField!
    private var tab: NSTableView!
    private var rows: [DecisionTrace] = []
    private var notif: NSObjectProtocol?
    private var lexiconEditorHosts: [LexiconEditorHost] = []

    static func newBox() -> SettingsBox {
        let s = SettingsBox()
        s.o.box = s
        s.build()
        return s
    }

    func show() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }

    private static func label(_ t: String) -> NSTextField { NSTextField(labelWithString: t) }

    private func build() {
        o.box = self
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        w.title = "LanguageSwitcher"
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
        let a = AppSettings.shared
        tMin = NSTextField(string: "\(a.minWordLength)"); tMin.frame.size = NSSize(width: 48, height: 22)
        tLog = NSTextField(string: "\(a.decisionLogSize)"); tLog.frame.size = NSSize(width: 48, height: 22)
        tEn = NSTextField(string: a.tisOverrideEN ?? ""); tEn.placeholderString = "TIS en (com.apple.keylayout.ABC), пусто=авто"
        tRu = NSTextField(string: a.tisOverrideRU ?? ""); tRu.placeholderString = "TIS ru (com.apple.keylayout.Russian)"
        tMan = NSTextField(string: a.lexiconManifestURL ?? ""); tMan.placeholderString = "HTTPS JSON {\"en\":\"https://…\",\"ru\":\"…\"}"
        cAuto = NSButton(checkboxWithTitle: "Автосмена (перехват ввода)", target: nil, action: nil)
        cAuto.state = a.isAutoSwitchEnabled ? .on : .off
        cLx = NSButton(checkboxWithTitle: "Сеть: проверка обновлений словарей", target: nil, action: nil)
        cLx.state = a.lexiconCheckUpdates ? .on : .off
        cFuzzy = NSButton(checkboxWithTitle: "Нечётко: NSSpellChecker если нет в словаре", target: nil, action: nil)
        cFuzzy.state = a.fuzzySpellEnabled ? .on : .off
        tFuzzyMin = NSTextField(string: "\(a.fuzzyMinWordLength)"); tFuzzyMin.frame.size = NSSize(width: 40, height: 22)
        cInc = NSButton(checkboxWithTitle: "По буквам: смена TIS при префиксе в словаре", target: nil, action: nil)
        cInc.state = a.incrementalLayoutSwitchEnabled ? .on : .off
        tIncMin = NSTextField(string: "\(a.incrementalPrefixMinLength)"); tIncMin.frame.size = NSSize(width: 40, height: 22)
        cIncDbg = NSButton(checkboxWithTitle: "Дебаг пошаговых скоров (~/LanguageSwitcher-launch.log)", target: nil, action: nil)
        cIncDbg.state = a.incrementalScoringDebug ? .on : .off

        let g = NSGridView(views: [
            [Self.label("min word:"), tMin, Self.label("log N:"), tLog],
            [NSView(), cAuto, NSView(), cLx],
            [Self.label("TIS EN:"), tEn, NSView(), NSView()],
            [Self.label("TIS RU:"), tRu, NSView(), NSView()],
            [Self.label("Манифест:"), tMan, NSView(), NSView()],
            [NSView(), cFuzzy, Self.label("fuzzy min:"), tFuzzyMin],
            [NSView(), cInc, Self.label("префикс min:"), tIncMin],
            [NSView(), cIncDbg, NSView(), NSView()]
        ])
        g.columnSpacing = 8; g.rowSpacing = 6; g.translatesAutoresizingMaskIntoConstraints = false
        let grid: NSView = g

        let aTarget = o
        let s = ["Сохранить", "Словари из бандла", "Input Mon.", "Accessibility", "Копир.", "Очистить"]
        let acts: [Selector] = [ #selector(aTarget.save), #selector(aTarget.relex), #selector(aTarget.im), #selector(aTarget.ax), #selector(aTarget.copyRow), #selector(aTarget.clear) ]
        let bRow = NSStackView(views: zip(s, acts).map { t, a in
            let b = NSButton(title: t, target: aTarget, action: a)
            b.bezelStyle = .rounded; return b
        })
        bRow.orientation = .horizontal; bRow.spacing = 6

        let lexHint = NSTextField(wrappingLabelWithString: "Двойной Ctrl: переключить слово RU↔латиница и записать новую форму в user-словарь (работает даже при выкл. автосмене).")
        lexHint.textColor = .secondaryLabelColor

        let lexBtns = NSStackView(views: [
            NSButton(title: "User EN…", target: aTarget, action: #selector(SettingsApply.editUserEn)),
            NSButton(title: "User RU…", target: aTarget, action: #selector(SettingsApply.editUserRu)),
            NSButton(title: "Папка словарей", target: aTarget, action: #selector(SettingsApply.openLexFolder))
        ])
        for b in lexBtns.arrangedSubviews.compactMap({ $0 as? NSButton }) { b.bezelStyle = .rounded }
        lexBtns.orientation = .horizontal
        lexBtns.spacing = 6

        let sc = NSScrollView()
        sc.hasVerticalScroller = true; sc.hasHorizontalScroller = false; sc.borderType = .bezelBorder; sc.wantsLayer = true
        tab = NSTableView()
        for (ti, wv) in [("t", 160.0 as CGFloat), ("m", 500.0)] {
            let c = NSTableColumn(identifier: .init(ti))
            c.width = wv; c.minWidth = 50; c.title = ti == "t" ? "Когда" : "Событие"
            tab.addTableColumn(c)
        }
        tab.dataSource = self; tab.delegate = self; sc.documentView = tab; tab.rowHeight = 28

        let st = NSStackView(views: [grid, lexHint, lexBtns, bRow, sc])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.orientation = .vertical; st.spacing = 8
        w.contentView?.addSubview(st)
        let root = w.contentView!
        NSLayoutConstraint.activate([
            st.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            st.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            st.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            st.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            sc.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            sc.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
        notif = NotificationCenter.default.addObserver(
            forName: .languageSwitcherDecisions, object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
    }

    deinit { if let n = notif { NotificationCenter.default.removeObserver(n) } }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        if row < 0 || row >= rows.count { return nil }
        if tableColumn?.identifier.rawValue == "t" { return ISO8601DateFormatter().string(from: rows[row].date) }
        if tableColumn?.identifier.rawValue == "m" { return rows[row].reasonHuman }
        return nil
    }

    fileprivate func save() {
        let a = AppSettings.shared
        a.minWordLength = min(10, max(1, Int(tMin?.stringValue ?? "2") ?? 2))
        a.decisionLogSize = min(200, max(5, Int(tLog?.stringValue ?? "30") ?? 30))
        a.tisOverrideEN = (tEn?.stringValue ?? "").isEmpty ? nil : tEn?.stringValue
        a.tisOverrideRU = (tRu?.stringValue ?? "").isEmpty ? nil : tRu?.stringValue
        a.lexiconManifestURL = (tMan?.stringValue ?? "").isEmpty ? nil : tMan?.stringValue
        a.isAutoSwitchEnabled = (cAuto.state == .on)
        a.lexiconCheckUpdates = (cLx.state == .on)
        a.fuzzySpellEnabled = (cFuzzy.state == .on)
        a.fuzzyMinWordLength = min(12, max(3, Int(tFuzzyMin?.stringValue ?? "4") ?? 4))
        a.incrementalLayoutSwitchEnabled = (cInc.state == .on)
        a.incrementalPrefixMinLength = min(12, max(1, Int(tIncMin?.stringValue ?? "2") ?? 2))
        a.incrementalScoringDebug = (cIncDbg.state == .on)
    }
    fileprivate func copyRow() {
        let r = tab?.selectedRow ?? -1; guard r >= 0, r < rows.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rows[r].reasonHuman, forType: .string)
    }
    fileprivate func clearLog() { DecisionLog.shared.clear(); reload() }
    private func reload() { rows = DecisionLog.shared.items; tab?.reloadData() }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w !== window else { return }
        lexiconEditorHosts.removeAll { $0.window === w }
    }

    fileprivate func openUserLexiconEditor(lang: String) {
        let k = EnabledKeyboardSourcesRegistry.normalizeLangTag(lang)
        guard !k.isEmpty else { return }
        let host = LexiconEditorHost(lang: k)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        w.title = "user-\(k).txt — свои слова"
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self

        let tv = NSTextView()
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.string = LexiconStore.shared.userLexiconRawText(for: k)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = tv

        let save = NSButton(title: "Сохранить", target: host, action: #selector(LexiconEditorHost.save))
        save.bezelStyle = .rounded
        let reveal = NSButton(title: "Показать файл", target: host, action: #selector(LexiconEditorHost.revealInFinder))
        reveal.bezelStyle = .rounded
        let btnRow = NSStackView(views: [save, reveal])
        btnRow.orientation = .horizontal
        btnRow.spacing = 8

        let root = NSStackView(views: [scroll, btnRow])
        root.orientation = .vertical
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false

        w.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 420))
        w.contentView?.addSubview(root)
        guard let cv = w.contentView else { return }
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: cv.topAnchor, constant: 8),
            root.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 8),
            root.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -8),
            root.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -8),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300)
        ])

        host.textView = tv
        host.window = w
        lexiconEditorHosts.append(host)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
