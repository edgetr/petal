import CoreGraphics
import Foundation

// Checks NoteLayout.swift: which sticky notes fit what's in front, telling browser tabs apart, and where a note the
// person moved sits on its window. Run with macos/checks/run.sh.
@main
struct NoteLayoutCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    static func place(_ scope: NoteScope?, pid: Int32 = 10, app: String = "com.apple.Safari", window: UInt32? = 5, tab: NoteTab? = nil) -> NotePlace {
        NotePlace(pid: pid, app: app, appName: "Safari", window: window, title: "", mode: "", desktop: 1, scope: scope, tab: tab)
    }

    static func main() {
        // MARK: Scopes

        let front = FrontPlace(pid: 10, app: "com.apple.Safari", window: 5, tab: nil)
        expect(NoteRules.fits(place(nil), front), "a kept chat with no scope is a window's")
        expect(NoteRules.fits(place(.window), front), "a window's note fits its window")
        expect(!NoteRules.fits(place(.window, window: 6), front), "not another window of its app")
        expect(!NoteRules.fits(place(.window, pid: 11), front), "not another app's window")
        expect(NoteRules.fits(place(.app, window: 6), front), "an app's note fits any of its windows")
        expect(NoteRules.fits(place(.app, pid: 99, window: nil), front), "and after the app restarted")
        expect(!NoteRules.fits(place(.app, app: "com.tinyspeck.slackmacgap"), front), "not another app")
        expect(!NoteRules.fits(place(.app, app: ""), FrontPlace(pid: 1, app: "", window: nil, tab: nil)), "never an app with no id")
        expect(NoteRules.sameWindow(place(.tab, tab: NoteTab(index: 1, url: "a", title: "")), front), "a tab's window is in front, whichever tab")

        // MARK: Windows Petal can't read (Finder opening a window from a stack, a note asked on the desktop)

        let finder = "com.apple.finder"
        let opening = FrontPlace(pid: 10, app: finder, window: nil, tab: nil)
        let finderWindow = FrontPlace(pid: 10, app: finder, window: 7, tab: nil)
        let onDesktop = place(.window, app: finder, window: nil)
        let onWindow = place(.window, app: finder, window: 5)
        expect(!NoteRules.fits(onDesktop, finderWindow), "a note asked with no window never shows on a real window")
        expect(!NoteRules.fitting([onDesktop], finderWindow).contains(0), "nor is it taken there")
        expect(!NoteRules.sameWindow(onDesktop, finderWindow, orUnknown: true), "and it steps away from one")
        expect(!NoteRules.windowUnknown(onDesktop, finderWindow), "a known window isn't unknown")
        expect(!NoteRules.fits(onWindow, opening), "a window not read yet shows no window's note")
        expect(!NoteRules.sameWindow(onWindow, opening), "nor brings one up")
        expect(NoteRules.windowUnknown(onWindow, opening), "but an open note doesn't step away from it")
        expect(NoteRules.sameWindow(onWindow, opening, orUnknown: true), "and stays put on a click there")
        expect(!NoteRules.windowUnknown(onWindow, FrontPlace(pid: 11, app: finder, window: nil, tab: nil)), "another app's unknown window isn't its")
        expect(NoteRules.fits(onDesktop, opening), "no window in front and none kept, same app: it shows")
        expect(!NoteRules.fits(onDesktop, FrontPlace(pid: 11, app: finder, window: nil, tab: nil)), "but not on another process")
        expect(!NoteRules.fits(place(.tab, app: finder, window: nil), finderWindow), "a tab's note that knows no tab is as strict")
        expect(NoteRules.fits(place(.app, app: finder, window: 5), opening), "an app's note fits its app, whatever window")

        // MARK: Chromium tabs (ids)

        let chrome = "com.google.Chrome"
        let a = NoteTab(id: "41", index: 2, count: 3, url: "https://github.com/edgetr/petal", title: "Petal")
        let chromeNote = place(.tab, app: chrome, tab: a)
        func chromeFront(_ tab: NoteTab, pid: Int32 = 10, window: UInt32? = 5) -> FrontPlace {
            FrontPlace(pid: pid, app: chrome, window: window, tab: tab)
        }
        expect(NoteRules.fits(chromeNote, chromeFront(a)), "its tab in front")
        expect(!NoteRules.fits(chromeNote, chromeFront(NoteTab(id: "42", index: 3, count: 3, url: a.url, title: "Petal"))),
               "another tab on the same page has its own note")
        expect(NoteRules.fits(chromeNote, chromeFront(NoteTab(id: "41", index: 2, count: 3, url: "https://github.com/edgetr/petal/pulls", title: "Pulls"))),
               "the tab went to another page: still its note")
        expect(NoteRules.fits(chromeNote, chromeFront(NoteTab(id: "41", index: 1, count: 1, url: a.url, title: ""), window: 9)),
               "a Chromium tab dragged to another window keeps its note")
        expect(!NoteRules.fits(chromeNote, FrontPlace(pid: 10, app: chrome, window: 5, tab: nil)), "no tab read: a tab's note doesn't show")
        expect(NoteRules.fits(chromeNote, chromeFront(NoteTab(id: "3", index: 1, count: 1, twins: 1, url: a.url + "/", title: ""), pid: 77, window: 1)),
               "after the browser restarted, the same address finds it")
        expect(!NoteRules.fits(chromeNote, chromeFront(NoteTab(id: "3", index: 1, count: 3, twins: 2, url: a.url, title: ""), pid: 77, window: 1)),
               "after a restart, of two tabs on its page, not the one in another place")
        expect(NoteRules.fits(chromeNote, chromeFront(NoteTab(id: "4", index: 2, count: 3, twins: 2, url: a.url, title: ""), pid: 77, window: 1)),
               "but the one in its place")
        expect(!NoteRules.fits(chromeNote, chromeFront(NoteTab(id: "41", index: 2, count: 3, url: "https://x.com", title: ""), pid: 77)),
               "after a restart a reused id doesn't")

        // MARK: Safari tabs (place and address)

        let s1 = NoteTab(index: 2, count: 4, url: "https://apple.com/mac", title: "Mac")
        let safariNote = place(.tab, tab: s1)
        func safariFront(_ tab: NoteTab, window: UInt32? = 5) -> FrontPlace { FrontPlace(pid: 10, app: "com.apple.Safari", window: window, tab: tab) }
        expect(NoteRules.fits(safariNote, safariFront(s1)), "its tab in front")
        expect(!NoteRules.fits(safariNote, safariFront(NoteTab(index: 3, count: 4, url: "https://apple.com/iphone", title: ""))), "another tab")
        expect(!NoteRules.fits(safariNote, safariFront(NoteTab(index: 3, count: 4, url: "https://apple.com/", title: ""))),
               "another tab on the same site")
        expect(NoteRules.fits(safariNote, safariFront(NoteTab(index: 1, count: 3, twins: 1, url: s1.url, title: ""))),
               "a tab before it closed: found by its address")

        // Two tabs on the same page are two tabs.
        expect(!NoteRules.fits(safariNote, safariFront(NoteTab(index: 3, count: 4, twins: 2, url: s1.url, title: "Mac"))),
               "a duplicate tab in another place has its own note")
        expect(NoteRules.fits(safariNote, safariFront(NoteTab(index: 2, count: 4, twins: 2, url: s1.url, title: "Mac"))),
               "of two tabs on its page, the one in its place is its tab")
        expect(NoteRules.fits(safariNote, safariFront(NoteTab(index: 2, count: 5, twins: 2, url: s1.url, title: "Mac"))),
               "still in its place after a tab opened after it")
        expect(!NoteRules.fits(safariNote, safariFront(NoteTab(index: 1, count: 3, url: s1.url, title: ""))),
               "the address alone, when Petal can't tell how many tabs have it, isn't enough")
        let gecko = place(.tab, app: "org.mozilla.firefox", tab: NoteTab(url: "https://mozilla.org", title: "Mozilla"))
        expect(NoteRules.fits(gecko, FrontPlace(pid: 10, app: "org.mozilla.firefox", window: 5, tab: NoteTab(url: "https://mozilla.org", title: ""))),
               "a browser that tells no places goes by the address")

        // Fragments count.
        let routed = place(.tab, tab: NoteTab(index: 2, count: 4, twins: 1, url: "https://mail.app/#inbox", title: "Inbox"))
        expect(!NoteRules.fits(routed, safariFront(NoteTab(index: 3, count: 4, twins: 1, url: "https://mail.app/#sent", title: "Sent"))),
               "another tab on another #route of the same app isn't its tab")
        expect(NoteRules.fits(routed, safariFront(NoteTab(index: 2, count: 4, twins: 1, url: "https://mail.app/#sent", title: "Sent"))),
               "its own tab gone to another #route in its place still is")
        expect(!NoteRules.fits(routed, safariFront(NoteTab(index: 2, count: 3, twins: 1, url: "https://mail.app/#sent", title: "Sent"))),
               "but not once the tabs around it changed")
        expect(!NoteRules.fits(safariNote, safariFront(s1, window: 6)), "a Safari tab belongs to its window")
        let navigated = NoteTab(index: 2, count: 4, url: "https://apple.com/mac/compare", title: "Compare")
        expect(NoteRules.fits(safariNote, safariFront(navigated), previous: s1), "went to another page while showing: still its note")
        expect(!NoteRules.fits(safariNote, safariFront(navigated)), "with nothing seen before, a new address is another tab")
        expect(!NoteRules.fits(safariNote, safariFront(NoteTab(index: 2, count: 3, url: "https://apple.com/ipad", title: "")), previous: s1),
               "its tab closed and the next took its place: not its note")
        expect(!NoteRules.fits(safariNote, safariFront(navigated), previous: NoteTab(index: 3, count: 4, url: "https://apple.com/iphone", title: "")),
               "switched from another tab to a new address: not its note")
        let followed = NoteRules.follow(s1, to: navigated, keepWords: true)
        expect(followed.url == navigated.url && followed.title == "Compare" && followed.index == 2, "the note follows its tab's address")
        let quiet = NoteRules.follow(NoteTab(index: 2, count: 4, url: "", title: ""), to: navigated, keepWords: false)
        expect(quiet.url.isEmpty && quiet.title.isEmpty && quiet.index == 2, "a private app's address and title are never kept")
        expect(NoteRules.sameURL("https://a.com/x/", "https://a.com/x"), "a trailing slash doesn't count")
        expect(NoteRules.sameURL("https://a.com/x/#top", "https://a.com/x#top"), "nor before a fragment")
        expect(!NoteRules.sameURL("https://a.com/#/inbox", "https://a.com/#/sent"), "a fragment counts")
        expect(NoteRules.sameURL("https://a.com/x#", "https://a.com/x"), "an empty fragment doesn't")
        expect(NoteRules.samePage("https://a.com/x#top", "https://a.com/x/"), "the same page, whatever its fragment")
        expect(NoteRules.follow(s1, to: NoteTab(index: 3, count: 5, twins: 2, url: s1.url, title: "Mac"), keepWords: true).twins == 2,
               "the note follows how many tabs share its address")
        expect(!NoteRules.sameURL("", ""), "no address is never the same address")

        // MARK: Telling notes apart (one tab, one note)

        // Two Safari tabs on one page, each with a note; the second closes: the one left has the address alone.
        let twinA = place(.tab, tab: NoteTab(index: 1, count: 2, twins: 2, url: s1.url, title: "Mac"))
        let twinB = place(.tab, tab: NoteTab(index: 2, count: 2, twins: 2, url: s1.url, title: "Mac"))
        let survivor = safariFront(NoteTab(index: 1, count: 1, twins: 1, url: s1.url, title: "Mac"))
        expect(NoteRules.fits(twinA, survivor) && NoteRules.fits(twinB, survivor), "both fit the tab left by its address alone")
        expect(NoteRules.fitting([twinA, twinB], survivor).isEmpty, "so neither is taken: no note moves onto the other's tab")
        // The first closes: the second moves to its place; still nothing to tell them apart.
        expect(NoteRules.fitting([twinA, twinB], survivor).isEmpty, "nor when the first closed and the second took its place")
        // The second went to another page instead: the first is still in its place among as many tabs.
        let stayed = safariFront(NoteTab(index: 1, count: 2, twins: 1, url: s1.url, title: "Mac"))
        expect(NoteRules.fitting([twinA, twinB], stayed) == [0], "the one in its place among as many tabs is taken")
        expect(NoteRules.fitting([twinA], survivor) == [0], "one note alone follows its tab by the address, as before")
        // Same-address tabs restored in two windows after the browser restarted.
        let wA = place(.tab, pid: 10, window: 5, tab: NoteTab(index: 1, count: 1, twins: 1, url: s1.url, title: ""))
        let wB = place(.tab, pid: 10, window: 6, tab: NoteTab(index: 1, count: 1, twins: 1, url: s1.url, title: ""))
        let restored = FrontPlace(pid: 99, app: "com.apple.Safari", window: 40, tab: NoteTab(index: 1, count: 1, twins: 1, url: s1.url, title: ""))
        expect(NoteRules.fitting([wA, wB], restored).isEmpty, "two restored windows alike: neither note is taken")
        // A Chromium tab's id is certain, whatever else fits by the address.
        let byID = place(.tab, app: chrome, tab: NoteTab(id: "7", index: 1, count: 1, twins: 1, url: a.url, title: ""))
        let byURL = place(.tab, pid: 3, app: chrome, tab: NoteTab(id: "70", index: 1, count: 1, twins: 1, url: a.url, title: ""))
        let chromeNow = chromeFront(NoteTab(id: "7", index: 1, count: 1, twins: 1, url: a.url, title: ""))
        expect(NoteRules.fitting([byID, byURL], chromeNow) == [0], "a Chromium tab's own id wins; a guess by address isn't taken")
        expect(NoteRules.fitting([place(.window), place(.app), twinA, twinB], survivor) == [0, 1],
               "window and app notes are never held back by tabs alike")

        // MARK: Notes here and chats kept from before, together

        let chatA = UUID(), chatB = UUID()
        let liveA = NoteCandidate(place: twinA, chat: chatA, live: true)
        let keptB = NoteCandidate(place: twinB, chat: chatB, live: false)
        // Live A and kept B were twins on one page; B's twin closed: only A's place is left with the address.
        expect(NoteRules.fitting([liveA, keptB], survivor).isEmpty,
               "a note here isn't moved onto a tab a kept chat fits as well (union, not the live notes alone)")
        expect(NoteRules.fitting([liveA], survivor) == [0], "with no kept chat alike, the note here follows its tab")
        // The same chat as a note here and its kept copy (picked from the list after a restart): one candidate.
        let keptA = NoteCandidate(place: twinA, chat: chatA, live: false)
        expect(NoteRules.unique([keptA, liveA]) == [1], "a kept copy of a chat a note here holds is that note")
        expect(NoteRules.fitting([liveA, keptA], survivor) == [0], "so the chat's two copies never make its tab unsure")
        expect(NoteRules.fitting([keptA, liveA], survivor) == [1], "whichever order they're gathered in")
        expect(NoteRules.unique([keptA, keptA, NoteCandidate(place: twinB, chat: nil, live: true)]) == [0, 2],
               "two kept copies of one chat are one; a note with no chat is its own")
        let keptAlone = NoteCandidate(place: twinA, chat: chatA, live: false)
        expect(NoteRules.fitting([keptAlone, NoteCandidate(place: place(.window), chat: chatB, live: true)], survivor) == [0, 1],
               "a kept chat and a window's note both fit")

        // MARK: Showing a Safari tab (by address and place)

        let urls = ["https://a.com", "https://apple.com/mac", "https://b.com", "https://apple.com/mac/"]
        expect(NoteRules.choose(NoteTab(index: 4, count: 4, twins: 2, url: s1.url, title: ""), urls: urls) == .at(4),
               "of two tabs with its address, the one in its place")
        expect(NoteRules.choose(NoteTab(index: 2, count: 4, twins: 2, url: s1.url, title: ""), urls: urls) == .at(2), "the first, when it's that one")
        expect(NoteRules.choose(NoteTab(index: 3, count: 4, twins: 2, url: s1.url, title: ""), urls: urls) == .unsure,
               "its place no longer has its address: no guess between the two")
        expect(NoteRules.choose(NoteTab(index: 9, count: 9, twins: 1, url: "https://b.com", title: ""), urls: urls) == .at(3),
               "the only tab with its address, wherever it is now")
        expect(NoteRules.choose(NoteTab(index: 3, count: 4, url: "https://gone.com", title: ""), urls: urls) == .unsure,
               "its address nowhere, another in its place among as many tabs: gone elsewhere, or closed and another opened: no guess")
        expect(NoteRules.choose(NoteTab(index: 3, count: 4, url: "https://b.com/#top", title: ""), urls: ["https://a.com", "https://x.com", "https://b.com/#end", "https://y.com"]) == .at(3),
               "only its #fragment changed, in its place among as many tabs: its tab")
        expect(NoteRules.choose(NoteTab(index: 2, count: 3, url: "https://closed.com", title: ""), urls: ["https://a.com", "https://new.com", "https://c.com"]) == .unsure,
               "its tab closed and a new one opened, as many tabs again: never the new one by its place")
        expect(NoteRules.choose(NoteTab(index: 3, count: 5, url: "https://gone.com", title: ""), urls: urls) == .missing,
               "its address nowhere and the tabs around it changed: its tab closed")
        expect(NoteRules.choose(NoteTab(index: 3, count: 5, url: "", title: ""), urls: urls) == .unsure, "no address kept: never called closed")
        expect(NoteRules.choose(s1, urls: []) == .unsure, "no tabs read: unsure")

        // MARK: Private apps

        var said = place(.tab, tab: NoteTab(index: 2, count: 4, twins: 1, url: s1.url, title: "Mac"))
        said.title = "Mac - Apple"
        let clean = said.scrubbed
        expect(clean.title.isEmpty && clean.tab?.url == "" && clean.tab?.title == "", "a private app's titles and address go")
        expect(clean.tab?.index == 2 && clean.tab?.count == 4 && clean.scope == .tab && clean.window == 5, "its tab's place stays")
        expect(NoteRules.sameFrame(CGRect(x: 0, y: 0, width: 800, height: 600), CGRect(x: 1, y: -2, width: 801, height: 598)) &&
               !NoteRules.sameFrame(CGRect(x: 0, y: 0, width: 800, height: 600), CGRect(x: 0, y: 0, width: 700, height: 600)),
               "frames alike within 2 points")

        // MARK: Which note shows

        struct N { let scope: NoteScope; let showing: Bool; let name: String }
        let pick = { (notes: [N]) in NoteRules.pick(notes, scope: \.scope, showing: \.showing)?.name }
        expect(pick([N(scope: .app, showing: false, name: "app"), N(scope: .window, showing: false, name: "window"),
                     N(scope: .tab, showing: false, name: "tab")]) == "tab", "a tab's note beats its window's and its app's")
        expect(pick([N(scope: .app, showing: true, name: "app"), N(scope: .window, showing: false, name: "window")]) == "window",
               "a window's note beats its app's, even the one showing")
        expect(pick([N(scope: .window, showing: false, name: "first"), N(scope: .window, showing: true, name: "showing")]) == "showing",
               "between equals, the one showing stays")
        expect(pick([]) == nil, "nothing fits, nothing shows")
        // Notes here first, then chats kept from before: ranked together.
        expect(pick([N(scope: .window, showing: true, name: "live window"), N(scope: .tab, showing: false, name: "kept tab")]) == "kept tab",
               "a tab's kept chat beats a window's note here, even the one showing")
        expect(pick([N(scope: .tab, showing: false, name: "live tab"), N(scope: .tab, showing: false, name: "kept tab")]) == "live tab",
               "between equals, the note here beats a kept chat")

        // MARK: Keys

        expect(NoteRules.key(place(nil)) == "10-5", "a window's key is the one kept chats had")
        expect(NoteRules.key(place(.app)) == "app|com.apple.Safari", "an app's key is its app")
        expect(NoteRules.key(chromeNote) == "tab|10|41", "a Chromium tab's key is its id")

        // MARK: Where it sits

        let window = CGRect(x: 100, y: 100, width: 800, height: 600)   // y up: top at 700
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 544, height: 300)
        let topRight = NoteSpot.stick(panel: CGRect(x: 340, y: 380, width: 544, height: 300), window: window)
        expect(topRight.corner == .topRight, "nearest corner", "\(topRight)")
        expect(topRight.frame(size: size, window: window, screen: screen) == CGRect(x: 340, y: 380, width: 544, height: 300),
               "stuck where it was left", "\(topRight.frame(size: size, window: window, screen: screen))")
        let moved = window.offsetBy(dx: 200, dy: -50)
        expect(topRight.frame(size: size, window: moved, screen: screen).origin == CGPoint(x: 540, y: 330), "moves with its window")
        let wider = CGRect(x: 100, y: 100, width: 900, height: 500)   // grown right, shrunk from the top
        expect(topRight.frame(size: size, window: wider, screen: screen).origin == CGPoint(x: 440, y: 280),
               "keeps its spot from its corner when the window resizes")
        let taller = CGSize(width: 544, height: 400)
        expect(topRight.frame(size: taller, window: window, screen: screen).maxY == 680, "stuck by a top corner, it grows down")
        let bottomLeft = NoteSpot.stick(panel: CGRect(x: 120, y: 110, width: 544, height: 200), window: window)
        expect(bottomLeft.corner == .bottomLeft && bottomLeft.dx == 20 && bottomLeft.dy == 10, "bottom left", "\(bottomLeft)")
        expect(bottomLeft.frame(size: CGSize(width: 544, height: 260), window: window, screen: screen).minY == 110, "stuck by a bottom corner, it grows up")
        let off = window.offsetBy(dx: 1000, dy: 400)
        let kept = topRight.frame(size: size, window: off, screen: screen)
        expect(screen.contains(kept), "kept whole on the window's screen", "\(kept)")
        let huge = topRight.frame(size: CGSize(width: 544, height: 1200), window: window, screen: screen)
        expect(huge.maxY == screen.maxY, "taller than the screen: its top stays on it", "\(huge)")
        let outside = NoteSpot.stick(panel: CGRect(x: 950, y: 500, width: 300, height: 200), window: window)
        expect(outside.corner == .topRight && outside.dx > 0, "left beside its window, it stays beside it", "\(outside)")

        // MARK: Coordinates and screens

        expect(NoteRules.appKitFrame(CGRect(x: 10, y: 25, width: 100, height: 50), primaryHeight: 900) == CGRect(x: 10, y: 825, width: 100, height: 50),
               "Accessibility's frame in AppKit's coordinates")
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        expect(NoteRules.screen(for: CGRect(x: -500, y: 100, width: 800, height: 600), in: [screen, left]) == left, "the screen it covers most")
        expect(NoteRules.screen(for: CGRect(x: 5000, y: 5000, width: 10, height: 10), in: [screen, left]) == screen, "on none: the first")

        print(failures == 0 ? "ok: \(passed) checks" : "\(failures) of \(passed + failures) checks failed")
        exit(failures == 0 ? 0 : 1)
    }
}
