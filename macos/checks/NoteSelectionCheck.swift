import CoreGraphics
import Foundation

// Checks the rule a note's passage follows before Petal AI may stick to it, the one petal_look uses for selected
// text (UIMap.selectionHidden, through Assist.selectionInSecret): nothing from a password field, a field named like a
// password, token, key, card number or security code, a field Petal filled with a secret, or any field whose whole
// text holds a vault secret. Run with macos/checks/run.sh.
@main
struct NoteSelectionCheck {
    static func main() {
        var failures = 0
        func expect(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL \(what)") } }
        let vault = { (text: String) in text.contains("sk-live-123456789") }
        let plain = UINode(role: "AXTextArea", value: "Doors open at 8. Talks start at 9.")
        expect(!UIMap.selectionHidden(in: plain, filled: false, secret: vault), "a plain text's sentence may be a passage")
        expect(UIMap.selectionHidden(in: UINode(role: "AXTextField", subrole: "AXSecureTextField"), filled: false, secret: vault), "never a password field")
        for name in ["Password", "API key", "Access token", "Card number", "Security code"] {
            expect(UIMap.selectionHidden(in: UINode(role: "AXTextField", title: name, value: "abc"), filled: false, secret: vault), "never a field named \(name)")
        }
        expect(UIMap.selectionHidden(in: UINode(role: "AXTextField", value: "anything"), filled: true, secret: vault), "never a field Petal filled with a secret")
        expect(UIMap.selectionHidden(in: UINode(role: "AXTextArea", value: "notes and sk-live-123456789 and more"), filled: false, secret: vault),
               "never a field whose whole text holds a vault secret, whatever part is selected")
        expect(!UIMap.selectionHidden(in: UINode(role: "AXStaticText", title: "Card number", value: "Card number"), filled: false, secret: vault),
               "a label named Card number isn't a field")

        // What the note tools tell an agent: every string redacted with the vault's index, all of it or nothing.
        let index = UIMap.SecretIndex(["sk-live-1234567890abcdef"])
        let answer: [String: Any] = ["text": "config:\nkey = sk-live-1234567890abcdef\nport = 80", "title": "sk-live-1234567890abcdef",
                                     "notes": [["preview": "uses sk-live-1234567890abcdef here", "places": ["The page example.com"]]],
                                     "count": 3, "onScreen": true]
        let shown = NoteShield.shield(answer, index: index) as? [String: Any]
        let text = shown?["text"] as? String ?? ""
        let preview = ((shown?["notes"] as? [Any])?.first as? [String: Any])?["preview"] as? String ?? ""
        expect(!text.contains("sk-live") && text.contains("port = 80") && text.contains(UIMap.hidden), "a note's text: its key hidden, the rest kept")
        expect(shown?["title"] as? String == UIMap.hidden, "a title that is a key: hidden")
        expect(!preview.contains("sk-live") && preview.hasPrefix("uses "), "previews in lists too")
        expect(shown?["count"] as? Int == 3 && shown?["onScreen"] as? Bool == true, "numbers and flags as they were")
        expect(NoteShield.shield(answer, index: .unavailable) == nil, "the vault unreadable: nothing told")
        expect(NoteShield.shield("Couldn't move it.", index: .unavailable) == nil, "not even a plain message")
        print("note selection: " + (failures == 0 ? "all checks passed" : "\(failures) failed"))
        if failures > 0 { exit(1) }
    }
}
