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
        let safariOnly = NoteTab(element: 900, index: 1, count: 2, shared: 1, url: "https://apple.com/mac", title: "")
        expect(!NoteRules.fits(place(.tab, tab: NoteTab(index: 1, count: 1, shared: 1, url: "https://apple.com/mac", title: "")),
                               FrontPlace(pid: 99, app: "com.apple.Safari", window: 40, tab: NoteTab(index: 1, count: 1, shared: 1, url: "https://apple.com/mac", title: ""))),
               "never onto a tab Petal couldn't tell apart from then on (no strip)")
        expect(NoteRules.fits(place(.tab, tab: NoteTab(index: 1, count: 1, shared: 1, url: "https://apple.com/mac", title: "")),
                              FrontPlace(pid: 99, app: "com.apple.Safari", window: 40, tab: safariOnly)),
               "a Safari tab after a restart: the browser's only tab on its address, with a button")

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
        let adopted = NoteRules.follow(NoteTab(index: 1, count: 1, shared: 1, url: s1.url, title: ""), to: safariOnly, keepWords: true)
        expect(adopted.element == 900, "a tab found again by its address takes its button from then on")
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
        let slashNote = place(.tab, pid: 3, app: chrome, tab: NoteTab(index: 1, count: 2, shared: NoteRules.shared("https://a.com/app", among: listed),
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
        expect(back.element == nil && back.index == 2 && back.shared == 1 && back.url == s1.url, "a tab's button is never saved",
               String(data: saved, encoding: .utf8) ?? "")
        expect(!back.known && s1.known && a.known, "a tab read back from a save is known only by its address")
        // Petal restarted, the browser didn't: the same process, but the kept chat has no button: by the address alone.
        let keptFromBefore = place(.tab, tab: back)
        expect(NoteRules.fits(keptFromBefore, safariFront(NoteTab(element: 5, index: 3, count: 4, shared: 1, url: s1.url, title: ""))),
               "after Petal restarted, the browser's only tab on its address")
        expect(!NoteRules.fits(keptFromBefore, safariFront(NoteTab(element: 5, index: 2, count: 4, shared: 2, url: s1.url, title: ""))),
               "but not one of two, even in its place")

        // MARK: Telling notes apart (one tab, one note)

        // Two notes kept from before on the same address; the browser has it once: neither by the address alone.
        let keptA = place(.tab, pid: 3, tab: NoteTab(index: 1, count: 1, shared: 1, url: s1.url, title: ""))
        let keptB = place(.tab, pid: 3, window: 6, tab: NoteTab(index: 1, count: 1, shared: 1, url: s1.url, title: ""))
        let onlyTab = safariFront(NoteTab(element: 3, index: 1, count: 1, shared: 1, url: s1.url, title: ""))
        expect(NoteRules.fits(keptA, onlyTab) && NoteRules.fits(keptB, onlyTab), "both fit by the address")
        expect(NoteRules.fitting([keptA, keptB], onlyTab).isEmpty, "so neither is taken: no note moves onto the other's tab")
        expect(NoteRules.fitting([keptA], onlyTab) == [0], "one alone is")
        // A note with the tab's own button wins; a guess by address isn't taken.
        let byButton = place(.tab, tab: NoteTab(element: 3, index: 1, count: 1, shared: 1, url: s1.url, title: ""))
        expect(NoteRules.fitting([keptA, byButton], onlyTab) == [1], "a tab's own button wins over the address")
        // A Chromium tab's id is certain, whatever else fits by the address.
        let byID = place(.tab, app: chrome, tab: NoteTab(id: "7", index: 1, count: 1, shared: 1, url: a.url, title: ""))
        let byURL = place(.tab, pid: 3, app: chrome, tab: NoteTab(id: "70", index: 1, count: 1, shared: 1, url: a.url, title: ""))
        let chromeNow = chromeFront(NoteTab(id: "7", index: 1, count: 1, shared: 1, url: a.url, title: ""))
        expect(NoteRules.fitting([byID, byURL], chromeNow) == [0], "a Chromium tab's own id wins; a guess by address isn't taken")
        expect(NoteRules.fitting([place(.window), place(.app), keptA, keptB], onlyTab) == [0, 1],
               "window and app notes are never held back by tabs alike")

        // MARK: Notes here and chats kept from before, together

        let chatA = UUID(), chatB = UUID()
        let liveA = NoteCandidate(place: keptA, chat: chatA, live: true)
        let keptChatB = NoteCandidate(place: keptB, chat: chatB, live: false)
        expect(NoteRules.fitting([liveA, keptChatB], onlyTab).isEmpty,
               "a note here isn't moved onto a tab a kept chat fits as well (union, not the live notes alone)")
        expect(NoteRules.fitting([NoteCandidate(place: byButton, chat: chatA, live: true), keptChatB], onlyTab) == [0],
               "the note here with the tab's button is taken")
        expect(NoteRules.fitting([liveA], onlyTab) == [0], "with no kept chat alike, the note here follows its tab")
        // The same chat as a note here and its kept copy (picked from the list after a restart): one candidate.
        let keptCopyA = NoteCandidate(place: keptA, chat: chatA, live: false)
        expect(NoteRules.unique([keptCopyA, liveA]) == [1], "a kept copy of a chat a note here holds is that note")
        expect(NoteRules.fitting([liveA, keptCopyA], onlyTab) == [0], "so the chat's two copies never make its tab unsure")
        expect(NoteRules.fitting([keptCopyA, liveA], onlyTab) == [1], "whichever order they're gathered in")
        expect(NoteRules.unique([keptCopyA, keptCopyA, NoteCandidate(place: keptB, chat: nil, live: true)]) == [0, 2],
               "two kept copies of one chat are one; a note with no chat is its own")
        expect(NoteRules.fitting([keptCopyA, NoteCandidate(place: place(.window), chat: chatB, live: true)], safariFront(NoteTab(element: 3, index: 1, count: 1, shared: 1, url: s1.url, title: ""))) == [0, 1],
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
