import AppKit

/// Selected text from any app, through macOS's Services (the right-click menu, under Services when there are many):
/// "Ask Petal AI" opens the chat with the text quoted, ready for a question about it, the way T3 Code cites a
/// passage; "Add to Petal AI" quotes it in the chat without opening it, for gathering a few passages first.
@MainActor
final class TextServices: NSObject {
    @objc func askPetal(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        take(pasteboard, open: true)
    }

    @objc func addToPetal(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        take(pasteboard, open: false)
    }

    private func take(_ pasteboard: NSPasteboard, open: Bool) {
        // Never a secret: what a password manager marks as one, or anything from an app kept private.
        guard !Assist.isConcealed(pasteboard), !PetalApp.shared.assist.neverLook(NSWorkspace.shared.frontmostApplication?.bundleIdentifier),
              let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        let source = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        // Nor one of the vault's secrets: the text is quoted as Petal AI may be told it (each secret as "(hidden)", or
        // a line saying the vault can't be read now), checked off the main thread (the Keychain may take a while).
        // Text too long to search is never quoted; Ask Petal AI still opens the chat.
        DispatchQueue.global(qos: .userInitiated).async {
            let shown = Assist.shownText(text, limit: .max)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let app = PetalApp.shared
                    if let shown { app.claude.quote(shown, from: source) }
                    if open { app.claude.open(asking: nil) } else if shown != nil { app.claude.noteAdded() }
                }
            }
        }
    }
}
