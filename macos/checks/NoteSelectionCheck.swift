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
        func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") { if !ok { failures += 1; print("FAIL \(what) \(detail())") } }
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

        // Search and lookup only see what the agent may see: prefixes of a saved card number or PIN find nothing.
        let card = "4111111111111111", pin = "4821"
        let vaultIndex = UIMap.SecretIndex([card, pin])
        let matches = { (query: String, text: String) in query.isEmpty || text.localizedCaseInsensitiveContains(query) }
        let notes = ["Travel\ncard \(card) for the hotel", "Door\ncode \(pin) at the gate", "Groceries\nmilk, bread"]
        var probed: Set<Int> = []
        for length in 1...card.count { probed.formUnion(NoteShield.search(String(card.prefix(length)), in: notes, index: vaultIndex, matches: matches) ?? [0]) }
        expect(!probed.contains(0), "no prefix of a saved card number finds its note")
        expect(NoteShield.search(pin, in: notes, index: vaultIndex, matches: matches) == [], "a saved PIN finds nothing")
        expect(NoteShield.search("482", in: notes, index: vaultIndex, matches: matches) == [], "nor part of it")
        expect(NoteShield.search("hotel", in: notes, index: vaultIndex, matches: matches) == [0], "words around it still find the note")
        expect(NoteShield.search("", in: notes, index: vaultIndex, matches: matches) == [0, 1, 2], "an empty search lists them all")
        expect(NoteShield.search("milk", in: notes, index: .unavailable, matches: matches) == nil, "the vault unreadable: no results at all")
        let rows = [(handle: "n1a2b3c4d5e6f", body: "# Card \(card)", version: false), (handle: "n9f8e7d6c5b4a", body: "# Door", version: false)]
        expect(NoteShield.find("Card \(card)", rows: rows, index: vaultIndex) == .none && NoteShield.find("/n/Card \(card).md", rows: rows, index: vaultIndex) == .none,
               "naming a guessed secret in a title, or a file, finds nothing")
        expect(NoteShield.find("Card (hidden)", rows: rows, index: vaultIndex) == .found(0) && NoteShield.find("n9f8e7d6c5b4a", rows: rows, index: vaultIndex) == .found(1),
               "a note found by what petal_notes showed of it: its title, or its handle")
        expect(NoteShield.find("n9f8e7d6c5b4a", rows: rows, index: .unavailable) == .unreadable, "the vault unreadable: nothing looked up")

        // Redacted whole before anything is cut: a secret straddling a cut leaves nothing of itself.
        let straddle = "# Door\n" + String(repeating: "a", count: 157) + " \(pin) more words after it"
        expect(String(NoteText.preview(straddle).prefix(160)).hasSuffix(" 48"), "the case is real: a raw cut leaves part of the PIN")
        let told = NoteShield.shield(["preview": NoteShield.Derived { NoteTold.preview(straddle, $0) },
                                      "title": NoteShield.Derived { NoteTold.title(String(repeating: "b", count: 76) + " \(card) end", $0) }],
                                     index: vaultIndex) as? [String: Any]
        let toldPreview = told?["preview"] as? String ?? "?", toldTitle = told?["title"] as? String ?? "?"
        expect(!toldPreview.contains("48") && !toldPreview.isEmpty, "a PIN across the preview's cut: none of it told", toldPreview)
        expect(!toldTitle.contains("411") && !toldTitle.isEmpty, "a card number across the title's cut: none of it told", toldTitle)
        var passage = NoteStick(kind: .passage)
        passage.quote = String(repeating: "c", count: 57) + " \(card)"
        passage.url = "https://example.com/\(card)"
        let place = passage.redacted { vaultIndex.redacted($0) }.words
        expect(!place.contains("41") && place.contains("example.com"), "a passage's quote and address cut only after redaction", place)

        // A tool's answer holds no file name, path or pictures' folder: a handle, words derived after redaction, and
        // pictures as `![picture N]`.
        let assets = NoteShelf.assetsFolder(id: "file:Inbox/Card 41111.md")
        expect(!assets.contains("Card") && !assets.contains("Inbox") && !assets.contains("41") && assets.hasPrefix("pictures-"),
               "a pictures' folder name copies nothing of the id or the file's name", assets)
        let body = "# Trip\nTickets for Friday\n![boarding pass](\(assets)/picture-1a2b.png)\nGate 12\n![](\(assets)/picture-3c4d.png)"
        var filePlace = NoteStick(kind: .file)
        filePlace.path = "/Users/someone/Documents/Itinerary.pdf"
        let toolAnswer = NoteShield.shield(NoteShield.note(handle: "n1a2b3c4d5e6f", body: body, notebook: "Travel", places: [filePlace],
                                                       modified: "2026-11-09T10:00:00Z", onScreen: false, text: true), index: vaultIndex)
        let json = (try? JSONSerialization.data(withJSONObject: toolAnswer ?? [:], options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        expect(!json.isEmpty && !json.contains("pictures-") && !json.contains(".assets") && !json.contains(".png") && !json.contains(".md")
               && !json.contains("/Users/someone/Documents"), "no path, file name or pictures' folder in the answer", json)
        expect(json.contains("![picture 1]") && json.contains("![picture 2]") && json.contains("Gate 12") && json.contains("n1a2b3c4d5e6f"),
               "its words, its pictures by number, its handle", json)
        let back = NoteTold.restorePictures("Tickets\n![picture 2]\nnew line\n![picture 1]\n![picture 7]", from: body)
        expect(back == "Tickets\n![](\(assets)/picture-3c4d.png)\nnew line\n![boarding pass](\(assets)/picture-1a2b.png)\n![picture 7]",
               "an agent's `![picture N]` written back is that picture again; one there isn't stays words", back)

        // A title names a note only when exactly one has it, as the tools tell titles: never a guess.
        let alike = [(handle: "naaa", body: "# Shopping\nmilk", version: false), (handle: "nbbb", body: "# Shopping\nbread", version: false),
                     (handle: "nccc", body: "# PIN \(pin)", version: false), (handle: "nddd", body: "# PIN (hidden)", version: false)]
        expect(NoteShield.find("Shopping", rows: alike, index: vaultIndex) == .ambiguous([0, 1]), "two notes titled Shopping: ambiguous, with both")
        expect(NoteShield.find("PIN (hidden)", rows: alike, index: vaultIndex) == .ambiguous([2, 3]), "titles redaction made alike: ambiguous too")
        expect(NoteShield.find("nbbb", rows: alike, index: vaultIndex) == .found(1), "a handle still names one")
        expect(NoteShield.find("naaa.f00d", rows: [(handle: "naaa", body: "# A", version: false)], index: vaultIndex) == .found(0),
               "a copy's handle after its conflict was settled names the note's one paper")

        // A handle the redaction changed (an older one holding a card's digits) is still accepted as shown, when it names one.
        let digitHandles = [(handle: "n41111111xyz", body: "# One", version: false), (handle: "nqrstuvwxyzab", body: "# Two", version: false)]
        let shownHandle = vaultIndex.redacted("n41111111xyz")
        expect(shownHandle != "n41111111xyz" && NoteShield.find(shownHandle, rows: digitHandles, index: vaultIndex) == .found(0),
               "a handle told as \(shownHandle) still names its note")

        // A specific conflict copy, named by its own handle: that copy, never the first paper of its id.
        let copies = [(handle: "nabc.1f2e", body: "# A\nmine", version: false), (handle: "nabc.9d8c", body: "# A\ntheirs", version: false)]
        expect(NoteShield.find("nabc.9d8c", rows: copies, index: vaultIndex) == .found(1), "the copy named is the copy found")
        print("note selection: " + (failures == 0 ? "all checks passed" : "\(failures) failed"))
        if failures > 0 { exit(1) }
    }
}
