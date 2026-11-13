import AppKit

/// `Petal --bench-dock`'s drop step: what a drag over the dock holds is weighed from its URLs alone, never from the
/// disk on the main thread (`DockDrops`). One line, "ok" or "FAIL"; the number of failures is returned.
@MainActor
enum DockDropsCheck {
    static func run() -> Int {
        var problems: [String] = []
        // Said by the URL alone: these paths don't exist, so a read of the disk would say otherwise.
        let missing = "/petal-check-\(getpid())/nowhere"
        let said = DockDrops.items([URL(fileURLWithPath: missing + "/Folder", isDirectory: true),
                                    URL(fileURLWithPath: missing + "/Slack.app", isDirectory: true),
                                    URL(fileURLWithPath: missing + "/Notes.pdf", isDirectory: false),
                                    URL(string: "https://example.com/page")!])
        let expected: [DockRules.Dropped] = [.folder(missing + "/Folder"), .app(missing + "/Slack.app"), .document(missing + "/Notes.pdf"),
                                             .site("https://example.com/page")]
        if said != expected { problems.append("weighed \(said)") }
        // A real folder whose URL doesn't say it's one: a document at first, a folder once it was looked at off the
        // main thread.
        let folder = SettingsBench.scratch.appending(path: "dropped-folder")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bare = URL(fileURLWithPath: folder.path, isDirectory: false)
        let first = DockDrops.items([bare])
        let deadline = Date().addingTimeInterval(5)
        var later = first
        while Date() < deadline, later == first {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            later = DockDrops.items([bare])
        }
        if first != [.document(folder.path)] { problems.append("first \(first)") }
        if later != [.folder(folder.path)] { problems.append("later \(later)") }
        // Weighing a drag of 200 items takes no time worth noticing.
        let many = (0..<200).map { URL(fileURLWithPath: missing + "/\($0)/", isDirectory: true) }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<10 { _ = DockDrops.items(many) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 / 10
        print(String(format: "drops: %@ weighed from their URLs (200 items in %.2f ms)%@", problems.isEmpty ? "ok  " : "FAIL", ms,
                     problems.isEmpty ? "" : "; " + problems.joined(separator: ", ")))
        return problems.isEmpty ? 0 : 1
    }
}
