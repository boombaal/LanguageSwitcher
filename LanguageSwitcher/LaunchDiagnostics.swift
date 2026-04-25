import AppKit

/// Shown on launch: tap/AX + bundle path. Uses **frame layout only** (no Auto Layout) so the window is always visible.
@objc private final class LaunchDiagnosticsController: NSObject {
    var openSettings: (() -> Void)?
    weak var panel: NSPanel?
    @objc func openIM() { _ = PermissionsHelper.openInputMonitoringSettings() }
    @objc func openAX() { _ = PermissionsHelper.openAccessibilitySettings() }
    @objc func doSettings() { openSettings?() }
    @objc func hide() { panel?.orderOut(nil) }
}

enum LaunchDiagnostics {
    private static let ctrl = LaunchDiagnosticsController()
    private static var panel: NSPanel?

    static func show(tapFailed: Bool, tapMessage: String? = nil, axOK: Bool, onOpenSettings: (() -> Void)?) {
        if panel != nil { return }
        let w: CGFloat = 540
        let h: CGFloat = 420
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        p.title = "LanguageSwitcher — диагностика"
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        ctrl.openSettings = onOpenSettings
        ctrl.panel = p
        self.panel = p

        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
        let rpath = Bundle.main.bundlePath
        let tapLine: String = {
            if tapFailed, let m = tapMessage, !m.isEmpty { return m }
            if tapFailed {
                return "• Клавиатурный тап: НЕ СОЗДАН — включите Input Monitoring для пути (ниже), Quit и снова запустите .app"
            }
            return "• Клавиатурный тап: создан. Срабатывание: пробел/Enter/Tab в конце слова (см. README). Тест: рус. раскладка → test → пробел. Лог: ~/LanguageSwitcher-launch.log — ищите «first keyDown» (любой ключ в TextEdit)."
        }()
        let axLine = axOK
            ? "• Accessibility: OK"
            : "• Accessibility: нет — включите LanguageSwitcher, затем Quit и перезапустите"
        // Длинный блок про TCC/подпись нужен при сбоях; при OK — только краткие строки.
        let tccNote: String
        if tapFailed || !axOK {
            tccNote = """
TCC и подпись: разрешения привязаны к **подписи** бинарника, а не только к пути. Проект раньше собирался с CODE_SIGNING_ALLOWED=NO (без подписи) — macOS часто **не применяет** такие разрешения. Сейчас включена ad-hoc подпись; после первой такой сборки: **снимите** LanguageSwitcher с обоих списков (Input Monitoring и Accessibility), **+** и снова выберите этот .app, Quit, `open` на .app. Стабильнее: в Xcode — Signing & Capabilities — Team (бесплатный Apple ID) — *Sign to Run Locally*.

"""
        } else {
            tccNote = ""
        }
        let text = "\(LaunchLog.humanReadablePaths)\nBuild \(build)\n\n\(tccNote)\(tapLine)\n\n\(axLine)\n\nПуть (должен совпадать с TCC):\n\(rpath)"
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .systemFont(ofSize: 12)
        tv.string = text
        let sc = NSScrollView(frame: .zero)
        sc.hasVerticalScroller = true
        sc.hasHorizontalScroller = false
        sc.drawsBackground = true
        sc.borderType = .bezelBorder
        sc.autoresizingMask = [.width, .height]
        sc.documentView = tv
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: 1e7)
        tv.maxSize = NSSize(width: 1e6, height: 1e7)
        tv.minSize = NSSize(width: 0, height: 0)
        sc.frame = NSRect(x: 20, y: 52, width: w - 40, height: 300)
        p.contentView?.addSubview(sc)

        func addBtn(_ t: String, _ sel: Selector, _ x: CGFloat) -> NSButton {
            let b = NSButton(title: t, target: ctrl, action: sel)
            b.bezelStyle = .rounded
            b.frame = NSRect(x: x, y: 8, width: 124, height: 32)
            p.contentView?.addSubview(b)
            return b
        }
        _ = addBtn("Input Mon…", #selector(LaunchDiagnosticsController.openIM), 20)
        _ = addBtn("Access…", #selector(LaunchDiagnosticsController.openAX), 148)
        _ = addBtn("Настр…", #selector(LaunchDiagnosticsController.doSettings), 276)
        _ = addBtn("Скрыть", #selector(LaunchDiagnosticsController.hide), 404)

        p.setContentSize(NSSize(width: w, height: h))
        p.contentView?.autoresizingMask = [.width, .height]
        p.center()
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
