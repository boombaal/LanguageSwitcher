import Foundation
import AppKit

extension Notification.Name { static let languageSwitcherDecisions = Notification.Name("app.ls.decisions") }

/// Ring buffer of recent `DecisionTrace` (thread-safe enough if app only posts from main for UI).
final class DecisionLog: NSObject {
    static let shared = DecisionLog()
    private var lock = NSLock()
    private var storage: [DecisionTrace] = []

    var items: [DecisionTrace] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func push(_ t: DecisionTrace) {
        let maxN = AppSettings.shared.decisionLogSize
        lock.lock()
        storage.append(t)
        while storage.count > maxN, !storage.isEmpty { storage.removeFirst() }
        lock.unlock()
        NotificationCenter.default.post(name: .languageSwitcherDecisions, object: t)
    }

    func clear() {
        lock.lock()
        storage = []
        lock.unlock()
        NotificationCenter.default.post(name: .languageSwitcherDecisions, object: nil)
    }
}
