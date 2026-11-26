import Foundation

// Checks SystemDockRules.swift: Petal's own hiding of macOS's Dock is never kept or put back as the person's own
// settings, and a Dock left hidden by Petal with nothing saved is shown again. Run with macos/checks/run.sh.
@main
struct SystemDockRulesCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    /// The settings as Config.readObject gives them back from macos-dock.json.
    static func json(_ object: [String: Any]) -> [String: Any] {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    static func main() {
        // Petal's wait, and the long waits around it, are Petal's hiding; the person's own short waits aren't.
        expect(SystemDockRules.isHidden(delay: 1000.0), "a 1000-second wait is Petal's hiding")
        expect(SystemDockRules.isHidden(delay: SystemDockRules.hiddenDelay), "a wait of hiddenDelay is Petal's hiding")
        expect(!SystemDockRules.isHidden(delay: 0.5), "a short wait is the person's own")
        expect(!SystemDockRules.isHidden(delay: nil), "no wait set isn't hidden")
        expect(!SystemDockRules.isHidden(delay: NSNull()), "a wait saved as unset isn't hidden")

        // The person's own settings, saved before hiding: put back as they are.
        let theirs = json(["autohide": true, "autohide-delay": 0.2, "no-bouncing": true, "tilesize": 48.0, "orientation": "left",
                           "autohide-time-modifier": NSNull()])
        let kept = SystemDockRules.own(theirs)
        expect(NSDictionary(dictionary: kept).isEqual(to: theirs), "the person's own settings are kept as saved", "\(kept)")

        // The bug: settings saved after the Dock was already hidden hold Petal's hiding. Putting them back left the
        // Dock hidden for good, and nothing was saved any more for restore-dock or doctor to notice.
        let hiddenSaved = json(["autohide": true, "autohide-delay": 1000.0, "no-bouncing": true, "tilesize": 48.0,
                                "orientation": NSNull(), "autohide-time-modifier": NSNull()])
        let own = SystemDockRules.own(hiddenSaved)
        expect(own["autohide"] as? Bool == false, "Petal's saved auto-hide goes back off", "\(own)")
        expect(own["autohide-delay"] is NSNull, "Petal's saved wait is removed, not put back", "\(own)")
        expect(own["no-bouncing"] is NSNull, "the no-bouncing saved with Petal's hiding is removed", "\(own)")
        expect(own["tilesize"] as? Double == 48.0 && own["orientation"] is NSNull, "the other saved settings stay as saved", "\(own)")
        expect(!SystemDockRules.isHidden(delay: own["autohide-delay"]), "what's put back never hides the Dock")
        let again = SystemDockRules.own(own)
        expect(NSDictionary(dictionary: again).isEqual(to: own), "cleaning settings twice changes nothing more")
        // A file from an older Petal, with the wait as a whole number.
        expect(SystemDockRules.own(json(["autohide": true, "autohide-delay": 1000]))["autohide"] as? Bool == false,
               "a saved whole-number wait is Petal's hiding too")

        // Nothing saved, but the Dock still has Petal's hiding: it's cleared; otherwise it's left alone.
        let clear = SystemDockRules.leftover(delay: 1000.0)
        expect(clear?["autohide"] as? Bool == false && clear?["autohide-delay"] is NSNull,
               "a Dock left hidden with nothing saved gets auto-hide off and its wait removed", "\(String(describing: clear))")
        expect(clear?["tilesize"] == nil && clear?["orientation"] == nil && clear?["no-bouncing"] == nil,
               "clearing a leftover hiding leaves the person's other settings alone")
        expect(SystemDockRules.leftover(delay: 0.2) == nil && SystemDockRules.leftover(delay: nil) == nil,
               "a Dock not hidden by Petal is left alone")

        print("system dock rules: \(passed) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
