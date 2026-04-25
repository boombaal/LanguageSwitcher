import AppKit
import Foundation

/// Вместо `@main` на `AppDelegate`: явно назначаем `delegate` до `NSApplicationMain`, иначе
/// на части сочетаний Xcode 26+ / Swift 6+ `applicationWillFinishLaunching` не приходил — логи
/// и `LaunchLog.markProcessStart` не писались, хотя C-конструктор работал.
@main
enum AppMain {
    /// `NSApplication.delegate` is weak; keep the delegate alive for the process lifetime.
    private static var delegateHolder: AppDelegate?
    static func main() {
        let delegate = AppDelegate()
        delegateHolder = delegate
        NSApplication.shared.delegate = delegate
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}
