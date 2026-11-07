import AppKit
import ApplicationServices
import Security

/// One field to fill from the vault, as Petal decided it (Vault.decide): the item, the field, where the field was
/// (read by Petal itself, never from the AI), and what kind of field it was. Checked again right before the keys go
/// (VaultFiller), and filled through ComputerUse's line, with its pointer, Stop and window checks.
struct VaultFillPlan {
    var itemID = ""
    /// The item's title, for the history ("Filled your GitHub password on github.com").
    var title = ""
    var field: VaultField
    /// What the person just typed into Petal's card for this page, filled without saving it first.
    var given: String?
    var place: Vault.Place
    var target: Vault.Target
    var submit = false
    var task = ""
    var fourDigitYear = false
}

// MARK: - Filling

/// Puts a vault value into one field, off the main thread: only once the field is still on the page (or in the app)
/// Petal decided on, still the kind of field it was, and has the keyboard. Keystrokes posted to the app's own process
/// a few at a time (UIMap.batches), or an item picked from a pop-up menu; never the clipboard. A password field's
/// value is never read back.
enum VaultFiller {
    static func fill(_ plan: VaultFillPlan, into element: AXUIElement, map: ComputerUse.Map, cancel: Acting.Cancel) -> String? {
        let pid = map.pid
        // The same page or app as when Petal decided: a page that moved on meanwhile never gets it.
        let now = VaultReader.place(of: element, pid: pid, bundle: map.bundle, appName: map.appName)
        if let why = Vault.moved(from: plan.place, to: now) { return why }
        if !plan.place.web, plan.place.signed, !now.signed { return "Petal couldn't verify \(map.appName) anymore; nothing was filled." }
        // Still the kind of field it was: a password field if it was one, a menu if it was one.
        if VaultReader.target(element) != plan.target {
            return "That field changed since petal_ui; nothing was filled. Call petal_ui again."
        }
        // What to put in: from the vault now (the AI never holds it), or what the person just typed into the card.
        guard let text = plan.given ?? VaultStore.item(plan.itemID).flatMap({ Vault.text($0, plan.field, fourDigitYear: plan.fourDigitYear) }),
              !text.isEmpty else { return "That isn't in the vault anymore." }
        guard !cancel.stopped else { return ComputerUse.stoppedText }
        if let error = Acting.bringWindow(map, cancel: cancel) { return error }
        if plan.target.popup { return choose(text, in: element, pid: pid, cancel: cancel) }
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
        // Over what's there already, only once the keyboard is in this field.
        if let all = UIMap.parseKey("cmd-a") {
            guard keysGo(to: element, pid: pid), Acting.post(all, to: pid, cancel: cancel) else {
                return cancel.stopped ? ComputerUse.stoppedText : "The cursor left the field; nothing was filled."
            }
        }
        guard Acting.type(text, to: pid, cancel: cancel, still: { keysGo(to: element, pid: pid) }) else {
            return cancel.stopped ? ComputerUse.stoppedText : "The cursor left the field while Petal was filling it, so it stopped there. Call petal_ui to see the page."
        }
        if plan.submit, let enter = UIMap.parseKey("return") {
            guard keysGo(to: element, pid: pid) else { return "The cursor left the field before Return: it was filled, not sent." }
            guard Acting.post(enter, to: pid, cancel: cancel) else { return ComputerUse.stoppedText }
        }
        return nil
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

    /// Opens a pop-up menu (a web page's select), picks the item that is `wanted` (Vault.pick: "Türkiye" finds
    /// "Turkey"), or closes it again with nothing picked when none is.
    static func choose(_ wanted: String, in popup: AXUIElement, pid: pid_t, cancel: Acting.Cancel) -> String? {
        func items() -> [AXUIElement] {
            let children: [AXUIElement] = Windows.value(popup, kAXChildrenAttribute) ?? []
            let menu = children.first { (Windows.value($0, kAXRoleAttribute) as String?) == "AXMenu" }
            return (menu.flatMap { Windows.value($0, kAXChildrenAttribute) as [AXUIElement]? } ?? [])
                .filter { (Windows.value($0, kAXRoleAttribute) as String?) == "AXMenuItem" }
        }
        guard !cancel.stopped else { return ComputerUse.stoppedText }
        var list = items()
        var opened = false
        if list.isEmpty {
            AXUIElementPerformAction(popup, kAXPressAction as CFString)
            opened = true
            for _ in 0..<5 where list.isEmpty { usleep(80_000); list = items() }
        }
        let titles = list.map { (Windows.value($0, kAXTitleAttribute) as String?) ?? "" }
        guard let index = Vault.pick(wanted, from: titles) else {
            if opened, let escape = UIMap.parseKey("escape") { Acting.post(escape, to: pid, cancel: cancel) }
            return list.isEmpty ? "That menu didn't open through Accessibility; ask the person to pick it." : "Petal didn't find a matching item in that menu; ask the person to pick it."
        }
        guard !cancel.stopped else {
            if opened, let escape = UIMap.parseKey("escape") { Acting.post(escape, to: pid, cancel: Acting.Cancel()) }
            return ComputerUse.stoppedText
        }
        guard AXUIElementPerformAction(list[index], kAXPressAction as CFString) == .success else {
            if opened, let escape = UIMap.parseKey("escape") { Acting.post(escape, to: pid, cancel: cancel) }
            return "Couldn't pick it from that menu; ask the person to pick it."
        }
        return nil
    }
}

// MARK: - Where a field is

/// Which page or app a field is in, read by Petal through Accessibility (never from the AI), off the main thread.
enum VaultReader {
    /// The addresses of the web areas around `element`: the nearest (a login or payment frame's own) and the
    /// outermost (the tab's page). Not in a web page: the app, and whether its signature checks out.
    static func place(of element: AXUIElement, pid: pid_t, bundle: String, appName: String) -> Vault.Place {
        var place = Vault.Place(bundle: bundle, appName: appName)
        var areas: [String?] = []
        var current: AXUIElement? = element
        for _ in 0..<120 {
            guard let at = current else { break }
            let role: String = Windows.value(at, kAXRoleAttribute) ?? ""
            if role == "AXWebArea" {
                place.web = true
                areas.append(url(at))
            }
            if role == "AXWindow" || role == "AXApplication" { break }
            current = Windows.value(at, kAXParentAttribute)
        }
        place.frameURL = areas.first ?? nil
        place.topURL = areas.last ?? nil
        if !place.web { place.signed = signed(pid: pid, bundle: bundle) }
        return place
    }

    static func url(_ area: AXUIElement) -> String? {
        if let url: URL = Windows.value(area, "AXURL") { return url.absoluteString }
        if let text: String = Windows.value(area, "AXURL") { return text }
        return nil
    }

    /// The running app is signed by Apple's certificates (an App Store or Developer ID app, or Apple's own) for this
    /// very bundle id, and its signature checks out now: an app made to look like another can't pass.
    static func signed(pid: pid_t, bundle: String) -> Bool {
        guard !bundle.isEmpty, !bundle.contains("\"") else { return false }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic and identifier \"\(bundle)\"" as CFString, [], &requirement) == errSecSuccess else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
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
    /// never sees a password, card number, security code or key.
    func vault(_ args: [String: Any], caller: String?, _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
        switch (args["action"] as? String ?? "list").lowercased() {
        case "list": vaultList(args, send)
        case "fill": vaultFill(args, caller: caller, send, fail)
        case "request": vaultRequest(args, caller: caller, send, fail)
        case "new_login", "generate": vaultNewLogin(args, caller: caller, send, fail)
        case "use": vaultUse(args, send, fail)
        default: fail("action is list, fill, request or new_login.")
        }
    }

    private static let hidden = "Petal fills these itself; you never see a password, card number, security code or key."

    private func vaultList(_ args: [String: Any], _ send: @escaping (Any) -> Void) {
        let kind = (args["kind"] as? String).flatMap { $0.isEmpty ? nil : Vault.kindNamed($0) }
        let site = (args["site"] as? String).flatMap(VaultSite.host)
        VaultStore.load { items in
            var list = items.filter { kind == nil || $0.kind == kind }
            if let site { list = list.filter { $0.kind != .login || $0.sites.contains { VaultSite.matches(host: site, saved: $0) } } }
            send(["items": list.map { Vault.shown($0, in: items) },
                  "note": Self.hidden + " Fill with action fill: the item's id and fields {field: id from petal_ui}."])
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

    /// Where the controls are and what kind each is (and the browser's own answer for the tab), read off the main
    /// thread, handed back on it with the vault's items.
    private func vaultPlaces(_ map: ComputerUse.Map, _ entries: [ComputerUse.Entry],
                             done: @escaping @MainActor (_ places: [Vault.Place], _ targets: [Vault.Target], _ items: [VaultItem]) -> Void) {
        ComputerUse.readQueue.async {
            let places = entries.map { VaultReader.place(of: $0.element, pid: map.pid, bundle: map.bundle, appName: map.appName) }
            let targets = entries.map { VaultReader.target($0.element) }
            let title: String = Windows.value(map.window, kAXTitleAttribute) ?? ""
            let items = VaultStore.items()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard places.contains(where: \.web), let running = NSRunningApplication(processIdentifier: map.pid) else { return done(places, targets, items) }
                    // The browser's own answer for this window's tab, where it gives one (Automation allowed).
                    let window = Browsers.Window(number: map.windowID, title: title, frame: map.windowFrame)
                    self.app.browsers.frontURL(of: running, window: window) { tab in
                        done(places.map { var p = $0; if p.web { p.tabURL = tab }; return p }, targets, items)
                    }
                }
            }
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
        vaultPlaces(map, entries) { places, targets, items in
            // The item: named, else the login saved for this page (or app), else the only card saved.
            let first = Vault.field(wanted[0].word)!
            let item: VaultItem
            if !ref.isEmpty {
                guard let found = Vault.find(items, ref) else { return fail("There's no “\(ref)” in the vault. action list shows what's there.") }
                item = found
            } else if [.username, .password].contains(first) {
                let place = places[wanted.firstIndex { Vault.field($0.word) == .password } ?? 0]
                let logins = Vault.logins(items, host: place.web ? place.host : nil, bundle: place.web ? nil : place.bundle)
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
            var plans: [VaultFillPlan] = []
            var asks: [(String, String)] = []
            var shops: Set<String> = []
            for (offset, pair) in wanted.enumerated() {
                let field = Vault.field(pair.word, kind: item.kind)!
                var plan = VaultFillPlan(itemID: item.id, title: item.title, field: field, place: places[offset], target: targets[offset])
                plan.task = task
                plan.fourDigitYear = args["fourDigitYear"] as? Bool ?? false
                let shop = places[offset].shop.map(VaultSite.registrable) ?? ""
                let allowed = item.kind == .card && self.computer.checkout(caller, shop: shop, task: task).allowed
                switch Vault.decide(item, field, target: targets[offset], place: places[offset], checkout: allowed) {
                case .refuse(let why): return fail("\(pair.id): \(why) Nothing was filled.")
                case .ask(let title, let detail): asks.append((title, detail))
                case .buy(let shop): shops.insert(shop)
                case .fill: break
                }
                plans.append(plan)
            }
            // Return goes once, after the last field.
            if args["submit"] as? Bool == true, !plans.isEmpty { plans[plans.count - 1].submit = true }
            let go: (Bool) -> Void = { allowed in
                self.vaultFillAll(plans, entries: entries, map: map, caller: caller, allowed: allowed, send: send)
            }
            if !shops.isEmpty {
                guard shops.count == 1, let shop = shops.first else { return fail("Those fields are on different shops' pages; fill one checkout at a time.") }
                return self.vaultBuy(item, shop: shop, args: args, map: map, caller: caller, task: task, send: send, fail: fail) { go(true) }
            }
            guard let (title, detail) = asks.first else { return go(false) }
            self.ask("vault-fill", title, detail: detail, always: true, warn: true, allow: "Fill anyway", owner: caller) { allowed in
                guard allowed else { return send(["declined": "The person didn't let Petal fill it. Don't find another way."]) }
                go(true)
            }
        }
    }

    /// Fills the fields one after another; the AI hears which were filled, and the first error if any.
    private func vaultFillAll(_ plans: [VaultFillPlan], entries: [ComputerUse.Entry], map: ComputerUse.Map, caller: String, allowed: Bool,
                              send: @escaping (Any) -> Void) {
        var steps = Array(plans.indices)
        var filled: [String] = []
        func next() {
            guard !steps.isEmpty else {
                var reply: [String: Any] = ["filled": filled, "app": map.appName]
                if plans.last?.submit == true { reply["next"] = "The window may have changed: call petal_ui again before using more ids." }
                return send(reply)
            }
            let index = steps.removeFirst()
            computer.fill(plans[index], entry: entries[index], map: map, caller: caller, allowed: allowed, send: { reply in
                if let declined = (reply as? [String: Any])?["declined"] { return send(["filled": filled, "declined": declined]) }
                filled.append(plans[index].field.rawValue)
                next()
            }, fail: { why in
                send(["filled": filled, "error": why])
            })
        }
        next()
    }

    /// The one card before payment info goes into a shop's page in a reply: "Buy on shop.example?", what Petal AI says
    /// it's buying (its words, marked as such) and the card. Buy lets payment info fill there, and the order be
    /// placed, for the rest of the reply; Don't (the default) fills nothing.
    private func vaultBuy(_ item: VaultItem, shop: String, args: [String: Any], map: ComputerUse.Map, caller: String, task: String,
                          send: @escaping (Any) -> Void, fail: @escaping (String) -> Void, bought: @escaping () -> Void) {
        let what = UIMap.truncate(UIMap.tidy(args["buying"] as? String ?? ""), 160)
        let price = UIMap.truncate(UIMap.tidy(args["price"] as? String ?? ""), 40)
        let said = [what, price].filter { !$0.isEmpty }.joined(separator: ", ")
        let detail = (said.isEmpty ? "Petal AI didn't say what it's buying." : "Petal AI says: “\(said)”.") + " Pays with \(Vault.cardName(item))."
        let cancel = computer.checkout(caller, shop: shop, task: task).cancel
        ask("vault-buy", "Buy on \(shop)?", detail: detail, always: true, warn: true, allow: "Buy", owner: caller) { allowed in
            guard allowed else { return send(["declined": "The person said Don't: nothing was filled. Don't buy it, and don't find another way."]) }
            guard self.computer.allowCheckout(caller, shop: shop, bundle: map.bundle, cancel: cancel) else { return fail(ComputerUse.stoppedText) }
            self.did("You said Buy on \(shop) (\(Vault.cardName(item)))")
            bought()
        }
    }

    // MARK: request

    /// Asks the person for what's missing, on Petal's card (a login, contact info, an address, payment info or an
    /// API key): typed there, never into the chat. With fields' ids, Submit fills them on the page Petal read (never
    /// payment info: that waits for Buy); for a login, "Save to your vault" (on by default) keeps it for that site.
    private func vaultRequest(_ args: [String: Any], caller: String?, _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
        let legacyName = (args["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let kind = (args["kind"] as? String).flatMap { $0.isEmpty ? nil : Vault.kindNamed($0) } ?? (legacyName.isEmpty ? .login : .apiKey)
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
        let why = (args["why"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (args["title"] as? String ?? legacyName).trimmingCharacters(in: .whitespaces)
        let show: @MainActor ([Vault.Place], [Vault.Target]) -> Void = { places, targets in
            // The site shown and saved is the one Petal read: the password field's page (or the first field's).
            let read = places.isEmpty ? nil : places[mapped.firstIndex { $0.0.isSecret } ?? 0]
            var form = VaultForm(kind: kind, place: read.map(VaultForm.placeName) ?? "", fills: !ids.isEmpty)
            form.title = title
            form.username = args["username"] as? String ?? ""
            if kind == .apiKey, let read, read.web { form.site = read.host ?? "" }
            self.ask("vault-new", form.heading, detail: why, always: true, form: form, owner: caller, typed: { answer in
                self.vaultAnswered(answer, kind: kind, place: read, mapped: mapped, places: places, targets: targets,
                                   window: window, caller: caller, send: send)
            }) { allowed in
                if !allowed { send(["declined": "The person closed it. Don't ask for it in the chat."]) }
            }
        }
        guard let window else { return show([], []) }
        vaultPlaces(window.map, window.entries) { places, targets, _ in
            // Never a card whose Submit couldn't fill: a password only into a password field, and so on.
            var probe = VaultItem(kind: kind, title: "x", sites: places.compactMap(\.host), apps: places.map(\.bundle))
            for field in kind.fields { probe[field] = "x" }
            probe[.expiry] = "01/30"
            for (offset, pair) in mapped.enumerated() {
                if case .refuse(let why) = Vault.decide(probe, pair.0, target: targets[offset], place: places[offset]) { return fail("\(pair.1): \(why)") }
            }
            show(places, targets)
        }
    }

    private func vaultAnswered(_ answer: VaultForm.Answer, kind: VaultKind, place: Vault.Place?, mapped: [(VaultField, String)],
                               places: [Vault.Place], targets: [Vault.Target], window: (map: ComputerUse.Map, entries: [ComputerUse.Entry])?,
                               caller: String?, send: @escaping (Any) -> Void) {
        var item = VaultItem(kind: kind, title: answer.title)
        for (field, value) in answer.values { item[field] = value }
        if kind == .login, let place {
            if place.web, let host = place.host { item.sites = [host] } else if !place.web, place.signed { item.apps = [place.bundle] }
        }
        if kind == .apiKey, let site = VaultSite.host(answer.site) { item.sites = [site] }
        if item.title.isEmpty {
            switch kind {
            case .login: item.title = place.map { $0.web ? $0.host.map(VaultSite.registrable) ?? "Login" : $0.appName } ?? "Login"
            case .contact: item.title = item[.name].isEmpty ? "Contact info" : item[.name]
            case .address: item.title = "Home"
            case .card: item.title = Vault.brand(item[.number].filter(\.isNumber)) ?? "Card"
            case .apiKey: item.title = item.sites.first ?? "API key"
            }
        }
        var reply: [String: Any] = ["note": Self.hidden]
        let fillAll = {
            guard let window, let caller, !mapped.isEmpty else { return send(reply) }
            // Each field on the page Petal read for it when the card showed, checked again right before.
            let plans = mapped.indices.compactMap { index -> VaultFillPlan? in
                guard let value = answer.values[mapped[index].0], !value.isEmpty else { return nil }
                return VaultFillPlan(title: item.title, field: mapped[index].0, given: value, place: places[index], target: targets[index])
            }
            let used = mapped.indices.filter { answer.values[mapped[$0].0].map { !$0.isEmpty } ?? false }
            self.vaultFillAll(plans, entries: used.map { window.entries[$0] }, map: window.map, caller: caller, allowed: true) { result in
                if let filled = result as? [String: Any] { reply.merge(filled) { _, new in new } }
                send(reply)
            }
        }
        guard answer.save else { return fillAll() }
        let saving = item
        VaultStore.queue.async {
            let ok = VaultStore.save([saving])
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if ok {
                        self.did("Saved \(saving.kind == .login ? "a login for \(saving.sites.first ?? saving.title)" : "“\(saving.title)”") in the vault")
                        reply["saved"] = Vault.shown(saving)
                    } else {
                        reply["saved"] = false
                        reply["error"] = "The Keychain didn't take it, so it isn't saved."
                    }
                    fillAll()
                }
            }
        }
    }

    // MARK: new_login

    /// A new account: Petal makes a strong password, saves it as a login for the page it read, and fills the
    /// password field (and the one confirming it, and the username).
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
        if !usernameID.isEmpty, username.isEmpty { return fail("Give username too: the email or username for the new account.") }
        vaultPlaces(map, entries) { places, targets, _ in
            let place = places[0]
            var item = VaultItem(kind: .login, title: (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                                 ?? (place.web ? place.host.map(VaultSite.registrable) ?? "Login" : place.appName))
            if place.web, let host = place.host { item.sites = [host] } else if !place.web { item.apps = [place.bundle] }
            item[.username] = username
            item[.password] = "x"
            // Only where it would fill by itself: a secure page (or a verified app).
            if let why = Vault.mismatch(item, place) { return fail("Petal didn't make a password here: \(why)") }
            let roles: [VaultField] = [.password] + (confirmID.isEmpty ? [] : [.password]) + (usernameID.isEmpty ? [] : [.username])
            for (offset, field) in roles.enumerated() {
                if case .refuse(let why) = Vault.decide(item, field, target: targets[offset], place: places[offset]) { return fail("\(ids[offset]): \(why)") }
            }
            VaultStore.queue.async {
                item[.password] = Vault.password(length: length, symbols: symbols, allowed: allowed, random: VaultStore.random)
                let ok = VaultStore.save([item])
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard ok else { return fail("The Keychain didn't take the new password, so nothing was filled.") }
                        self.did("Made a strong password for \(place.where_) and saved it in the vault")
                        let plans = roles.indices.map { index -> VaultFillPlan in
                            var plan = VaultFillPlan(itemID: item.id, title: item.title, field: roles[index], place: places[index], target: targets[index])
                            plan.task = args["task"] as? String ?? ""
                            return plan
                        }
                        self.vaultFillAll(plans, entries: Array(entries.prefix(roles.count)), map: map, caller: caller, allowed: false) { result in
                            var reply = (result as? [String: Any]) ?? [:]
                            reply["saved"] = Vault.shown(item)
                            reply["note"] = "Petal made a strong password and saved it as \(item.title); you never see it."
                            send(reply)
                        }
                    }
                }
            }
        }
    }

    // MARK: use (older callers)

    /// Types a saved key or password into the field that has the cursor in the app in front, after asking every
    /// time: for sessions that name a secret, as before kinds. `fill` is the way now.
    private func vaultUse(_ args: [String: Any], _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
        let name = (args["name"] as? String ?? args["item"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return fail("Nothing's in front to type into.")
        }
        if neverLook(front.bundleIdentifier) { return fail("The user keeps \(front.localizedName ?? "that app") private.") }
        VaultStore.load { items in
            guard let item = Vault.find(items, name), [.apiKey, .login].contains(item.kind) else {
                return fail("There's no “\(name)” in the vault. action list shows what's there; fill is the way to fill a field.")
            }
            let place = front.localizedName ?? "the app in front"
            let field: VaultField = item.kind == .login ? .password : .value
            self.ask("vault:\(item.id)", "Type your “\(item.title)” into \(place)", detail: "Petal types it into the field that has the cursor; \(self.app.chatProvider?.name ?? "the AI") never sees it.",
                     always: true) { allowed in
                guard allowed else { return send(["declined": "The person didn't allow it."]) }
                let pid = front.processIdentifier
                VaultStore.queue.async {
                    guard let secret = VaultStore.item(item.id).map({ $0[field] }), !secret.isEmpty else {
                        return DispatchQueue.main.async { fail("Couldn't read it from the Keychain.") }
                    }
                    let source = CGEventSource(stateID: .combinedSessionState)
                    for chunk in UIMap.batches(secret) {
                        for down in [true, false] {
                            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                            chunk.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                            event?.postToPid(pid)
                        }
                    }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.did("Typed your “\(item.title)” into \(place)")
                            send(["typed": item.title, "into": place])
                        }
                    }
                }
            }
        }
    }
}
