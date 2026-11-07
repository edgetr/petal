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

    static let s1Tab = NoteTab(element: 1, index: 2, count: 4, shared: 1, url: "https://apple.com/mac", title: "Mac")

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
        expect(NoteRules.sameWindow(place(.tab, tab: NoteTab(element: 1, index: 1, url: "a", title: "")), front), "a tab's window is in front, whichever tab")

        // MARK: Windows Petal can't read (Finder opening a window from a stack, a note asked on the desktop)

        let finder = "com.apple.finder"
        let opening = FrontPlace(pid: 10, app: finder, window: nil, tab: nil)
        let desktop = FrontPlace(pid: 10, app: finder, window: nil, tab: nil, none: true)
        let finderWindow = FrontPlace(pid: 10, app: finder, window: 7, tab: nil)
        let onDesktop = place(.window, app: finder, window: nil)
        let onWindow = place(.window, app: finder, window: 5)
        expect(!NoteRules.fits(onDesktop, finderWindow), "a note asked with no window never shows on a real window")
        expect(!NoteRules.fitting([onDesktop], finderWindow).contains(0), "nor is it taken there")
        expect(!NoteRules.sameWindow(onDesktop, finderWindow, orUnknown: true), "and it steps away from one")
        expect(!NoteRules.windowUnknown(onDesktop, finderWindow), "a known window isn't unknown")
        expect(NoteRules.fits(onDesktop, desktop), "no window in front, as Finder said, and none kept: it shows")
        expect(!NoteRules.fits(onDesktop, opening), "a window Petal couldn't read isn't no window: a desktop note doesn't show there")
        expect(!NoteRules.fitting([onDesktop], opening).contains(0), "nor is it taken there")
        expect(!NoteRules.sameWindow(onDesktop, opening), "nor brought up there")
        expect(NoteRules.windowUnknown(onDesktop, opening), "it's kept to come back once Finder says which window")
        expect(!NoteRules.windowUnknown(onDesktop, desktop), "no window, said so, isn't unknown")
        expect(!NoteRules.fits(onWindow, opening), "a window not read yet shows no window's note")
        expect(!NoteRules.fits(onWindow, desktop), "nor does no window")
        expect(!NoteRules.sameWindow(onWindow, opening), "nor brings one up")
        expect(NoteRules.windowUnknown(onWindow, opening), "but it's kept to come back once its window is known")
        expect(NoteRules.sameWindow(onWindow, opening, orUnknown: true), "and stays put on a click there")
        expect(!NoteRules.sameWindow(onWindow, desktop, orUnknown: true), "but not on the desktop: that's no window of its")
        expect(!NoteRules.windowUnknown(onWindow, FrontPlace(pid: 11, app: finder, window: nil, tab: nil)), "another app's unknown window isn't its")
        expect(!NoteRules.fits(onDesktop, FrontPlace(pid: 11, app: finder, window: nil, tab: nil, none: true)), "nor another process's desktop")
        expect(!NoteRules.fits(place(.tab, app: finder, window: nil), finderWindow), "a tab's note that knows no tab is as strict")
        expect(NoteRules.fits(place(.app, app: finder, window: 5), opening), "an app's note fits its app, whatever window")
        expect(FrontPlace(pid: 1, app: "", window: 3, tab: nil, none: true).unread == false && opening.unread && !desktop.unread,
               "unread only when no window and not said so")

        // What a note's AI reads and uses: never a window its app shows after the note was asked with none.
        expect(onDesktop.target == .nothing, "a window's note asked with no window targets nothing")
        expect(onWindow.target == .window(5), "a window's note targets its window")
        expect(place(.app, app: finder, window: nil).target == .focused && place(.app, app: finder, window: 5).target == .focused,
               "only an app's note follows its app's focused window")
        expect(place(.tab, window: nil, tab: NoteTab(id: "1", url: "a", title: "")).target == .focused,
               "a tab's note whose window isn't known: whichever window shows its tab (checked before and after)")
        expect(place(.tab, window: nil).target == .nothing, "a tab's note that knows no tab and no window: nothing")

        // An open note steps away the moment another app comes forward, before its window is read.
        let otherApp = FrontPlace(pid: 20, app: "com.apple.Notes", window: nil, tab: nil)
        expect(!NoteRules.sameWindow(onWindow, otherApp, orUnknown: true) && !NoteRules.sameWindow(onDesktop, otherApp, orUnknown: true),
               "another app in front, window not read yet: a window's note isn't there")
        expect(NoteRules.sameWindow(onWindow, opening, orUnknown: true), "its own app, window not read yet: it waits for the read")
        expect(!NoteRules.sameWindow(place(.tab, tab: s1Tab), FrontPlace(pid: 20, app: "com.apple.Safari", window: nil, tab: nil), orUnknown: true),
               "another Safari process: not a tab note's")
        expect(NoteRules.sameWindow(place(.app, app: "com.apple.Notes", window: 3), otherApp, orUnknown: true),
               "an app's note stays with its app, whatever process")

        // MARK: Chromium tabs (ids)

        let chrome = "com.google.Chrome"
        let a = NoteTab(id: "41", index: 2, count: 3, shared: 1, url: "https://github.com/edgetr/petal", title: "Petal")
        let chromeNote = place(.tab, app: chrome, tab: a)
        func chromeFront(_ tab: NoteTab, pid: Int32 = 10, window: UInt32? = 5) -> FrontPlace {
            FrontPlace(pid: pid, app: chrome, window: window, tab: tab)
        }
        expect(NoteRules.fits(chromeNote, chromeFront(a)), "its tab in front")
        expect(!NoteRules.fits(chromeNote, chromeFront(NoteTab(id: "42", index: 3, count: 3, shared: 2, url: a.url, title: "Petal"))),
               "another tab on the same page has its own note")
        expect(NoteRules.fits(chromeNote, chromeFront(NoteTab(id: "41", index: 2, count: 3, url: "https://github.com/edgetr/petal/pulls", title: "Pulls"))),
               "the tab went to another page: still its note")
        expect(NoteRules.fits(chromeNote, chromeFront(NoteTab(id: "41", index: 1, count: 1, url: a.url, title: ""), window: 9)),
               "a Chromium tab dragged to another window keeps its note")
        expect(!NoteRules.fits(chromeNote, FrontPlace(pid: 10, app: chrome, window: 5, tab: nil)), "no tab read: a tab's note doesn't show")
        expect(!NoteRules.fits(chromeNote, chromeFront(NoteTab(index: 2, count: 3, shared: 1, url: a.url, title: ""))),
               "a tab read with no id isn't its tab by the address while the browser runs")

        // Accessibility couldn't read the window, AppleScript still named the active tab: unreadable never matches.
        let tabUnread = chromeFront(a, window: nil)
        expect(tabUnread.unread && !NoteRules.fits(chromeNote, tabUnread), "a tab read with its window unread isn't its tab, even by its id")
        expect(NoteRules.fitting([chromeNote], tabUnread).isEmpty, "nor is it taken there (no note before the plain chat)")
        expect(!NoteRules.fits(chromeNote, FrontPlace(pid: 10, app: chrome, window: nil, tab: a, none: true)), "nor with no window said")
        let onlyOne = NoteTab(id: "3", index: 1, count: 1, shared: 1, url: a.url, title: "")
        expect(NoteRules.fits(chromeNote, chromeFront(onlyOne, pid: 77)) && !NoteRules.fits(chromeNote, chromeFront(onlyOne, pid: 77, window: nil)),
               "nor after a restart by its address")
        expect(NoteRules.windowUnknown(chromeNote, tabUnread), "a tab's note is kept to come back once its window is read")
        expect(!NoteRules.sameWindow(chromeNote, tabUnread) && NoteRules.sameWindow(chromeNote, tabUnread, orUnknown: true),
               "never brought up there; an open one waits for the read")
        let adoptedTab = NoteRules.adopt(chromeNote, tabUnread, title: "", keepWords: true)
        expect(adoptedTab.window == 5, "a window Petal couldn't read never replaces the one a tab's note knows", "\(String(describing: adoptedTab.window))")
        let appNote = place(.app, app: chrome, window: 5)
        expect(NoteRules.fits(appNote, tabUnread), "an app's note still fits its app (the app is known without Accessibility)")
        let adoptedApp = NoteRules.adopt(appNote, tabUnread, title: "", keepWords: true)
        expect(adoptedApp.window == 5, "nor the one an app's note knows")
        expect(NoteRules.adopt(appNote, chromeFront(a, window: 9), title: "Petal", keepWords: true).window == 9,
               "a window read: an app's note follows it")
        expect(NoteRules.adopt(appNote, FrontPlace(pid: 10, app: chrome, window: nil, tab: nil, none: true), title: "", keepWords: true).window == nil,
               "and no window, said so, is none")
        let movedTab = NoteRules.adopt(chromeNote, chromeFront(NoteTab(id: "41", index: 1, count: 1, url: a.url, title: "Petal 2"), window: 9), title: "Petal 2", keepWords: false)
        expect(movedTab.window == 9 && movedTab.tab?.index == 1 && movedTab.title.isEmpty && movedTab.tab?.title == "Petal",
               "a tab's note follows its tab's window and place; a private app's words aren't kept")

        // MARK: After the browser restarted: only an address no other tab of the browser has

        let restartedOnly = NoteTab(id: "3", index: 1, count: 1, shared: 1, url: a.url + "/", title: "")
        expect(NoteRules.fits(chromeNote, chromeFront(restartedOnly, pid: 77, window: 1)),
               "the only tab of the whole browser on its address finds it")
        expect(!NoteRules.fits(chromeNote, chromeFront(NoteTab(id: "4", index: 2, count: 3, shared: 2, url: a.url, title: ""), pid: 77, window: 1)),
               "two tabs on its address anywhere in the browser: neither, whatever their places")
        expect(!NoteRules.fits(chromeNote, chromeFront(NoteTab(id: "4", index: 1, count: 1, url: a.url, title: ""), pid: 77, window: 1)),
               "nor when how many have it isn't known")
        expect(!NoteRules.fits(chromeNote, chromeFront(NoteTab(id: "41", index: 2, count: 3, shared: 1, url: "https://x.com", title: ""), pid: 77)),
               "a reused id after a restart doesn't count")
        // The same address in two windows, the note on one; the browser restarts and both come back. Each window has
        // one tab on it, but the browser has two: no adoption (and no new Chromium id taken by a guess).
        let inTwo = NoteTab(id: "9", index: 1, count: 1, shared: 2, url: a.url, title: "")
        expect(!NoteRules.fits(chromeNote, chromeFront(inTwo, pid: 77, window: 2)), "same address in two windows after a restart: not taken")
        // Its tab had a twin (anywhere in the browser) when the note last saw it: the one left may be the twin.
        let hadTwin = place(.tab, app: chrome, tab: NoteTab(id: "41", index: 1, count: 2, shared: 2, url: a.url, title: ""))
        expect(!NoteRules.fits(hadTwin, chromeFront(restartedOnly, pid: 77, window: 1)),
               "one tab left of two alike is no more certain after a restart")
        expect(!NoteRules.fits(place(.tab, app: chrome, tab: NoteTab(id: "41", url: a.url, title: "")), chromeFront(restartedOnly, pid: 77)),
               "a note that never knew how many tabs had its address isn't found by it")
        expect(!NoteRules.fits(place(.tab, app: chrome, tab: NoteTab(id: "41", index: 1, count: 1, shared: 1, url: a.url, title: "")),
                               chromeFront(NoteTab(element: 3, index: 1, count: 1, shared: 1, url: a.url, title: ""), pid: 77)),
               "only onto a tab with an id of its own")
        expect(chromeNote.tabComesBack, "a Chromium tab's note comes back (by its id, or after a restart its address)")

        // Safari after a restart (Petal's or the browser's): never by its address, however alone it is.
        let safariOnly = NoteTab(element: 900, index: 1, count: 2, shared: 1, url: "https://apple.com/mac", title: "")
        expect(!NoteRules.fits(place(.tab, tab: NoteTab(index: 1, count: 1, shared: 1, url: "https://apple.com/mac", title: "")),
                               FrontPlace(pid: 99, app: "com.apple.Safari", window: 40, tab: safariOnly)),
               "a Safari tab after a restart isn't found by its address, even the browser's only one")
        expect(!NoteRules.fits(place(.tab, tab: NoteTab(element: 900, index: 1, count: 1, shared: 1, url: "https://apple.com/mac", title: "")),
                               FrontPlace(pid: 99, app: "com.apple.Safari", window: 40, tab: safariOnly)),
               "nor by a button number from another run of the browser")

        // MARK: Safari, Firefox and Zen tabs (their button in the tab strip)

        let s1 = NoteTab(element: 1, index: 2, count: 4, shared: 1, url: "https://apple.com/mac", title: "Mac")
        let safariNote = place(.tab, tab: s1)
        func safariFront(_ tab: NoteTab, pid: Int32 = 10, window: UInt32? = 5) -> FrontPlace {
            FrontPlace(pid: pid, app: "com.apple.Safari", window: window, tab: tab)
        }
        expect(NoteRules.fits(safariNote, safariFront(s1)), "its tab in front")
        expect(!NoteRules.fits(safariNote, safariFront(NoteTab(element: 2, index: 3, count: 4, url: "https://apple.com/iphone", title: ""))), "another tab")
        expect(NoteRules.fits(safariNote, safariFront(NoteTab(element: 1, index: 2, count: 4, url: "https://apple.com/mac/compare", title: "Compare"))),
               "its tab went to another page: still its note")
        expect(NoteRules.fits(safariNote, safariFront(NoteTab(element: 1, index: 4, count: 6, url: s1.url, title: ""))),
               "moved in its strip, with tabs opened around it: still its tab")
        expect(NoteRules.fits(safariNote, safariFront(NoteTab(element: 1, index: 1, count: 1, url: "https://apple.com/mac#x", title: ""))),
               "a #fragment changed and other tabs closed: still its tab")
        expect(!NoteRules.fits(safariNote, safariFront(NoteTab(index: 2, count: 4, shared: 1, url: s1.url, title: ""))),
               "a tab whose button couldn't be read isn't its tab by the address while the browser runs")
        // Duplicated: its tab A (a note) duplicated into B, selected; A closed behind it.
        let dupB = NoteTab(element: 2, index: 2, count: 2, shared: 2, url: s1.url, title: "Mac")
        expect(!NoteRules.fits(safariNote, safariFront(dupB)), "a duplicate of its tab is another tab")
        let dupBAlone = NoteTab(element: 2, index: 1, count: 1, shared: 1, url: s1.url, title: "Mac")
        expect(!NoteRules.fits(safariNote, safariFront(dupBAlone)), "and stays another once the original closed (the note doesn't move to it)")
        // Reordered: A and B swapped, B selected in A's old place among as many tabs, before Petal looked.
        let swapped = NoteTab(element: 2, index: 2, count: 4, shared: 1, url: "https://b.com", title: "B")
        expect(!NoteRules.fits(safariNote, safariFront(swapped)), "another tab moved into its place is never taken for it going elsewhere")
        let gecko = place(.tab, app: "org.mozilla.firefox", tab: NoteTab(element: 7, index: 1, count: 2, url: "https://mozilla.org", title: "Mozilla"))
        func geckoFront(_ tab: NoteTab) -> FrontPlace { FrontPlace(pid: 10, app: "org.mozilla.firefox", window: 5, tab: tab) }
        expect(NoteRules.fits(gecko, geckoFront(NoteTab(element: 7, index: 2, count: 2, url: "https://mozilla.org/about", title: ""))),
               "a Firefox tab by its button, wherever it went")
        expect(!NoteRules.fits(gecko, geckoFront(NoteTab(element: 8, index: 1, count: 2, url: "https://mozilla.org", title: "Mozilla"))),
               "not another Firefox tab on the same page")
        expect(!NoteRules.fits(gecko, geckoFront(NoteTab(url: "https://mozilla.org", title: ""))), "nor one read with no strip")

        let followed = NoteRules.follow(s1, to: NoteTab(element: 1, index: 3, count: 5, shared: 2, url: "https://apple.com/mac/compare", title: "Compare"), keepWords: true)
        expect(followed.url == "https://apple.com/mac/compare" && followed.title == "Compare" && followed.index == 3 && followed.shared == 2,
               "the note follows its tab's address, place and how many share it")
        let quiet = NoteRules.follow(NoteTab(element: 1, index: 2, count: 4, url: "", title: ""), to: s1, keepWords: false)
        expect(quiet.url.isEmpty && quiet.title.isEmpty && quiet.index == 2 && quiet.element == 1, "a private app's address and title are never kept")
        expect(!safariNote.tabComesBack && !gecko.tabComesBack, "a Safari or Firefox tab's note doesn't come back once its button is gone")
        expect(NoteRules.sameURL("https://a.com/x/", "https://a.com/x"), "a trailing slash doesn't count")
        expect(NoteRules.sameURL("https://a.com/x/#top", "https://a.com/x#top"), "nor before a fragment")
        expect(!NoteRules.sameURL("https://a.com/#/inbox", "https://a.com/#/sent"), "a fragment counts")
        expect(NoteRules.sameURL("https://a.com/x#", "https://a.com/x"), "an empty fragment doesn't")
        expect(NoteRules.samePage("https://a.com/x#top", "https://a.com/x/"), "the same page, whatever its fragment")
        expect(!NoteRules.sameURL("", ""), "no address is never the same address")

        // How many tabs share an address: counted with the rule matching uses.
        let listed = ["https://a.com/app", "https://a.com/app/", "https://a.com/app#x", "https://b.com", ""]
        expect(NoteRules.shared("https://a.com/app", among: listed) == 2, "/app and /app/ are one address, counted twice",
               "\(String(describing: NoteRules.shared("https://a.com/app", among: listed)))")
        expect(NoteRules.shared("https://a.com/app/", among: listed) == 2, "from either side")
        expect(NoteRules.shared("https://a.com/app#x", among: listed) == 1, "a fragment is another address")
        expect(NoteRules.shared("https://c.com", among: listed) == nil, "not in the listing: unknown, never none")
        expect(NoteRules.shared("", among: listed) == nil && NoteRules.shared("https://a.com/app", among: [""]) == nil,
               "no address, or no listing: unknown")
        let slashNote = place(.tab, pid: 3, app: chrome, tab: NoteTab(id: "1", index: 1, count: 2, shared: NoteRules.shared("https://a.com/app", among: listed),
                                                                         url: "https://a.com/app", title: ""))
        expect(!NoteRules.fits(slashNote, chromeFront(NoteTab(id: "5", index: 2, count: 2, shared: NoteRules.shared("https://a.com/app/", among: listed),
                                                                url: "https://a.com/app/", title: ""))),
               "after a restart, a note on /app isn't taken by /app/ while both are open")

        // Firefox and Zen can't count by address (their strips show titles): unknown, so never found again by it.
        let inbox = place(.tab, pid: 3, app: "org.mozilla.firefox", tab: NoteTab(index: 1, count: 2, shared: 1, url: "https://mail.example.com/inbox", title: "Inbox (3)"))
        expect(!NoteRules.fits(inbox, FrontPlace(pid: 4, app: "org.mozilla.firefox", window: 9,
                                                 tab: NoteTab(element: 3, index: 2, count: 2, url: "https://mail.example.com/inbox", title: "Inbox (5)"))),
               "after a restart, a Firefox tab isn't found by its address: another tab may have it")

        // A read that didn't count (a note's AI reading its tab) keeps the count made for the same address.
        let counted = NoteTab(id: "41", index: 1, count: 2, shared: 1, url: "https://a.com/app", title: "")
        expect(NoteRules.follow(counted, to: NoteTab(id: "41", index: 2, count: 3, url: "https://a.com/app/", title: ""), keepWords: true).shared == 1,
               "an uncounted read of the same address keeps its count")
        expect(NoteRules.follow(counted, to: NoteTab(id: "41", index: 2, count: 3, url: "https://a.com/other", title: ""), keepWords: true).shared == nil,
               "a new address drops it")
        expect(NoteRules.follow(counted, to: NoteTab(id: "41", index: 2, count: 3, shared: 2, url: "https://a.com/app", title: ""), keepWords: true).shared == 2,
               "a counted read replaces it")

        // Never saved: a tab's button means nothing once Petal quits.
        let saved = try! JSONEncoder().encode(s1)
        let back = try! JSONDecoder().decode(NoteTab.self, from: saved)
        expect(back.element == nil && back.index == 2 && back.url == s1.url, "a tab's button is never saved",
               String(data: saved, encoding: .utf8) ?? "")
        expect(!back.known && s1.known && a.known, "a tab read back from a save is known only by its address")
        // Petal restarted, the browser didn't: the same process, but the kept chat has no button: it isn't found again.
        let keptFromBefore = place(.tab, tab: back)
        expect(!NoteRules.fits(keptFromBefore, safariFront(NoteTab(element: 5, index: 3, count: 4, shared: 1, url: s1.url, title: ""))),
               "after Petal restarted, not even the browser's only tab on its address")
        expect(!NoteRules.fits(keptFromBefore, safariFront(NoteTab(element: 5, index: 2, count: 4, url: s1.url, title: ""))),
               "nor one in its place")
        // A Chromium tab after Petal restarted, the browser not: its id still means its tab.
        let chromeBack = try! JSONDecoder().decode(NoteTab.self, from: try! JSONEncoder().encode(a))
        expect(chromeBack.id == "41" && NoteRules.fits(place(.tab, app: chrome, tab: chromeBack), chromeFront(NoteTab(id: "41", url: "https://x.com", title: ""))),
               "a Chromium tab's id is saved and finds its tab while the browser runs")

        // MARK: Telling notes apart (one tab, one note)

        // Two Chromium chats kept from before the browser restarted, on the same address; the browser has it once:
        // neither by the address alone.
        let keptA = place(.tab, pid: 3, app: chrome, tab: NoteTab(id: "1", index: 1, count: 1, shared: 1, url: a.url, title: ""))
        let keptB = place(.tab, pid: 3, app: chrome, window: 6, tab: NoteTab(id: "2", index: 1, count: 1, shared: 1, url: a.url, title: ""))
        let onlyTab = chromeFront(NoteTab(id: "7", index: 1, count: 1, shared: 1, url: a.url, title: ""))
        expect(NoteRules.fits(keptA, onlyTab) && NoteRules.fits(keptB, onlyTab), "both fit by the address")
        expect(NoteRules.fitting([keptA, keptB], onlyTab).isEmpty, "so neither is taken: no note moves onto the other's tab")
        expect(NoteRules.fitting([keptA], onlyTab) == [0], "one alone is")
        // A Chromium tab's id is certain, whatever else fits by the address.
        let byID = place(.tab, app: chrome, tab: NoteTab(id: "7", index: 1, count: 1, shared: 1, url: a.url, title: ""))
        expect(NoteRules.fitting([keptA, byID], onlyTab) == [1], "a Chromium tab's own id wins; a guess by address isn't taken")
        expect(NoteRules.fitting([place(.window, app: chrome), place(.app, app: chrome), keptA, keptB], onlyTab) == [0, 1],
               "window and app notes are never held back by tabs alike")
        // Safari: by its button only, so two notes are never both a guess.
        let byButton = place(.tab, tab: NoteTab(element: 3, index: 1, count: 1, url: s1.url, title: ""))
        let safariKept = place(.tab, pid: 3, tab: NoteTab(index: 1, count: 1, url: s1.url, title: ""))
        expect(NoteRules.fitting([safariKept, byButton], safariFront(NoteTab(element: 3, index: 1, count: 1, url: s1.url, title: ""))) == [1],
               "a Safari tab's own button; a chat known only by its address never")

        // MARK: Notes here and chats kept from before, together

        let chatA = UUID(), chatB = UUID()
        let liveA = NoteCandidate(place: keptA, chat: chatA, live: true)
        let keptChatB = NoteCandidate(place: keptB, chat: chatB, live: false)
        expect(NoteRules.fitting([liveA, keptChatB], onlyTab).isEmpty,
               "a note here isn't moved onto a tab a kept chat fits as well (union, not the live notes alone)")
        expect(NoteRules.fitting([NoteCandidate(place: byID, chat: chatA, live: true), keptChatB], onlyTab) == [0],
               "the note here with the tab's own id is taken")
        expect(NoteRules.fitting([liveA], onlyTab) == [0], "with no kept chat alike, the note here follows its tab")
        // The same chat as a note here and its kept copy (picked from the list after a restart): one candidate.
        let keptCopyA = NoteCandidate(place: keptA, chat: chatA, live: false)
        expect(NoteRules.unique([keptCopyA, liveA]) == [1], "a kept copy of a chat a note here holds is that note")
        expect(NoteRules.fitting([liveA, keptCopyA], onlyTab) == [0], "so the chat's two copies never make its tab unsure")
        expect(NoteRules.fitting([keptCopyA, liveA], onlyTab) == [1], "whichever order they're gathered in")
        expect(NoteRules.unique([keptCopyA, keptCopyA, NoteCandidate(place: keptB, chat: nil, live: true)]) == [0, 2],
               "two kept copies of one chat are one; a note with no chat is its own")
        expect(NoteRules.fitting([keptCopyA, NoteCandidate(place: place(.window, app: chrome), chat: chatB, live: true)], onlyTab) == [0, 1],
               "a kept chat and a window's note both fit")

        // MARK: Private apps

        var said = place(.tab, tab: NoteTab(element: 4, index: 2, count: 4, shared: 1, url: s1.url, title: "Mac"))
        said.title = "Mac - Apple"
        let clean = said.scrubbed
        expect(clean.title.isEmpty && clean.tab?.url == "" && clean.tab?.title == "", "a private app's titles and address go")
        expect(clean.tab?.element == 4 && clean.tab?.index == 2 && clean.scope == .tab && clean.window == 5, "its tab's button and place stay")
        expect(!NoteRules.fits(place(.tab, pid: 3, tab: clean.tab), safariFront(NoteTab(element: 6, shared: 1, url: "", title: ""))),
               "with no address kept, it's never found again by one")
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

        // MARK: One place, one note

        // Two tab notes of one window, both made "This window": the one made so last takes the window, the other lets go.
        let tabA = place(.tab, tab: NoteTab(element: 1, index: 1, count: 2, url: "https://a.com", title: ""))
        let tabB = place(.tab, tab: NoteTab(element: 2, index: 2, count: 2, url: "https://b.com", title: ""))
        var widenedA = tabA, widenedB = tabB
        widenedA.scope = .window
        widenedB.scope = .window
        expect(NoteRules.letGo([tabA, tabB]).isEmpty, "two tabs of one window are two places")
        expect(NoteRules.letGo([widenedB, widenedA]) == [1], "made the same window: the one taking it keeps it, the other lets go")
        expect(NoteRules.letGo([widenedB, nil, tabA, place(.window, window: 6)]).isEmpty, "a tab of that window, another window, or none: no clash")
        expect(NoteRules.letGo([place(.app, window: 5), place(.app, pid: 99, window: 8)]) == [1], "two notes made all of one app: one keeps it")
        // Kept chats, newest first, after a restart: the newest keeps the place.
        expect(NoteRules.letGo([widenedA, widenedB, widenedA, tabB]) == [1, 2], "read newest first, each place keeps its newest chat")

        // Two tabs on one address, each with a note; tab B moved into A's old place while A wasn't selected: B's place
        // is updated, A's isn't, so their window, place and address match. B made "This tab" again never makes A let
        // go: different buttons, and different keys.
        let twinA = place(.tab, tab: NoteTab(element: 1, index: 1, count: 2, url: s1.url, title: ""))
        let twinB = place(.tab, tab: NoteTab(element: 2, index: 1, count: 2, url: s1.url, title: ""))
        expect(NoteRules.key(twinA) != NoteRules.key(twinB), "their keys are their buttons", NoteRules.key(twinA))
        expect(!NoteRules.samePlace(twinB, twinA) && NoteRules.letGo([twinB, twinA]).isEmpty, "two buttons are two tabs")
        expect(NoteRules.letGo([twinB, place(.tab, tab: NoteTab(element: 2, index: 2, count: 2, url: "https://other.com", title: ""))]) == [1],
               "one button is one tab, whatever its place and address")
        let chromeTwinA = place(.tab, app: chrome, tab: NoteTab(id: "1", index: 1, count: 2, url: a.url, title: ""))
        let chromeTwinB = place(.tab, app: chrome, tab: NoteTab(id: "2", index: 1, count: 2, url: a.url, title: ""))
        expect(NoteRules.letGo([chromeTwinB, chromeTwinA]).isEmpty && NoteRules.letGo([chromeTwinA, chromeTwinA]) == [1], "Chromium tabs by their ids")
        expect(NoteRules.letGo([place(.tab, pid: 11, app: chrome, tab: chromeTwinA.tab), chromeTwinA]).isEmpty, "never across two runs of the browser")
        // The same two read back after a restart: no button, the same window, place and address. Stale keys never make
        // one chat let go of its place for another: a tab known by neither id nor button holds no place.
        let keptTwin = place(.tab, tab: NoteTab(index: 1, count: 2, url: s1.url, title: ""))
        expect(!NoteRules.samePlace(keptTwin, twinA) && !NoteRules.samePlace(twinA, keptTwin), "a tab known by its button isn't a kept chat's by its key")
        expect(!NoteRules.samePlace(keptTwin, keptTwin) && NoteRules.letGo([keptTwin, keptTwin]).isEmpty,
               "two Safari chats kept from before, alike: neither lets go for the other")
        expect(!keptTwin.tabComesBack, "and neither comes back to a place")
        // Two Chromium chats kept for one tab (the same id, the same run of the browser): the newest keeps it.
        let chromeKept = place(.tab, pid: 3, app: chrome, tab: NoteTab(id: "9", index: 1, count: 2, url: a.url, title: ""))
        expect(NoteRules.letGo([chromeKept, chromeKept]) == [1], "two Chromium chats for one tab id: the newest keeps it")

        // MARK: Keys

        expect(NoteRules.key(place(nil)) == "10-5", "a window's key is the one kept chats had")
        expect(NoteRules.key(place(.app)) == "app|com.apple.Safari", "an app's key is its app")
        expect(NoteRules.key(chromeNote) == "tab|10|41", "a Chromium tab's key is its id")
        expect(NoteRules.key(safariNote) == "tab|10|e1", "a Safari tab's key is its button")
        expect(NoteRules.key(keptTwin) == "tab|10|5/1|\(s1.url)", "one known by neither: its window, place and address")

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
