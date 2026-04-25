import AppKit
import CoreGraphics

extension CGEvent {
    var vKey: UInt16 { UInt16(truncatingIfNeeded: getIntegerValueField(.keyboardEventKeycode)) }

    /// `NSEvent(cgEvent:)` is often `nil` for `CGEventTap` callbacks; flags still come from `CGEvent`.
    var nsModifierFlags: NSEvent.ModifierFlags {
        var m = NSEvent.ModifierFlags()
        if flags.contains(.maskShift) { m.insert(.shift) }
        if flags.contains(.maskControl) { m.insert(.control) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskCommand) { m.insert(.command) }
        if flags.contains(.maskSecondaryFn) { m.insert(.function) }
        return m
    }

    var isKeyAutorepeat: Bool { getIntegerValueField(.keyboardEventAutorepeat) != 0 }
}
