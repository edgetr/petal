import AppKit

/// What the Mac's modes may have left behind on the screen, put right once by the first Petal without them
/// (ModesMigration moves the files; this is what needs the running app). Windows that were waiting off-screen for
/// another mode come back to where they were, and a Do Not Disturb Petal turned on while holding notifications, and
/// never got to turn off, goes off. Each leaves its file, so once done there's nothing here to do.
@MainActor
enum ModesLeftovers {
    static func settle() {
        guard !Headless.on else { return }
        bringBackWindows(tries: 6)
        quietOff()
        for key in ["dailySummaryShown", "learnedOn"] { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: Windows put away for another mode

    /// parked.json, as per-mode windows wrote it: each window's own frame from before it was moved aside.
    private struct Parked: Decodable {
        struct Window: Decodable {
            let id: UInt32
            let pid: Int32
            /// Where it goes back to, top-left origin.
            let frame: CGRect
        }
        let parked: [Window]
    }

    private static let parkedFile = Config.supportFolder.appending(path: "parked.json")

    /// Every window parked.json lists goes back to its frame, inside its screen and clear of the dock, and then the
    /// file goes. Without Accessibility nothing can be moved, so the file waits for a launch that has it. A window
    /// whose app doesn't answer yet (still starting at login) is tried again every 5 seconds, `tries` times.
    private static func bringBackWindows(tries: Int) {
        guard FileManager.default.fileExists(atPath: parkedFile.path) else { return }
        guard let data = try? Data(contentsOf: parkedFile), let saved = try? JSONDecoder().decode(Parked.self, from: data) else {
            try? FileManager.default.removeItem(at: parkedFile)   // not a list of windows: nothing to bring back
            return
        }
        guard Windows.trusted else { return }
        bringBack(saved.parked, tries: tries)
    }

    private static func bringBack(_ windows: [Parked.Window], tries: Int) {
        let screens = Windows.screens()
        var waiting: [Parked.Window] = []
        for window in windows where NSRunningApplication(processIdentifier: window.pid) != nil {   // an app that quit took its window along
            guard let element = Windows.element(window.id, pid: window.pid) else { waiting.append(window); continue }
            func overlap(_ area: CGRect) -> CGFloat {
                let cut = window.frame.intersection(area)
                return cut.isNull ? 0 : cut.width * cut.height
            }
            // Its own screen, else (that display gone) the main one.
            guard let home = screens.max(by: { overlap($0.frame) < overlap($1.frame) }).flatMap({ overlap($0.frame) > 0 ? $0 : nil }) ?? screens.first else { continue }
            Windows.place(element, pid: window.pid,
                          ScreenArea.fit(window.frame, in: Windows.usableArea(frame: home.frame, visible: home.visible, respectClear: true)))
        }
        guard !waiting.isEmpty, tries > 1 else {
            try? FileManager.default.removeItem(at: parkedFile)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { bringBack(waiting, tries: tries - 1) }
    }

    // MARK: Do Not Disturb left on

    /// quiet.json was there while Petal had Do Not Disturb on for a mode that held notifications; still there now,
    /// Petal never turned it off (a crash). The Shortcut that turned it on turns it off, and the marker goes.
    private static func quietOff() {
        let marker = Config.folder.appending(path: "quiet.json")
        guard let saved = Config.parse(marker) else {
            try? FileManager.default.removeItem(at: marker)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            if saved["way"] as? String == "shortcut" {
                let input = FileManager.default.temporaryDirectory.appending(path: "petal-quiet-off-\(UUID().uuidString).txt")
                if (try? Data("off".utf8).write(to: input)) != nil {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                    process.arguments = ["run", "Petal Do Not Disturb", "--input-path", input.path]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    process.standardInput = FileHandle.nullDevice
                    if (try? process.run()) != nil { process.waitUntilExit() }
                    try? FileManager.default.removeItem(at: input)
                }
            }
            try? FileManager.default.removeItem(at: marker)
        }
    }
}
