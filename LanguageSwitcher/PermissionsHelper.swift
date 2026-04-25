import AppKit
import ApplicationServices
import CoreFoundation
import Foundation

/// Input Monitoring: System Settings → Privacy & Security → Input Monitoring.
/// Accessibility: system prompt via `kAXTrustedCheckOptionPrompt` + same pane for Accessibility.
enum PermissionsHelper {
    private static var axPrompted = false

    static var isInputMonitoringAssumed: Bool = true
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func promptAccessibililtyDialogOnce() {
        guard !axPrompted else { return }
        axPrompted = true
        // Bool `true` in NSDictionary can bridge badly for AXIsProcessTrustedWithOptions,
        // which then calls CFGetTypeID on a null value. Use kCFBooleanTrue. The prompt key
        // is an Unmanaged<CFString> in the Swift import.
        let k = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options: [CFString: CFTypeRef] = [k: kCFBooleanTrue!]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    @discardableResult
    static func openInputMonitoringSettings() -> Bool {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { return NSWorkspace.shared.open(u) }
        return false
    }

    @discardableResult
    static func openAccessibilitySettings() -> Bool {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { return NSWorkspace.shared.open(u) }
        return false
    }
}
