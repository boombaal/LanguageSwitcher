import AppKit
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: SettingsBox?
    private var tap: EventTapController!
    private var status: StatusBarController!

    override init() {
        super.init()
    }

    func applicationWillFinishLaunching(_: Notification) {
        LaunchLog.markProcessStart()
        LaunchLog.append("0 applicationWillFinishLaunching")
    }

    func applicationDidFinishLaunching(_: Notification) {
        LaunchLog.append("1 applicationDidFinishLaunching enter")
        _ = NSApp.setActivationPolicy(.regular)
        LaunchLog.append("2 setActivationPolicy(regular)")

        PermissionsHelper.promptAccessibililtyDialogOnce()
        LaunchLog.append("3 after AXIsProcessTrusted prompt call")

        EnabledKeyboardSourcesRegistry.shared.startMonitoring()
        LexiconStore.shared.reloadFromBundleAndCache()
        LexiconDownloadService.shared.refreshManifestDownloadsIfNeeded(
            enabledLangs: EnabledKeyboardSourcesRegistry.shared.enabledLangTags
        )
        NotificationCenter.default.addObserver(
            forName: .keyboardSourcesRegistryDidChange,
            object: nil,
            queue: .main
        ) { _ in
            LexiconDownloadService.shared.refreshManifestDownloadsIfNeeded(
                enabledLangs: EnabledKeyboardSourcesRegistry.shared.enabledLangTags
            )
        }

        tap = EventTapController(lex: LexiconStore.shared) { t in
            DispatchQueue.main.async { DecisionLog.shared.push(t) }
        }
        LaunchLog.append("4 EventTap created")

        DispatchQueue.main.async { [self] in
            LaunchLog.append("5 main async: UI+tap")
            self.status = StatusBarController(tap: self.tap) { [weak self] in self?.openSettings() }
            self.tap.start()
            LaunchLog.append("6 tap start failedToCreate=\(self.tap.failedToCreateTap)")
            LaunchDiagnostics.show(
                tapFailed: self.tap.failedToCreateTap,
                tapMessage: self.tap.tapFailureUserMessage,
                axOK: PermissionsHelper.isAccessibilityTrusted
            ) { [weak self] in self?.openSettings() }
            NSApp.activate(ignoringOtherApps: true)
            LaunchLog.append("7 LaunchDiagnostics shown, bundle=\(Bundle.main.bundlePath)")
        }
    }

    private func openSettings() {
        if settings == nil { settings = SettingsBox.newBox() }
        settings?.show()
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openSettings() }
        return true
    }
}
