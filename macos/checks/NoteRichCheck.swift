import AppKit

// Checks NoteEditor.swift's text for a note: every kind of line (headings, checkboxes, a link's card, a picture,
// Petal's ink, inline links, list items, empty lines) goes into the editor and comes back as the same Markdown.
// AppKit only: stand-ins below for the parts of Petal it would reach (nothing is fetched or read). Run with
// macos/checks/run.sh.
enum Headless { nonisolated(unsafe) static var on = true }
final class NoteStore { nonisolated static let io = DispatchQueue(label: "petal.check.notes") }
@MainActor final class Sites { static let shared = Sites(); func icon(_ id: String) -> NSImage? { nil } }
struct PaperNote { var file: NoteFile; var url: URL; var key: String { url.path } }

@main
struct NoteRichCheck {
    @MainActor static func main() {
        var failures = 0
        let style = NoteRich.Style(ink: .black, dim: .gray, petal: .blue, accent: .blue)
        let bodies = [
            "# Title\n\nwords with [a link](https://a.b/c) and https://x.y/z\n- [ ] todo\n- [x] done\nhttps://example.com/page\n![cap](<a b.assets/p.png>)\n> ink line\n>\n## Sub\n- bullet\n",
            "",
            "one line",
            "### Small\n> answer\n> more\n\nafter",
        ]
        for body in bodies {
            let editor = NoteRich.attributed(NoteBlock.blocks(body), base: URL(fileURLWithPath: "/tmp"), style: style)
            let back = NoteBlock.body(NoteRich.blocks(editor))
            if back != body && !(body.isEmpty && back.isEmpty) {
                failures += 1
                print("FAIL the editor changed a note:\n---\n\(body)\n---\n\(back)\n---")
            }
        }
        print("note editor: \(bodies.count - failures) of \(bodies.count) round trips")
        if failures > 0 { exit(1) }
    }
}
