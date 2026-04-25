import AppKit

final class StatusBarController: NSObject {
    private var item: NSStatusItem!
    private weak var tap: EventTapController?
    private let settingsOpener: () -> Void

    init(tap: EventTapController, openSettings: @escaping () -> Void) {
        self.tap = tap
        self.settingsOpener = openSettings
        super.init()
        let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = i.button {
            let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
            b.toolTip = "LanguageSwitcher build \(build)"
            b.appearsDisabled = false
            b.title = "LS\(build)"
            b.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            b.imagePosition = .imageLeft
            if let img = NSImage(systemSymbolName: "character.textbox", accessibilityDescription: "LanguageSwitcher") {
                img.isTemplate = true
                b.image = img
            } else {
                b.image = nil
            }
        }
        if #available(macOS 11.0, *) { i.isVisible = true }
        let m = NSMenu()
        m.addItem(withTitle: "Настройки…", action: #selector(openS), keyEquivalent: ",")
        m.items.last?.target = self
        m.addItem(withTitle: "Проверить разрешения", action: #selector(openPerm), keyEquivalent: "")
        m.items.last?.target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Перезапустить перехват", action: #selector(restart), keyEquivalent: "r")
        m.items.last?.keyEquivalentModifierMask = [.option, .command]
        m.items.last?.target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Выход", action: #selector(quit), keyEquivalent: "q")
        m.items.last?.target = self
        i.menu = m
        item = i
    }

    @objc private func openS() { settingsOpener() }
    @objc private func openPerm() {
        PermissionsHelper.promptAccessibililtyDialogOnce()
        _ = PermissionsHelper.openAccessibilitySettings()
        _ = PermissionsHelper.openInputMonitoringSettings()
    }
    @objc private func restart() { tap?.stop(); tap?.start() }
    @objc private func quit() { NSApp.terminate(nil) }
}
