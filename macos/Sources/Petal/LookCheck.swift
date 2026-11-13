import AppKit
import ApplicationServices

/// `Petal --look-check <bundle id> [--find <word>] [--part <n>]`: what petal_look with `text` would answer for that
/// app's front window (its focused one), through the same reading and redaction, with a made-up empty vault (the
/// Keychain is never read); for a browser, also which of its scripted windows that window matched and the tab it
/// shows. It only reads: it never activates, clicks, types or opens anything, and asks a browser only what it was
/// already allowed to be asked. Run by a person against their own apps, from a copy of Petal Accessibility trusts.
enum LookCheck {
    static func run(bundle: String, arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        Headless.on = true
        VaultStore.standIn([])
        func value(after flag: String) -> String? {
            guard let at = arguments.firstIndex(of: flag), arguments.indices.contains(at + 1) else { return nil }
            return arguments[at + 1]
        }
        let find = value(after: "--find") ?? ""
        let part = value(after: "--part").flatMap(Int.init) ?? 1
        guard Windows.trusted else {
            print("FAIL this copy of Petal isn't allowed Accessibility (System Settings › Privacy & Security › Accessibility)")
            exit(1)
        }
        guard let app = NSRunningApplication.persons(withBundleIdentifier: bundle).first else {
            print("FAIL \(bundle) isn't running")
            exit(1)
        }
        let pid = app.processIdentifier
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        let window: AXUIElement? = Windows.value(element, kAXFocusedWindowAttribute) ?? Windows.value(element, kAXMainWindowAttribute)
        let number = window.flatMap { Windows.id(of: $0) }
        let title: String = window.flatMap { Windows.value($0, kAXTitleAttribute) } ?? ""
        let frame = window.flatMap { Windows.frame(of: $0) } ?? .zero
        print("app \(app.localizedName ?? bundle) (pid \(pid))")
        print("window \(number.map(String.init) ?? "none") “\(title)” at \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height))")

        if let kind = Browsers.kind(bundle) {
            print("browser: \(kind), allowed to ask: \(Browsers.access(bundle) == .allowed ? "yes" : "no")")
            if kind != .gecko, let rows = Browsers.windowRows(bundle) {
                for (index, row) in rows.enumerated() {
                    let f = row.window.frame
                    print("  row \(index): id \(row.window.id) name “\(row.window.name)” tab “\(row.window.tabTitle)” at \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height))")
                }
                let browserWindow = Browsers.Window(number: number, title: title, frame: frame)
                if let matched = Browsers.row(in: rows, for: browserWindow, byNumber: kind == .safari) {
                    print("matched row: id \(matched.window.id) “\(matched.window.name)”")
                } else {
                    print("matched row: none")
                }
            }
            if let number {
                let tab = Browsers.shownTab(pid: pid, bundleID: bundle, window: Browsers.Window(number: number, title: title, frame: frame), element: window)
                print("tab it shows: " + (tab.map { "id \($0.id ?? "-") button \($0.element.map(String.init) ?? "-") index \($0.index.map(String.init) ?? "-") “\($0.title)” \($0.url)" } ?? "can't tell"))
            }
            let active = Browsers.activeTab(pid: pid, bundleID: bundle)
            print("front window's active tab: " + (active.map { "id \($0.id ?? "-") “\($0.title)”" } ?? "can't tell"))
        }

        let started = Date()
        let told = Assist.words(pid: pid, window: number, find: find, part: part)
        print(String(format: "read in %.2f s", Date().timeIntervalSince(started)))
        for key in told.keys.sorted() where key != "text" { print("\(key): \(told[key] ?? "")") }
        if let text = told["text"] as? String {
            print("text (\(text.count) characters):")
            print(text)
        }
        exit(0)
    }
}
