import AppKit
import ApplicationServices
import Security

// MARK: - Filling

/// Puts a vault value into one field, off the main thread: only once the field is still on the page (or in the app)
/// Petal decided on, still the kind of field it was, and has the keyboard. Keystrokes posted to the app's own process
/// a few at a time (UIMap.batches), or an item picked from a pop-up menu; never the clipboard. A password field's
/// value is never read back.
enum VaultFiller {
    static func fill(_ plan: VaultFillPlan, into element: AXUIElement, map: ComputerUse.Map, cancel: Acting.Cancel) -> String? {
        let pid = map.pid
        // The same page or app as when Petal decided: a page that moved on meanwhile never gets it.
        // Payment info also stays on the very page Buy was said on.
        let card: Set<VaultField> = [.number, .securityCode, .expiry, .month, .year]
        let now = VaultReader.place(of: element, pid: pid, bundle: map.bundle, appName: map.appName)
        if let why = Vault.moved(from: plan.place, to: now, samePage: card.contains(plan.field)) { return why }
        if !plan.place.web, plan.place.signed, !now.signed { return "Petal couldn't verify \(map.appName) anymore; nothing was filled." }
        // Still the kind of field it was: a password field if it was one, a menu if it was one.
        if VaultReader.target(element) != plan.target {
            return "That field changed since petal_ui; nothing was filled. Call petal_ui again."
        }
        // What to put in: from the vault now (the AI never holds it), or what the person just typed into the card.
        let saved: VaultItem?
        if plan.given == nil {
            do { saved = try VaultStore.item(plan.itemID) } catch { return VaultStore.unreadableText + " Nothing was filled." }
        } else {
            saved = nil
        }
        // A year as the field wants it: a menu's own items say ("2027" or "27"); a text field's placeholder, label or
        // room (or what the AI said).
        var four: Bool?
        if [.year, .expiry].contains(plan.field), !plan.target.popup {
            let node = Reader.node(element)
            let room: Int? = Windows.value(element, "AXMaxLength") ?? Windows.value(element, "AXMaxNumberOfCharacters")
            four = Vault.fourDigitYear(plan.field, format: plan.yearFormat, hints: [node.placeholder, node.label, node.title, node.help],
                                       maxLength: room)
        }
        // The item as it was when Petal planned the fill (and the person said Buy on it), not one edited since.
        if let saved, !Vault.sameRevision(plan.revision, saved) { return Vault.changedText }
        guard let text = plan.given.map({ Vault.typed(plan.field, $0) }) ?? saved.flatMap({ Vault.text($0, plan.field, fourDigitYear: four) }),
              !text.isEmpty else { return "That isn't in the vault anymore." }
        guard !cancel.stopped else { return cancel.buyEnded ? Acting.buyEndedText : ComputerUse.stoppedText }
        // Hidden from the AI before a key goes, saved in the vault or not: in petal_ui, petal_look, the clipboard and
        // pictures (Sensitive), for as long as Petal runs.
        if plan.field.isSecret {
            VaultIndex.remember(Vault.secrets(plan.field, text))
            Sensitive.filled(element, pid: pid)
        }
        if let error = Acting.bringWindow(map, cancel: cancel) { return error }
        if plan.target.popup {
            let year = plan.field == .year ? saved.map { $0[.expiry] } : nil
            let month = plan.field == .month
            // Right before each press (an option, opening the menu, its item): not stopped, steered or past the Buy,
            // and still the page Petal decided on. Reading a long menu's options takes a while.
            let still = { () -> String? in
                if cancel.stopped { return cancel.buyEnded ? Acting.buyEndedText : ComputerUse.stoppedText }
                return stillOnPage(plan, element: element, map: map, cancel: cancel, typed: false)
            }
            return choose(text, in: element, pid: pid, cancel: cancel, still: still, pick: { titles in
                if month { return Vault.pickMonth(text, from: titles) }
                return year.flatMap { Vault.pickYear($0, from: titles) } ?? Vault.pick(text, from: titles)
            })
        }
        if !Acting.isFront(pid) {
            guard Acting.bringForward(pid, cancel: cancel) else { return ComputerUse.stoppedText }
        }
        guard !cancel.stopped else { return ComputerUse.stoppedText }
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        var there = false
        for attempt in 0..<4 {
            if keysGo(to: element, pid: pid) { there = true; break }
            if attempt < 3 { usleep(70_000) }
        }
        guard there else { return "Couldn't put the cursor in that field through Accessibility. Ask the person to click into it, then try again." }
        // Focusing may have moved the page on (its own code going to another address): read again before any key.
        if let why = stillOnPage(plan, element: element, map: map, cancel: cancel, typed: false) { return why }
        // Over what's there already, only once the keyboard is in this field.
        if let all = UIMap.parseKey("cmd-a") {
            guard keysGo(to: element, pid: pid), Acting.post(all, to: pid, cancel: cancel) else {
                return cancel.stopped ? ComputerUse.stoppedText : "The cursor left the field; nothing was filled."
            }
        }
        // And before each batch of keys: the slow checks first (the page, a tab note's tab), then, immediately before
        // the keys go, the quick ones (the window in front, the keyboard in this field), so a click elsewhere while
        // the page was being read never gets them.
        var moved: String?
        var typed = false
        let still = {
            moved = stillOnPage(plan, element: element, map: map, cancel: cancel, typed: typed)
            if moved == nil, let tabPlace = map.tabPlace, ClaudePanel.tabShowing(tabPlace) == nil {
                moved = ClaudePanel.tabNotShowing + (typed ? " Petal stopped partway; what went in may need clearing." : "")
            }
            guard moved == nil, !cancel.stopped, Acting.windowInFront(map), keysGo(to: element, pid: pid) else { return false }
            typed = true
            return true
        }
        guard Acting.type(text, to: pid, cancel: cancel, still: still) else {
            if let moved { return moved }
            return cancel.stopped ? ComputerUse.stoppedText : "The cursor left the field while Petal was filling it, so it stopped there. Call petal_ui to see the page."
        }
        // A card number or code a field cut short (a 16-character field given more) isn't a fill: counted here,
        // never returned or logged. A secure field gives only its length. A browser's Accessibility may still show the
        // field as it was a moment ago (Chromium's lags behind its page), so it's read again for a little while
        // (never typed again), still on the same page, before it counts as cut short.
        if plan.field == .number || plan.field == .securityCode {
            var fits: Bool?
            for attempt in 0..<10 {
                if attempt > 0 {
                    usleep(60_000)
                    guard !cancel.stopped else { return cancel.buyEnded ? Acting.buyEndedText : ComputerUse.stoppedText }
                    if let why = stillOnPage(plan, element: element, map: map, cancel: cancel, typed: true) { return why }
                }
                let value: String? = plan.target.secure ? nil : Windows.value(element, kAXValueAttribute)
                let count: Int? = Windows.value(element, kAXNumberOfCharactersAttribute)
                fits = Vault.fits(text, value: value, count: count)
                if fits != false { break }
            }
            if fits == false {
                return plan.field == .number ? "The card number didn't fit in that field: it holds fewer digits than the card has. Ask the person to check it."
                    : "The security code didn't fit in that field. Ask the person to check it."
            }
        }
        if plan.submit, let enter = UIMap.parseKey("return") {
            guard keysGo(to: element, pid: pid) else { return "The cursor left the field before Return: it was filled, not sent." }
            guard Acting.post(enter, to: pid, cancel: cancel) else { return ComputerUse.stoppedText }
        }
        return nil
    }

    /// Why `element`'s page, read live as the check before filling reads it, isn't the one Petal decided on any more
    /// (another site, or for payment info another page of the shop: the checkout Buy was said on), or nil. A page's
    /// own code can move it on once the field is focused. A payment fill's Buy ends there: nothing more of the card
    /// goes in, on that page or after. `typed`: some of it went in already.
    static func stillOnPage(_ plan: VaultFillPlan, element: AXUIElement, map: ComputerUse.Map, cancel: Acting.Cancel, typed: Bool) -> String? {
        guard plan.place.web || plan.place.unverified else { return nil }
        let card: Set<VaultField> = [.number, .securityCode, .expiry, .month, .year]
        let now = VaultReader.place(of: element, pid: map.pid, bundle: map.bundle, appName: map.appName)
        guard Vault.moved(from: plan.place, to: now, samePage: plan.payment || card.contains(plan.field)) != nil else { return nil }
        let host = now.host ?? now.claimedURL.flatMap(VaultSite.host) ?? "another page"
        let stopped = typed ? "Petal stopped partway; what went in may need clearing." : "Nothing was filled."
        guard plan.payment else { return "The page moved on to \(host) while Petal was filling. \(stopped) Call petal_ui again." }
        cancel.endBuy()
        return "The page moved on to \(host) while Petal was filling payment info. \(stopped) The Buy is over: "
            + "don't try another way; if the person still wants it, fill again on the checkout page and Petal asks them again."
    }

    /// The app's keyboard is in `element` (or inside it), a password field or not.
    static func keysGo(to element: AXUIElement, pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let focused: AXUIElement = Windows.value(app, kAXFocusedUIElementAttribute) else { return false }
        var current: AXUIElement? = focused
        for _ in 0..<4 {
            guard let at = current else { return false }
            if CFEqual(at, element) { return true }
            current = Windows.value(at, kAXParentAttribute)
        }
        return false
    }

    /// Picks the item that is `wanted` from a pop-up menu (a web page's select; Vault.pick: "Türkiye" finds "Turkey";
    /// a year as "2027" or "27", whichever the menu has): straight from its options when it shows them closed, else
    /// by opening it and pressing the item in the menu that opens (under it, or the app's own: Chromium's), or
    /// closes it again with nothing picked when none is. `still` is asked right before every press, and its answer
    /// (stopped, or the page moved on) ends it with nothing more pressed.
    static func choose(_ wanted: String, in popup: AXUIElement, pid: pid_t, cancel: Acting.Cancel,
                       still: () -> String?, pick: ([String]) -> Int?) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        func role(_ element: AXUIElement) -> String { Windows.value(element, kAXRoleAttribute) ?? "" }
        func children(_ element: AXUIElement) -> [AXUIElement] { Windows.value(element, kAXChildrenAttribute) ?? [] }
        // The menus this app shows open: its own (a select's native menu), or the one holding what has its keyboard.
        func appMenus() -> [AXUIElement] {
            var menus = children(app).filter { role($0) == "AXMenu" }
            var current: AXUIElement? = Windows.value(app, kAXFocusedUIElementAttribute)
            for _ in 0..<3 {
                guard let at = current else { break }
                if role(at) == "AXMenu" { menus.append(at); break }
                current = Windows.value(at, kAXParentAttribute)
            }
            return menus
        }
        func index(_ list: [AXUIElement]) -> Int? {
            func texts(_ name: String) -> [String] { list.map { (Windows.value($0, name) as String?) ?? "" } }
            return Vault.pickOption(titles: texts(kAXTitleAttribute), values: texts(kAXValueAttribute),
                                    labels: texts(kAXDescriptionAttribute), pick: pick)
        }
        func close() { if let escape = UIMap.parseKey("escape") { Acting.post(escape, to: pid, cancel: Acting.Cancel()) } }
        if let why = still() { return why }
        // Shown without opening it: pressed there.
        let shown = Vault.selectOptions(popup, opened: false, appMenus: [], role: role, children: children).items
        if let at = index(shown) {
            if let why = still() { return why }
            if AXUIElementPerformAction(shown[at], kAXPressAction as CFString) == .success { return nil }
        }
        if let why = still() { return why }
        AXUIElementPerformAction(popup, kAXPressAction as CFString)
        var list: [AXUIElement] = []
        for attempt in 0..<6 {
            usleep(80_000)
            let found = Vault.selectOptions(popup, opened: true, appMenus: appMenus(), role: role, children: children)
            list = found.items
            if found.inMenu || (attempt >= 3 && !list.isEmpty) { break }
        }
        guard let at = index(list) else {
            close()
            return list.isEmpty ? "That menu didn't open through Accessibility; ask the person to pick it." : "Petal didn't find a matching item in that menu; ask the person to pick it."
        }
        if let why = still() { close(); return why }
        guard AXUIElementPerformAction(list[at], kAXPressAction as CFString) == .success else {
            close()
            return "Couldn't pick it from that menu; ask the person to pick it."
        }
        return nil
    }
}

// MARK: - Where a field is

/// Which page or app a field is in, read by Petal through Accessibility (never from the AI), off the main thread.
enum VaultReader {
    /// The browsers whose pages Petal believes about their address (AXURL), with who signs each (its Team ID, or
    /// "apple"): any other app's web view is part of that app, filled as the app.
    static let browsers: [String: String] = [
        "com.apple.Safari": "apple", "com.apple.SafariTechnologyPreview": "apple",
        "com.google.Chrome": "EQHXZ8M8AV", "com.google.Chrome.beta": "EQHXZ8M8AV", "com.google.Chrome.dev": "EQHXZ8M8AV",
        "com.google.Chrome.canary": "EQHXZ8M8AV", "org.mozilla.firefox": "43AQ936H96", "org.mozilla.firefoxdeveloperedition": "43AQ936H96",
        "org.mozilla.nightly": "43AQ936H96", "com.microsoft.edgemac": "UBF8T346G9", "com.brave.Browser": "KL8N8XSYF4",
        "com.brave.Browser.beta": "KL8N8XSYF4", "company.thebrowser.Browser": "S6N382Y83G", "com.vivaldi.Vivaldi": "4XF3XNRN6Y",
        "com.operasoftware.Opera": "A2P9LX4JPN", "net.imput.helium": "S4Q33XPHB4", "com.t3tools.t3code": "ARK85ZXQ4Z",
        "at.studio.AsideBrowser": "8CPD4K4TBB", "com.phibrowser.Mac": "87DQ3HMK5G",
    ]

    /// Every browser Petal knows of, trusted or not (Browsers.swift's, the ones above, and a few more people use):
    /// a field in one, outside a page Petal can verify, is never filled by itself or saved for the browser as an app.
    static let known: Set<String> = Set(browsers.keys).union(Browsers.chromium.keys).union(Browsers.safari).union(Browsers.gecko).union([
        "app.zen-browser.zen", "com.kagi.kagimacOS", "com.duckduckgo.macos.browser", "com.operasoftware.OperaGX",
        "com.sigmaos.sigmaos.macos", "net.waterfox.waterfox", "io.gitlab.librewolf-community", "one.ablaze.floorp",
        "org.chromium.Thorium", "com.ungoogled.chromium", "ru.yandex.desktop.yandex-browser", "com.naver.Whale",
        "org.torproject.torbrowser", "com.mullvad.mullvadbrowser", "com.openai.atlas", "ai.perplexity.comet",
    ])

    /// The addresses of the web areas around `element`: the nearest (a login or payment frame's own) and the tab's
    /// page (the outermost before an app's own page: T3 Code's sites sit inside its t3code://app/ page, which is
    /// never the page; Vault.pageTop), in a browser Petal trusts whose signature checks out. A page anywhere else (a
    /// browser Petal doesn't trust, another app's web view), or a browser's own controls: unverified, with the address
    /// the page gives for itself. Otherwise the app, and who signed it.
    static func place(of element: AXUIElement, pid: pid_t, bundle: String, appName: String) -> Vault.Place {
        var place = Vault.Place(bundle: bundle, appName: appName)
        var areas: [(element: AXUIElement, url: String?)] = []
        var current: AXUIElement? = element
        for _ in 0..<120 {
            guard let at = current else { break }
            let role: String = Windows.value(at, kAXRoleAttribute) ?? ""
            if role == "AXWebArea" { areas.append((at, url(at))) }
            if role == "AXWindow" || role == "AXApplication" { break }
            current = Windows.value(at, kAXParentAttribute)
        }
        let surface = Vault.surface(webArea: !areas.isEmpty, trusted: !areas.isEmpty && isBrowser(pid: pid, bundle: bundle),
                                    browser: known.contains(bundle))
        if surface == .web, !areas.isEmpty {
            let top = areas[Vault.pageTop(areas.map(\.url))]
            place.web = true
            place.frameURL = areas.first?.url
            place.topURL = top.url
            place.tab.page = top.element
        } else {
            place.unverified = surface == .unverified
            place.claimedURL = areas.first?.url
            place.team = signer(pid: pid, bundle: bundle)
            place.signed = place.team != nil || signed(pid: pid, bundle: bundle)
        }
        return place
    }

    /// The pages a browser window shows (each tab page's outermost web area that isn't an app's own page: inside T3
    /// Code's t3code://app/ page, the site's page it shows), as places: what a Buy is checked against before each act
    /// in that window, the same page `place(of:)` gives a field in it. A browser split into panes (Phi) shows several
    /// side by side; a Buy lasts while its own page is one of them. Not a web page (another app, or none found in
    /// time): none.
    static func pages(in window: AXUIElement, pid: pid_t, bundle: String, appName: String) -> [Vault.Place] {
        guard isBrowser(pid: pid, bundle: bundle) else { return [] }
        var out: [Vault.Place] = []
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var seen = 0
        let deadline = Date().addingTimeInterval(1)
        while !queue.isEmpty, seen < 3000, out.count < Self.panes, Date() < deadline {
            let (element, depth) = queue.removeFirst()
            seen += 1
            if (Windows.value(element, kAXRoleAttribute) as String?) == "AXWebArea" {
                let address = url(element)
                if Vault.isTabPage(address) {
                    var place = Vault.Place(bundle: bundle, appName: appName)
                    place.web = true
                    place.frameURL = address
                    place.topURL = address
                    place.tab.page = element
                    out.append(place)
                    // Its frames are part of it, never pages of their own.
                    continue
                }
            }
            guard depth < 30 else { continue }
            let children: [AXUIElement] = Windows.value(element, kAXChildrenAttribute) ?? []
            queue += children.map { ($0, depth + 1) }
        }
        return out
    }

    /// At most this many pages side by side in one window.
    static let panes = 8

    static func url(_ area: AXUIElement) -> String? {
        if let url: URL = Windows.value(area, "AXURL") { return url.absoluteString }
        if let text: String = Windows.value(area, "AXURL") { return text }
        return nil
    }

    private static func guest(_ pid: pid_t) -> SecCode? {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess else { return nil }
        return code
    }

    private static func satisfies(_ code: SecCode, _ text: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private static func requirement(bundle: String, team: String) -> String? {
        guard !bundle.isEmpty, !bundle.contains("\""), !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return team == "apple" ? "anchor apple and identifier \"\(bundle)\""
            : "anchor apple generic and identifier \"\(bundle)\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// The running app is a browser Petal knows, signed now by that browser's maker.
    static func isBrowser(pid: pid_t, bundle: String) -> Bool {
        guard let team = browsers[bundle], let text = requirement(bundle: bundle, team: team), let code = guest(pid) else { return false }
        return satisfies(code, text)
    }

    /// The running app is signed by Apple's certificates (an App Store or Developer ID app, or Apple's own) for this
    /// very bundle id, and its signature checks out now.
    static func signed(pid: pid_t, bundle: String) -> Bool {
        guard !bundle.isEmpty, !bundle.contains("\""), let code = guest(pid) else { return false }
        return satisfies(code, "anchor apple generic and identifier \"\(bundle)\"")
    }

    /// Who signed the running app for this bundle id, checked now: "apple" for Apple's own, else its Team ID; nil
    /// when it isn't signed so (an app made to look like another, signed by someone else, has another Team ID).
    static func signer(pid: pid_t, bundle: String) -> String? {
        guard !bundle.isEmpty, !bundle.contains("\""), let code = guest(pid) else { return nil }
        if satisfies(code, "anchor apple and identifier \"\(bundle)\"") { return "apple" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              let text = requirement(bundle: bundle, team: team), satisfies(code, text) else { return nil }
        return team
    }

    /// Who signed a running app, read off the main thread and handed back on it (for the settings window, when an
    /// app is added to a login).
    static func loadSigner(pid: pid_t, bundle: String, _ done: @escaping @MainActor (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let team = signer(pid: pid, bundle: bundle)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(team) } }
        }
    }

    /// Whether the control takes text, is a password field, or is a pop-up menu.
    static func target(_ element: AXUIElement) -> Vault.Target {
        let node = Reader.node(element)
        return Vault.Target(secure: UIMap.isSecure(node) || Acting.isSecure(element), text: UIMap.isText(node), popup: node.role == "AXPopUpButton")
    }
}

// MARK: - The tool

extension Assist {
    /// petal_vault. `list` what the AI may see; `fill` fields from the vault (a login or API key by itself where it
    /// belongs, else after asking; payment info after one Buy card per checkout; contact info and addresses freely);
    /// `request` what's missing through Petal's card; `new_login` a strong password made, saved and filled. The AI
    /// never sees a password, card number, security code or key. Every step after the first checks the call's reply
    /// is still going (ComputerUse.token).
    func vault(_ args: [String: Any], caller: String?, _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
        switch (args["action"] as? String ?? "list").lowercased() {
        case "list": vaultList(args, send)
        case "fill": vaultFill(args, caller: caller, send, fail)
        case "request": vaultRequest(args, caller: caller, send, fail)
        case "new_login", "generate": vaultNewLogin(args, caller: caller, send, fail)
        case "use": vaultUse(args, caller: caller, send, fail)
        default: fail("action is list, fill, request or new_login.")
        }
    }

    private static let hidden = "Petal fills these itself; you never see a password, card number, security code or key."
    private static let over = ComputerUse.stoppedText + " Don't carry on in this reply: say what's left and wait for them."

    private func vaultList(_ args: [String: Any], _ send: @escaping (Any) -> Void) {
        let kind = (args["kind"] as? String).flatMap { $0.isEmpty ? nil : Vault.kindNamed($0) }
        let site = (args["site"] as? String).flatMap(VaultSite.host)
        VaultStore.load { read in
            guard case .success(let items) = read else { return send(["error": VaultStore.unreadableText + " Try again in a moment."]) }
            var list = items.filter { kind == nil || $0.kind == kind }
            if let site { list = list.filter { $0.kind != .login || $0.sites.contains { VaultSite.matches(host: site, saved: $0) } } }
            var note = Self.hidden + " Fill with action fill: the item's id and fields {field: id from petal_ui}."
            if list.contains(where: { $0.kind == .unsorted }) {
                note += " An unsorted item was saved before the vault had kinds: Petal doesn't know what it is, so filling it (field value) asks the person every time."
            }
            send(["items": list.map { Vault.shown($0, in: items) }, "note": note])
        }
    }

    /// The caller's window from petal_ui and the controls named by id, or nil.
    private func vaultWindow(_ caller: String?, ids: [String]) -> (map: ComputerUse.Map, entries: [ComputerUse.Entry])? {
        guard let caller, let map = computer.maps[caller], Date().timeIntervalSince(map.made) <= UIMap.lifetime else { return nil }
        var entries: [ComputerUse.Entry] = []
        for id in ids {
            guard let entry = map.entries[id] else { return nil }
            entries.append(entry)
        }
        return (map, entries)
    }

    private func needsLook(_ caller: String?, ids: [String]) -> String {
        if caller == nil { return ComputerUse.oldTools }
        if ids.isEmpty { return "Call petal_ui first: the vault fills fields of the window it looked at." }
        return "There's no \(ids.joined(separator: ", ")) in the last petal_ui (ids last until the next petal_ui or 5 minutes). Call petal_ui again."
    }

    /// Where the controls are and what kind each is (and the browser's own answer for the tab: its address and its
    /// id for it), read off the main thread, handed back on it with the vault's items (nil when the vault can't be
    /// read). A tab note's map is read only while the note's tab is the one its window shows (else `fail`): never
    /// another tab's site on a card or in a fill.
    private func vaultPlaces(_ map: ComputerUse.Map, _ entries: [ComputerUse.Entry], fail: @escaping (String) -> Void,
                             done: @escaping @MainActor (_ places: [Vault.Place], _ targets: [Vault.Target], _ items: [VaultItem]?) -> Void) {
        ComputerUse.readQueue.async {
            if let tabPlace = map.tabPlace, ClaudePanel.tabShowing(tabPlace) == nil {
                return DispatchQueue.main.async { fail(ClaudePanel.tabNotShowing) }
            }
            let places = entries.map { VaultReader.place(of: $0.element, pid: map.pid, bundle: map.bundle, appName: map.appName) }
            let targets = entries.map { VaultReader.target($0.element) }
            let title: String = Windows.value(map.window, kAXTitleAttribute) ?? ""
            let items = try? VaultStore.items()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard places.contains(where: \.web) else { return done(places, targets, items) }
                    self.withTab(map, title: title) { url, id in
                        done(places.map { var p = $0; if p.web { p.tabURL = url; p.tab.id = id }; return p }, targets, items)
                    }
                }
            }
        }
    }

    /// The browser's own answer for the tab of `map`'s window (its address and its id for the tab), where it gives
    /// one (Automation allowed).
    private func withTab(_ map: ComputerUse.Map, title: String, done: @escaping @MainActor (_ url: String?, _ id: String?) -> Void) {
        withTab(pid: map.pid, windowID: map.windowID, frame: map.windowFrame, title: title, done: done)
    }

    private func withTab(pid: pid_t, windowID: CGWindowID?, frame: CGRect, title: String, done: @escaping @MainActor (_ url: String?, _ id: String?) -> Void) {
        guard let running = NSRunningApplication(processIdentifier: pid) else { return done(nil, nil) }
        let window = Browsers.Window(number: windowID, title: title, frame: frame)
        app.browsers.tab(of: running, window: window) { url, id in MainActor.assumeIsolated { done(url, id) } }
    }

    /// What `map`'s window shows now (its tab's pages, with the browser's own answer for the tab), read off the main
    /// thread: a Buy in that window is checked against them before every act there (ComputerUse).
    func vaultTab(_ map: ComputerUse.Map, done: @escaping @MainActor ([Vault.Place]) -> Void) {
        vaultTab(window: map.window, pid: map.pid, bundle: map.bundle, appName: map.appName, windowID: map.windowID, frame: map.windowFrame, done: done)
    }

    /// What `window` shows now, as above, for a read that has no map (petal_look).
    func vaultTab(window: AXUIElement, pid: pid_t, bundle: String, appName: String, windowID: CGWindowID?, frame: CGRect,
                  done: @escaping @MainActor ([Vault.Place]) -> Void) {
        // Read only on the read queue, as Map's window is.
        nonisolated(unsafe) let window = window
        ComputerUse.readQueue.async {
            let pages = VaultReader.pages(in: window, pid: pid, bundle: bundle, appName: appName)
            let title: String = Windows.value(window, kAXTitleAttribute) ?? ""
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !pages.isEmpty else { return done([]) }
                    self.withTab(pid: pid, windowID: windowID, frame: frame, title: title) { url, id in
                        done(pages.map { page in
                            var page = page
                            page.tabURL = url
                            page.tab.id = id
                            return page
                        })
                    }
                }
            }
        }
    }

    /// The pages a read of `map`'s window just met (`pages`, each tab page's outermost web area, and its address),
    /// with the browser's own answer for the tab: what petal_ui saw, checked against a Buy in that window. None: no
    /// page.
    func vaultShown(_ map: ComputerUse.Map, pages: [(page: AXUIElement, url: String?)], title: String,
                    done: @escaping @MainActor ([Vault.Place]) -> Void) {
        guard !pages.isEmpty else { return done([]) }
        withTab(map, title: title) { url, id in
            done(pages.map { shown in
                var place = Vault.Place(bundle: map.bundle, appName: map.appName)
                place.web = true
                place.frameURL = shown.url
                place.topURL = shown.url
                place.tab.page = shown.page
                place.tabURL = url
                place.tab.id = id
                return place
            })
        }
    }

    /// The fields asked for: `fields` {field: id}, or one `field` with `id`.
    private func wantedFields(_ args: [String: Any]) -> [(word: String, id: String)]? {
        var out: [(String, String)] = []
        for (key, value) in args["fields"] as? [String: Any] ?? [:] {
            guard let id = value as? String, !id.isEmpty else { return nil }
            out.append((key, id))
        }
        if let word = args["field"] as? String, let id = args["id"] as? String, !id.isEmpty { out.append((word, id)) }
        // The order a form is filled in: the vault's own.
        let order = VaultField.allCases
        return out.sorted { a, b in
            (order.firstIndex { $0 == Vault.field(a.0) } ?? 99) < (order.firstIndex { $0 == Vault.field(b.0) } ?? 99)
        }
    }

    // MARK: fill

    private func vaultFill(_ args: [String: Any], caller: String?, _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
        if let refusal = computer.refusal() { return fail(refusal) }
        guard let wanted = wantedFields(args), !wanted.isEmpty else {
            return fail("Give fields: {field: id} with ids from petal_ui, like {\"username\": \"e3\", \"password\": \"e4\"} (or field and id for one).")
        }
        for (word, _) in wanted where Vault.field(word) == nil {
            return fail("\(word) isn't a field Petal knows: username, password, name, email, phone, street, street2, city, region, postalCode, country, number, expiry, month, year, securityCode or value.")
        }
        let ids = wanted.map(\.id)
        guard let caller, let window = vaultWindow(caller, ids: ids) else { return fail(needsLook(caller, ids: ids)) }
        let map = window.map, entries = window.entries
        let ref = args["item"] as? String ?? args["name"] as? String ?? ""
        let task = args["task"] as? String ?? ""
        guard let token = computer.token(caller, task: task) else { return fail(Self.over) }
        vaultPlaces(map, entries, fail: fail) { places, targets, items in
            guard self.computer.live(caller, token) else { return fail(Self.over) }
            guard let items else { return fail(VaultStore.unreadableText + " Nothing was filled; try again in a moment.") }
            // The item: named, else the login saved for this page (or app), else the only card saved.
            let first = Vault.field(wanted[0].word)!
            let item: VaultItem
            if !ref.isEmpty {
                guard let found = Vault.find(items, ref) else { return fail("There's no “\(ref)” in the vault. action list shows what's there.") }
                item = found
            } else if [.username, .password].contains(first) {
                let place = places[wanted.firstIndex { Vault.field($0.word) == .password } ?? 0]
                // A page Petal can't verify: the login for the address it gives, which then asks (never one saved
                // for the browser as an app).
                let host = place.web ? place.host : place.unverified ? place.claimedURL.flatMap(VaultSite.host) : nil
                let logins = Vault.logins(items, host: host, bundle: place.web || place.unverified ? nil : place.bundle)
                guard !logins.isEmpty else {
                    return fail("There's no login saved for \(place.where_). Ask the person with action request (kind login, fields {username: id, password: id}): they type it into Petal's card, and Petal fills it.")
                }
                guard logins.count == 1 else {
                    return send(["choose": logins.map { Vault.shown($0) }, "note": "More than one login is saved for \(place.where_): call fill again with item (its id)."])
                }
                item = logins[0]
            } else if [.number, .securityCode, .expiry, .month, .year].contains(first), items.filter({ $0.kind == .card }).count == 1 {
                item = items.first { $0.kind == .card }!
            } else {
                return fail("Name the item (its id from action list).")
            }
            // One fill, one place: a card's question is about one page or app only.
            if let mixed = Vault.mixed(item.kind, places) { return fail(mixed) }
            var plans: [VaultFillPlan] = []
            var asked: [VaultField] = []
            var reasons: [String] = []
            var askPlace: Vault.Place?
            var buyPlace: Vault.Place?
            for (offset, pair) in wanted.enumerated() {
                let field = Vault.field(pair.word, kind: item.kind)!
                var plan = VaultFillPlan(itemID: item.id, title: item.title, field: field, place: places[offset], target: targets[offset])
                plan.revision = Vault.revision(item)
                plan.task = task
                plan.yearFormat = (args["yearFormat"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? ((args["fourDigitYear"] as? Bool).map { $0 ? "YYYY" : "YY" })
                plan.payment = item.kind == .card
                let bought = item.kind == .card
                    && self.computer.checkout(caller, token: token, place: places[offset], window: map.windowID, card: item.id,
                                              revision: plan.revision) != nil
                switch Vault.decide(item, field, target: targets[offset], place: places[offset], checkout: bought) {
                case .refuse(let why): return fail("\(pair.id): \(why) Nothing was filled.")
                case .ask(_, let why):
                    asked.append(field)
                    if !reasons.contains(why) { reasons.append(why) }
                    askPlace = askPlace ?? places[offset]
                case .buy: buyPlace = buyPlace ?? places[offset]
                case .fill: break
                }
                plans.append(plan)
            }
            // Return goes once, after the last field; never after payment info (it could place the order).
            if args["submit"] as? Bool == true, !plans.isEmpty {
                if let refusal = Vault.submitRefusal(item.kind) { return fail(refusal) }
                plans[plans.count - 1].submit = true
            }
            let go: (Bool) -> Void = { allowed in
                guard self.computer.live(caller, token) else { return fail(Self.over) }
                self.vaultFillAll(plans, entries: entries, map: map, caller: caller, token: token, allowed: allowed, send: send)
            }
            if let buyPlace {
                return self.vaultBuy(item, place: buyPlace, args: args, map: map, caller: caller, token: token, send: send, fail: fail) { go(true) }
            }
            // One card for every field that doesn't match, naming them all. Payment info a Buy covers fills on that
            // Buy, without asking to use the browser.
            guard let askPlace else { return go(item.kind == .card) }
            self.ask("vault-fill", Vault.question(item, asked, place: askPlace), detail: reasons.joined(separator: " "), always: true, warn: true,
                     allow: "Fill anyway", owner: caller) { allowed in
                guard allowed else { return send(["declined": "The person didn't let Petal fill it. Don't find another way."]) }
                go(true)
            }
        }
    }

    /// Fills the fields one after another; the AI hears which were filled, and the first error if any.
    private func vaultFillAll(_ plans: [VaultFillPlan], entries: [ComputerUse.Entry], map: ComputerUse.Map, caller: String,
                              token: Acting.Cancel, allowed: Bool, send: @escaping (Any) -> Void) {
        var steps = Array(plans.indices)
        var filled: [String] = []
        func next() {
            guard !steps.isEmpty else {
                var reply: [String: Any] = ["filled": filled, "app": map.appName]
                if plans.last?.submit == true { reply["next"] = "The window may have changed: call petal_ui again before using more ids." }
                return send(reply)
            }
            let index = steps.removeFirst()
            computer.fill(plans[index], entry: entries[index], map: map, caller: caller, token: token, allowed: allowed, send: { reply in
                if let declined = (reply as? [String: Any])?["declined"] { return send(["filled": filled, "declined": declined]) }
                filled.append(plans[index].field.rawValue)
                next()
            }, fail: { why in
                send(["filled": filled, "error": why])
            })
        }
        next()
    }

    /// The one card before payment info goes into a shop's page: "Buy on checkout.shop.example?", what Petal AI says
    /// it's buying (its words, marked as such) and the card. Buy lets that card's payment info fill on that exact
    /// host, in that window and tab, for the rest of the reply; Don't (the default) fills nothing.
    private func vaultBuy(_ item: VaultItem, place: Vault.Place, args: [String: Any], map: ComputerUse.Map, caller: String, token: Acting.Cancel,
                          send: @escaping (Any) -> Void, fail: @escaping (String) -> Void, bought: @escaping () -> Void) {
        guard let shop = place.shop, map.windowID != nil, place.tab.page != nil else {
            return fail("Petal couldn't tell which page, tab or window this is, so it fills no payment info here.")
        }
        let what = UIMap.truncate(UIMap.tidy(args["buying"] as? String ?? ""), 160)
        let price = UIMap.truncate(UIMap.tidy(args["price"] as? String ?? ""), 40)
        let said = [what, price].filter { !$0.isEmpty }.joined(separator: ", ")
        let detail = (said.isEmpty ? "Petal AI didn't say what it's buying." : "Petal AI says: “\(said)”.") + " Pays with \(Vault.cardName(item))."
        // A new Buy card for this window ends the Buy already in it (another card on the same checkout), before the
        // person answers: a Don't, a closed card or no answer never leaves the earlier one usable.
        let asked = map.windowID.map { computer.endBuys(in: $0) } ?? 0
        ask("vault-buy", "Buy on \(shop)?", detail: detail, always: true, warn: true, allow: "Buy", owner: caller) { allowed in
            guard allowed else { return send(["declined": "The person said Don't: nothing was filled. Don't buy it, and don't find another way."]) }
            // The card as the Buy card showed it: edited in Settings while the card was open, the Buy counts for
            // nothing (read off the main thread; the Keychain may wait).
            let shown = Vault.revision(item)
            VaultStore.load { result in
                guard case .success(let items) = result else { return fail(VaultStore.unreadableText + " Nothing was filled; try again in a moment.") }
                guard let now = items.first(where: { $0.id == item.id }), Vault.sameRevision(shown, now) else { return fail(Vault.changedText) }
                guard self.computer.allowCheckout(caller, token: token, place: place, map: map, card: item.id, revision: shown, asked: asked) else {
                    return fail("That Buy card is over (a newer one was asked for this window, or the reply ended): nothing was filled. " + Self.over)
                }
                self.did("You said Buy on \(shop) (\(Vault.cardName(item)))")
                bought()
            }
        }
    }

    // MARK: request

    /// Asks the person for what's missing, on Petal's card (a login, contact info, an address, payment info or an
    /// API key): typed there, never into the chat. With fields' ids, Submit fills them on the page Petal read (never
    /// payment info: that waits for Buy), and the card says plainly when that page or app isn't where a login or key
    /// belongs (not secure, another site in a frame, an app Petal can't verify); for a login, "Save to your vault"
    /// (on by default) keeps it for that site.
    private func vaultRequest(_ args: [String: Any], caller: String?, _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
        let legacyName = (args["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let kind = (args["kind"] as? String).flatMap { $0.isEmpty ? nil : Vault.kindNamed($0) } ?? (legacyName.isEmpty ? .login : .apiKey)
        guard VaultKind.made.contains(kind) else { return fail("kind is login, contact, address, card or apiKey.") }
        var mapped: [(VaultField, String)] = []
        if kind != .card {
            for (key, value) in args["fields"] as? [String: Any] ?? [:] {
                if let field = Vault.field(key, kind: kind), let id = value as? String, kind.fillable.contains(field) { mapped.append((field, id)) }
            }
            for (key, field) in [("username_id", VaultField.username), ("password_id", .password)] where kind == .login {
                if let id = args[key] as? String, !id.isEmpty, !mapped.contains(where: { $0.0 == field }) { mapped.append((field, id)) }
            }
        }
        let ids = mapped.map(\.1)
        if !ids.isEmpty, let refusal = computer.refusal() { return fail(refusal) }
        var window: (map: ComputerUse.Map, entries: [ComputerUse.Entry])?
        if !ids.isEmpty {
            guard let found = vaultWindow(caller, ids: ids) else { return fail(needsLook(caller, ids: ids)) }
            window = found
        }
        // The reply this belongs to: nothing is saved or filled for a reply that's over.
        var token: Acting.Cancel?
        if let caller {
            guard let current = computer.token(caller, task: args["task"] as? String ?? "") else { return fail(Self.over) }
            token = current
        }
        let live = { token.map { self.computer.live(caller ?? "", $0) } ?? true }
        let why = (args["why"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (args["title"] as? String ?? legacyName).trimmingCharacters(in: .whitespaces)
        let saved = mapped.firstIndex { $0.0.isSecret } ?? 0
        let show: @MainActor ([Vault.Place], [Vault.Target], String?) -> Void = { places, targets, warning in
            // The site shown and saved is the one Petal read: the password field's page (or the first field's).
            let read = places.isEmpty ? nil : places[saved]
            var form = VaultForm(kind: kind, place: read.map(VaultForm.placeName) ?? "", fills: !ids.isEmpty)
            form.title = title
            form.username = args["username"] as? String ?? ""
            if kind == .apiKey, let read, read.web { form.site = read.host ?? "" }
            // What doesn't match comes first, in Petal's words; then what Petal AI said, marked as its own.
            let said = why.isEmpty ? "" : "Petal AI says: “\(UIMap.truncate(UIMap.tidy(why), 300))”"
            let detail = [warning ?? "", said].filter { !$0.isEmpty }.joined(separator: "\n\n")
            self.ask("vault-new", form.heading, detail: detail, always: true, form: form, warn: warning != nil, owner: caller, typed: { answer in
                guard live() else { return send(["declined": Self.over]) }
                self.vaultAnswered(answer, kind: kind, place: read, mapped: mapped, places: places, targets: targets, warned: warning,
                                   window: window, caller: caller, token: token, send: send)
            }) { allowed in
                if !allowed { send(["declined": "The person closed it. Don't ask for it in the chat."]) }
            }
        }
        guard let window else { return show([], [], nil) }
        vaultPlaces(window.map, window.entries, fail: fail) { places, targets, _ in
            guard live() else { return fail(Self.over) }
            // Never a card whose Submit couldn't fill: a password only into a password field, one page or app at a
            // time, and so on. What only doesn't match is said on the card.
            let check = Vault.request(kind, mapped.map(\.0), targets: targets, places: places, saved: saved)
            if let refusal = check.refusal { return fail("\(mapped[check.index].1): \(refusal)") }
            show(places, targets, check.warning)
        }
    }

    private func vaultAnswered(_ answer: VaultForm.Answer, kind: VaultKind, place: Vault.Place?, mapped: [(VaultField, String)],
                               places: [Vault.Place], targets: [Vault.Target], warned: String?,
                               window: (map: ComputerUse.Map, entries: [ComputerUse.Entry])?,
                               caller: String?, token: Acting.Cancel?, send: @escaping (Any) -> Void) {
        var item = VaultItem(kind: kind, title: answer.title)
        for (field, value) in answer.values { item[field] = value }
        // Hidden from the AI from now on, whether it's saved or not.
        VaultIndex.remember(Vault.secrets(item))
        if kind == .login, let place { Vault.bind(&item, to: place) }
        if kind == .apiKey, let site = VaultSite.host(answer.site) { item.sites = [site] }
        if item.title.isEmpty {
            switch kind {
            case .login: item.title = place.map { $0.web ? $0.host.map(VaultSite.registrable) ?? "Login" : $0.appName } ?? "Login"
            case .contact: item.title = item[.name].isEmpty ? "Contact info" : item[.name]
            case .address: item.title = "Home"
            case .card: item.title = Vault.brand(item[.number].filter(\.isNumber)) ?? "Card"
            case .apiKey: item.title = item.sites.first ?? "API key"
            case .unsorted: item.title = "Secret"
            }
        }
        let live = { token.map { self.computer.live(caller ?? "", $0) } ?? true }
        var reply: [String: Any] = ["note": Self.hidden]
        // `stored`: the item as the vault saved it, which the fill then takes from the vault at that version (edited
        // or deleted in Settings while the fill waits, nothing fills); nil when it wasn't saved.
        let fillAll = { (stored: VaultItem?) in
            guard let window, let caller, let token, !mapped.isEmpty else { return send(reply) }
            guard live() else { reply["error"] = Self.over; return send(reply) }
            // Each field on the page Petal read for it when the card showed, checked again right before.
            let used = mapped.indices.filter { answer.values[mapped[$0].0].map { !$0.isEmpty } ?? false }
            let plans = Vault.answeredPlans(title: item.title, fields: used.map { mapped[$0].0 }, values: answer.values,
                                            places: used.map { places[$0] }, targets: used.map { targets[$0] }, saved: stored)
            let go = {
                self.vaultFillAll(plans, entries: used.map { window.entries[$0] }, map: window.map, caller: caller, token: token, allowed: true) { result in
                    if let filled = result as? [String: Any] { reply.merge(filled) { _, new in new } }
                    send(reply)
                }
            }
            // Decided again with what was typed (the service a key is for, the login bound to the page), as any fill
            // is: a place it doesn't match gets its card before a key goes, unless the request card said so already.
            switch Vault.recheck(item, used.map { mapped[$0].0 }, targets: used.map { targets[$0] }, places: used.map { places[$0] }, warned: warned) {
            case .fill: go()
            case .refuse(let index, let why):
                reply["error"] = "\(mapped[used[index]].1): \(why) Nothing was filled."
                send(reply)
            case .ask(let title, let detail):
                self.ask("vault-fill", title, detail: detail, always: true, warn: true, allow: "Fill anyway", owner: caller) { allowed in
                    guard allowed else {
                        reply["declined"] = "The person didn't let Petal fill it there. Don't find another way."
                        return send(reply)
                    }
                    guard live() else { reply["error"] = Self.over; return send(reply) }
                    go()
                }
            }
        }
        guard answer.save else { return fillAll(nil) }
        guard live() else { return send(["declined": Self.over]) }
        let saving = item
        VaultStore.queue.async {
            // Stopped, or the reply ended, while the save waited its turn: nothing is saved.
            guard !(token?.stopped ?? false) else {
                return DispatchQueue.main.async { MainActor.assumeIsolated { send(["declined": Self.over]) } }
            }
            let ok = VaultStore.save([saving])
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard live() else {
                        if ok { reply["saved"] = Vault.shown(saving) }
                        reply["declined"] = Self.over
                        return send(reply)
                    }
                    if ok {
                        self.did("Saved \(saving.kind == .login ? "a login for \(saving.sites.first ?? saving.apps.first ?? saving.title)" : "“\(saving.title)”") in the vault")
                        reply["saved"] = Vault.shown(saving)
                    } else {
                        reply["saved"] = false
                        reply["error"] = "The Keychain didn't take it, so it isn't saved."
                    }
                    fillAll(ok ? saving : nil)
                }
            }
        }
    }

    // MARK: new_login

    /// A new account: Petal makes a strong password, saves it as a login for the page it read, and fills the
    /// password field (and the one confirming it, and the username): only where every one of those fields would
    /// fill by itself (one secure page of that site, or an app Petal verified).
    private func vaultNewLogin(_ args: [String: Any], caller: String?, _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
        if let refusal = computer.refusal() { return fail(refusal) }
        let passwordID = args["password_id"] as? String ?? args["id"] as? String ?? ""
        guard !passwordID.isEmpty else { return fail("Give password_id (the new password field's id from petal_ui), and confirm_id if the page asks for it twice.") }
        let confirmID = args["confirm_id"] as? String ?? ""
        let usernameID = args["username_id"] as? String ?? ""
        let ids = [passwordID] + [confirmID, usernameID].filter { !$0.isEmpty }
        guard let caller, let window = vaultWindow(caller, ids: ids) else { return fail(needsLook(caller, ids: ids)) }
        let map = window.map, entries = window.entries
        let username = (args["username"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let length = (args["length"] as? NSNumber)?.intValue ?? 20
        let symbols = args["symbols"] as? Bool ?? true
        let allowed = (args["allowed_symbols"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let task = args["task"] as? String ?? ""
        if !usernameID.isEmpty, username.isEmpty { return fail("Give username too: the email or username for the new account.") }
        guard let token = computer.token(caller, task: task) else { return fail(Self.over) }
        vaultPlaces(map, entries, fail: fail) { places, targets, _ in
            guard self.computer.live(caller, token) else { return fail(Self.over) }
            let place = places[0]
            var item = VaultItem(kind: .login, title: (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                                 ?? (place.web ? place.host.map(VaultSite.registrable) ?? "Login" : place.appName))
            Vault.bind(&item, to: place)
            guard !item.sites.isEmpty || !item.apps.isEmpty else {
                let why = place.web ? "it couldn't read which page this is." : place.unverified ? Vault.unverifiedWhy(place) : "it couldn't verify who made \(place.appName)."
                return fail("Petal didn't make a password here: \(why)")
            }
            item[.username] = username
            item[.password] = "x"
            let roles: [VaultField] = [.password] + (confirmID.isEmpty ? [] : [.password]) + (usernameID.isEmpty ? [] : [.username])
            // Every field, as it would fill by itself; a field that would only ask (another site's frame, http, an
            // app Petal can't verify) means no password is made at all.
            if let (index, why) = Vault.unasked(item, roles, targets: Array(targets.prefix(roles.count)), places: Array(places.prefix(roles.count))) {
                return fail("\(ids[index]): Petal didn't make a password here: \(why)")
            }
            VaultStore.queue.async {
                item[.password] = Vault.password(length: length, symbols: symbols, allowed: allowed, random: VaultStore.random)
                VaultIndex.remember(Vault.secrets(item))
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // The reply ended while the password was made: nothing is saved or filled.
                        guard self.computer.live(caller, token) else { return fail(Self.over) }
                        let saving = item
                        VaultStore.queue.async {
                            // Stopped, or the reply ended, while the save waited its turn: nothing is saved.
                            guard !token.stopped else {
                                return DispatchQueue.main.async { MainActor.assumeIsolated { fail(Self.over) } }
                            }
                            let ok = VaultStore.save([saving])
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    guard self.computer.live(caller, token) else {
                                        return fail(ok ? "Petal saved the new password as \(saving.title) but filled nothing: " + Self.over : Self.over)
                                    }
                                    guard ok else { return fail("The Keychain didn't take the new password, so nothing was filled.") }
                                    self.did("Made a strong password for \(place.where_) and saved it in the vault")
                                    // The login as saved: edited while the fill waits to be allowed (another site), it fills nothing.
                                    let revision = Vault.revision(Vault.normalized(saving))
                                    let plans = roles.indices.map { index -> VaultFillPlan in
                                        var plan = VaultFillPlan(itemID: saving.id, title: saving.title, field: roles[index], place: places[index], target: targets[index])
                                        plan.revision = revision
                                        plan.task = task
                                        return plan
                                    }
                                    self.vaultFillAll(plans, entries: Array(entries.prefix(roles.count)), map: map, caller: caller, token: token, allowed: false) { result in
                                        var reply = (result as? [String: Any]) ?? [:]
                                        reply["saved"] = Vault.shown(saving)
                                        reply["note"] = "Petal made a strong password and saved it as \(saving.title); you never see it."
                                        send(reply)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: use (older callers)

    /// An older way to fill: a saved key or password by its name, into a field. It goes through `fill` with every
    /// one of fill's checks (the field's id from petal_ui, its page or app, its kind, Stop): `id`, else the one field
    /// petal_ui saw with the cursor.
    private func vaultUse(_ args: [String: Any], caller: String?, _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
        let name = (args["name"] as? String ?? args["item"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return fail("Give the item's id or name (action list shows them), and fill with action fill.") }
        var id = (args["id"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if id.isEmpty {
            guard let caller, let map = computer.maps[caller], Date().timeIntervalSince(map.made) <= UIMap.lifetime else {
                return fail("Call petal_ui first, then action fill with item and fields {password: id} (or {value: id} for a key).")
            }
            let focused = map.entries.filter { $0.value.node.focused }.map(\.key)
            guard focused.count == 1 else {
                return fail("Petal didn't see which field has the cursor. Use action fill with item and fields {password: id} (or {value: id} for a key) from petal_ui.")
            }
            id = focused[0]
        }
        let picked = id
        guard let caller, let token = computer.token(caller, task: args["task"] as? String ?? "") else {
            return fail(caller == nil ? ComputerUse.oldTools : Self.over)
        }
        VaultStore.load { read in
            guard self.computer.live(caller, token) else { return fail(Self.over) }
            guard case .success(let items) = read else { return fail(VaultStore.unreadableText + " Nothing was filled; try again in a moment.") }
            // An unsorted secret (an old name's) still works by its name: its fill asks the person every time.
            guard let item = Vault.find(items, name), [.apiKey, .login, .unsorted].contains(item.kind) else {
                return fail("There's no “\(name)” in the vault. action list shows what's there; fill is the way to fill a field.")
            }
            var forwarded = args
            forwarded["item"] = item.id
            forwarded["name"] = nil
            forwarded["field"] = nil
            forwarded["id"] = nil
            forwarded["fields"] = [item.kind == .login ? "password" : "value": picked]
            self.vaultFill(forwarded, caller: caller, send, fail)
        }
    }
}
